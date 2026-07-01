// load-gen — a long-lived Ballerina worker (not a service) that drives the five
// front-facing domains so the observability stack always has something to show.
// payment + notification are exercised transitively through order.
//
// Pattern is chosen via `--pattern <name>` (CLI) or LOADGEN_PATTERN env, default
// "baseline"; the named patterns/<name>.yaml defines RPS, worker count, optional
// spike window, and per-domain weights. Each HTTP call becomes an OTel span (the
// jaeger extension exports them), so the generated load is visible in Datadog.
import ballerina/data.yaml as yaml;
import ballerina/http;
import ballerina/io;
import ballerina/lang.runtime;
import ballerina/log;
import ballerina/random;
import ballerina/time;

type Spike record {
    int afterSeconds;
    int rps;
    int forSeconds;
};

type Weights record {
    int store;
    int customer;
    int inventory;
    int invoice;
    int 'order;
};

type Pattern record {
    string name;
    int baseRps;
    int workers;
    int durationSeconds;
    Spike? spike = ();
    Weights weights;
};

// Downstream front-doors. `new` is lazy, so these don't fail if a service is
// not up yet when load-gen starts.
final http:Client storeClient = check new (envOr("STORE_URL", "http://store:9090"));
final http:Client customerClient = check new (envOr("CUSTOMER_URL", "http://customer:9090"));
final http:Client orderClient = check new (envOr("ORDER_URL", "http://order:9090"));
final http:Client inventoryClient = check new (envOr("INVENTORY_URL", "http://inventory:9090"));
final http:Client invoiceClient = check new (envOr("INVOICE_URL", "http://invoice:9090"));

public function main(string... args) returns error? {
    string patternName = selectPattern(args);
    Pattern p = check loadPattern(patternName);
    log:printInfo("load-gen starting", pattern = p.name, baseRps = p.baseRps,
            workers = p.workers, durationSeconds = p.durationSeconds);

    int startSec = time:utcNow()[0];
    future<error?>[] handles = [];
    int w = 0;
    while w < p.workers {
        future<error?> f = start workerLoop(p, startSec, w);
        handles.push(f);
        w += 1;
    }
    foreach future<error?> f in handles {
        check wait f;
    }
}

isolated function workerLoop(Pattern p, int startSec, int id) returns error? {
    while true {
        int elapsed = time:utcNow()[0] - startSec;
        if p.durationSeconds > 0 && elapsed >= p.durationSeconds {
            return;
        }
        int rps = currentRps(p, elapsed);
        runFlow(p);
        // Pace so all `workers` strands together approximate `rps` req/s.
        decimal interval = rps > 0 ? <decimal>p.workers / rps : 1.0d;
        runtime:sleep(interval);
    }
}

isolated function currentRps(Pattern p, int elapsed) returns int {
    Spike? s = p.spike;
    if s is Spike && elapsed >= s.afterSeconds && elapsed < s.afterSeconds + s.forSeconds {
        return s.rps;
    }
    return p.baseRps;
}

isolated function runFlow(Pattern p) {
    string domain = pickDomain(p.weights);
    do {
        match domain {
            "store" => {
                check storeFlow();
            }
            "customer" => {
                check customerFlow();
            }
            "inventory" => {
                check inventoryFlow();
            }
            "invoice" => {
                check invoiceFlow();
            }
            "order" => {
                check orderFlow();
            }
        }
    } on fail error e {
        // Services may be mid-startup or chaos may be injected; keep driving.
        logError("flow failed: " + domain, e);
    }
}

// ── Per-domain flows ─────────────────────────────────────────────────────────

isolated function storeFlow() returns error? {
    http:Response _ = check storeClient->get("/products");
    http:Response _ = check storeClient->get(string `/products/${randInt(1, 5)}`);
}

isolated function customerFlow() returns error? {
    if random:createDecimal() < 0.3 {
        int n = randInt(1, 100000);
        json payload = {name: string `user-${n}`, email: string `user-${n}@example.com`};
        http:Response _ = check customerClient->post("/customers", payload);
    } else {
        http:Response _ = check customerClient->get(string `/customers/${randInt(1, 5)}`);
    }
}

isolated function inventoryFlow() returns error? {
    http:Response _ = check inventoryClient->get(string `/stock/${randSku()}`);
}

isolated function invoiceFlow() returns error? {
    // Early on these may 404 (no invoices yet) — realistic read noise.
    http:Response _ = check invoiceClient->get(string `/invoices/${randInt(1, 5)}`);
}

isolated function orderFlow() returns error? {
    json payload = {
        customerId: randInt(1, 5),
        items: [{sku: randSku(), qty: randInt(1, 3)}]
    };
    http:Response _ = check orderClient->post("/orders", payload);
}

// ── Helpers ──────────────────────────────────────────────────────────────────

isolated function pickDomain(Weights w) returns string {
    // `random:createDecimal()` actually returns `float` (Ballerina stdlib name is
    // historical — the value is a uniform 0.0..1.0 float). Cast to `decimal` so
    // the deterministic helper `pickDomainAt(_, decimal)` stays exact.
    return pickDomainAt(w, <decimal>random:createDecimal());
}

// Pure, deterministic weighted-domain selection. `r` must be in [0.0, 1.0).
// Extracted from `pickDomain` so unit tests can pin a specific roll.
isolated function pickDomainAt(Weights w, decimal r) returns string {
    [string, int][] entries = [
        ["store", w.store],
        ["customer", w.customer],
        ["inventory", w.inventory],
        ["invoice", w.invoice],
        ["order", w.'order]
    ];
    int total = 0;
    foreach var [_, wt] in entries {
        total += wt;
    }
    if total <= 0 {
        return "store";
    }
    // Map r ∈ [0.0, 1.0) to an index in [0, total). Must floor before casting:
    // `<int>E` in Ballerina applies to the next primary expression only, so
    // `<int>(r * total).floor()` parses as `(<int>(r * total)).floor()` — the
    // cast happens first (rounding 9.9 → 10), then `.floor()` is a no-op on int.
    // The extra parens here make `<int>` apply to the already-floored decimal.
    int roll = <int>((r * total).floor());
    int acc = 0;
    foreach var [domainName, wt] in entries {
        acc += wt;
        if roll < acc {
            return domainName;
        }
    }
    return "store";
}

// Inclusive random int in [lo, hi].
isolated function randInt(int lo, int hi) returns int {
    // `createIntInRange` is [start, end) — end-exclusive — so pass hi + 1 to
    // make hi reachable. Avoids the `<int>(float)` round-half-to-even pitfall
    // (e.g. `<int>(0.95 * 5)` rounds to 5, so `lo + that` could overshoot hi).
    int|random:Error n = random:createIntInRange(lo, hi + 1);
    return n is int ? n : lo;
}

isolated function randSku() returns string {
    return string `SKU-00${randInt(1, 5)}`;
}

isolated function selectPattern(string[] args) returns string {
    int i = 0;
    while i < args.length() {
        if args[i] == "--pattern" && i + 1 < args.length() {
            return args[i + 1];
        }
        i += 1;
    }
    return envOr("LOADGEN_PATTERN", "baseline");
}

isolated function loadPattern(string name) returns Pattern|error {
    string content = check io:fileReadString(string `patterns/${name}.yaml`);
    Pattern p = check yaml:parseString(content);
    return p;
}
