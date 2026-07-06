// Unit tests for load-gen — the long-lived Ballerina worker that drives the
// retail mesh. We test only pure logic: env-var defaulting, pattern parsing,
// the RPS schedule, weighted domain selection (via the test-only seeded entry
// point `pickDomainAt`), CLI pattern selection, and the bounded random helpers.
// No HTTP traffic is exercised here.
import ballerina/os;
import ballerina/test;

// ── envOr (obs.bal) ──────────────────────────────────────────────────────────

@test:Config {}
function testEnvOrFallbackWhenUnset() {
    // Use a name we are confident is not set in the test environment.
    string got = envOr("LOADGEN_TEST_DEFINITELY_UNSET_VAR", "fallback-value");
    test:assertEquals(got, "fallback-value", "missing env var should yield the fallback");
}

@test:Config {}
function testEnvOrReturnsSetValueWhenPresent() {
    // ballerina/os has no setEnv, so we lean on a variable that is virtually
    // always set in the process environment. PATH on macOS/Linux, USERPROFILE
    // on Windows — at least one of these should be present.
    string pathVal = os:getEnv("PATH");
    string userProfile = os:getEnv("USERPROFILE");
    string presentName;
    string presentValue;
    if pathVal != "" {
        presentName = "PATH";
        presentValue = pathVal;
    } else if userProfile != "" {
        presentName = "USERPROFILE";
        presentValue = userProfile;
    } else {
        // Truly stripped environment — accept that we can't exercise the positive
        // branch and assert the negative branch instead.
        test:assertEquals(envOr("LOADGEN_STILL_UNSET", "f"), "f");
        return;
    }
    string got = envOr(presentName, "fallback-value");
    test:assertEquals(got, presentValue, "set env var should override fallback");
}

// ── selectPattern (CLI / env arg parsing) ────────────────────────────────────

@test:Config {}
function testSelectPatternFromCliFlag() {
    string name = selectPattern(["--pattern", "spike"]);
    test:assertEquals(name, "spike");
}

@test:Config {}
function testSelectPatternDefaultsToBaseline() {
    // No --pattern flag, and we assume LOADGEN_PATTERN is not set in CI.
    // (If it IS set, envOr returns it — accept either the env value or "baseline".)
    string name = selectPattern([]);
    string envVal = os:getEnv("LOADGEN_PATTERN");
    string expected = envVal == "" ? "baseline" : envVal;
    test:assertEquals(name, expected);
}

@test:Config {}
function testSelectPatternIgnoresDanglingFlag() {
    // `--pattern` with no following value should fall through to the default.
    string name = selectPattern(["--pattern"]);
    string envVal = os:getEnv("LOADGEN_PATTERN");
    string expected = envVal == "" ? "baseline" : envVal;
    test:assertEquals(name, expected);
}

// ── loadPattern (YAML → Pattern) ─────────────────────────────────────────────

@test:Config {}
function testLoadPatternBaselineParsesCleanly() returns error? {
    Pattern p = check loadPattern("baseline");
    test:assertEquals(p.name, "baseline");
    test:assertEquals(p.baseRps, 5);
    test:assertEquals(p.workers, 4);
    test:assertEquals(p.durationSeconds, 0);
    test:assertTrue(p.spike is (), "baseline pattern has no spike window");
    // Weights match patterns/baseline.yaml.
    test:assertEquals(p.weights.store, 30);
    test:assertEquals(p.weights.customer, 15);
    test:assertEquals(p.weights.inventory, 25);
    test:assertEquals(p.weights.invoice, 10);
    test:assertEquals(p.weights.'order, 20);
}

@test:Config {}
function testLoadPatternSpikeHasSpikeWindow() returns error? {
    Pattern p = check loadPattern("spike");
    test:assertEquals(p.name, "spike");
    Spike? s = p.spike;
    test:assertTrue(s is Spike, "spike pattern must declare a spike window");
    if s is Spike {
        test:assertEquals(s.afterSeconds, 60);
        test:assertEquals(s.rps, 25);
        test:assertEquals(s.forSeconds, 60);
    }
}

// ── currentRps (RPS schedule given elapsed time) ─────────────────────────────

@test:Config {}
function testCurrentRpsBaselineIsConstant() {
    Pattern p = {
        name: "t",
        baseRps: 5,
        workers: 4,
        durationSeconds: 0,
        weights: {store: 1, customer: 1, inventory: 1, invoice: 1, 'order: 1}
    };
    test:assertEquals(currentRps(p, 0), 5);
    test:assertEquals(currentRps(p, 30), 5);
    test:assertEquals(currentRps(p, 9999), 5);
}

@test:Config {}
function testCurrentRpsHonorsSpikeWindow() {
    Pattern p = {
        name: "spike",
        baseRps: 5,
        workers: 6,
        durationSeconds: 0,
        spike: {afterSeconds: 60, rps: 25, forSeconds: 60},
        weights: {store: 1, customer: 1, inventory: 1, invoice: 1, 'order: 1}
    };
    // Before the window.
    test:assertEquals(currentRps(p, 0), 5);
    test:assertEquals(currentRps(p, 59), 5);
    // Inside the window (inclusive start, exclusive end).
    test:assertEquals(currentRps(p, 60), 25, "spike starts at afterSeconds");
    test:assertEquals(currentRps(p, 119), 25);
    // After the window.
    test:assertEquals(currentRps(p, 120), 5, "spike ends after forSeconds");
    test:assertEquals(currentRps(p, 600), 5);
}

// ── pickDomainAt (deterministic weighted selection) ──────────────────────────

@test:Config {}
function testPickDomainAtRespectsCumulativeWeights() {
    // Total weight = 100; cumulative boundaries: store[0,30), customer[30,45),
    // inventory[45,70), invoice[70,80), order[80,100).
    Weights w = {store: 30, customer: 15, inventory: 25, invoice: 10, 'order: 20};
    test:assertEquals(pickDomainAt(w, 0.00d), "store");
    test:assertEquals(pickDomainAt(w, 0.29d), "store");
    test:assertEquals(pickDomainAt(w, 0.30d), "customer");
    test:assertEquals(pickDomainAt(w, 0.44d), "customer");
    test:assertEquals(pickDomainAt(w, 0.45d), "inventory");
    test:assertEquals(pickDomainAt(w, 0.69d), "inventory");
    test:assertEquals(pickDomainAt(w, 0.70d), "invoice");
    test:assertEquals(pickDomainAt(w, 0.79d), "invoice");
    test:assertEquals(pickDomainAt(w, 0.80d), "order");
    test:assertEquals(pickDomainAt(w, 0.99d), "order");
}

@test:Config {}
function testPickDomainAtZeroWeightsFallsBackToStore() {
    Weights w = {store: 0, customer: 0, inventory: 0, invoice: 0, 'order: 0};
    test:assertEquals(pickDomainAt(w, 0.0d), "store");
    test:assertEquals(pickDomainAt(w, 0.5d), "store");
    test:assertEquals(pickDomainAt(w, 0.99d), "store");
}

@test:Config {}
function testPickDomainAtSkipsZeroWeightDomains() {
    // Only `order` has weight; every roll must select it.
    Weights w = {store: 0, customer: 0, inventory: 0, invoice: 0, 'order: 10};
    test:assertEquals(pickDomainAt(w, 0.0d), "order");
    test:assertEquals(pickDomainAt(w, 0.5d), "order");
    test:assertEquals(pickDomainAt(w, 0.99d), "order");
}

// ── randInt / randSku (bounded randomness — sample invariants) ───────────────

@test:Config {}
function testRandIntStaysWithinInclusiveBounds() {
    int lo = 1;
    int hi = 5;
    int i = 0;
    while i < 200 {
        int n = randInt(lo, hi);
        test:assertTrue(n >= lo && n <= hi,
                string `randInt(${lo}, ${hi}) returned ${n} (out of range)`);
        i += 1;
    }
}

@test:Config {}
function testRandSkuShapeAndRange() {
    int i = 0;
    while i < 100 {
        string sku = randSku();
        test:assertTrue(sku.startsWith("SKU-00"),
                string `randSku() must start with "SKU-00", got "${sku}"`);
        test:assertEquals(sku.length(), 7, "randSku format is SKU-00X (7 chars)");
        i += 1;
    }
}
