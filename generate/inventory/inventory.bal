import ballerina/http;
import ballerina/sql;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;
import ballerinax/redis;

// Shared listener: business routes + /health.
listener http:Listener mainListener = new (9090);

// ── Data layer clients ───────────────────────────────────────────────────────

final postgresql:Client|error db = new (
    host = envOr("DB_HOST", "postgres"),
    port = check int:fromString(envOr("DB_PORT", "5432")),
    username = envOr("DB_USER", "poc"),
    password = envOr("DB_PASSWORD", "pocpass"),
    database = envOr("DB_NAME", "inventorydb")
);

final redis:Client|error cache = new (connection = {
    host: envOr("REDIS_HOST", "redis"),
    port: check int:fromString(envOr("REDIS_PORT", "6379"))
});

// ── Domain types ─────────────────────────────────────────────────────────────

type ReserveReq record {|
    string sku;
    int qty;
|};

isolated function cacheKey(string sku) returns string => string `stock:${sku}`;

// Pure reservation guard — true iff `qty` units can be reserved against `current` on-hand.
// Rejects non-positive requests and any draw that would go negative.
isolated function canReserve(int current, int qty) returns boolean =>
    qty > 0 && current >= qty;

// ── Startup: schema + seed ────────────────────────────────────────────────────

function init() {
    do {
        postgresql:Client dbClient = check db;
        _ = check dbClient->execute(`CREATE TABLE IF NOT EXISTS stock (sku TEXT PRIMARY KEY, qty INT)`);
        int count = check dbClient->queryRow(`SELECT COUNT(*) FROM stock`);
        if count == 0 {
            string[] skus = ["SKU-001", "SKU-002", "SKU-003", "SKU-004", "SKU-005"];
            foreach string sku in skus {
                _ = check dbClient->execute(`INSERT INTO stock (sku, qty) VALUES (${sku}, ${100})
                    ON CONFLICT (sku) DO NOTHING`);
            }
            logInfo("seeded stock table with SKU-001..SKU-005");
        }
        logInfo("inventory-service started");
    } on fail var e {
        logError("DB unavailable at startup — schema init skipped", e);
    }
}

// ── DB helpers ────────────────────────────────────────────────────────────────

// Read qty from Postgres; nil when the SKU is unknown.
isolated function dbQty(string sku) returns int|error? {
    postgresql:Client dbClient = check db;
    int|sql:Error r = dbClient->queryRow(`SELECT qty FROM stock WHERE sku = ${sku}`);
    if r is sql:NoRowsError {
        return ();
    }
    return r;
}

// ── Service ───────────────────────────────────────────────────────────────────

service /health on mainListener {
    resource function get .() returns json => {status: "UP", 'service: "inventory-service"};
}

service /stock on mainListener {

    // GET /stock/{sku} → {sku, qty, source: "cache"|"db"}
    // Redis first; on miss fall back to Postgres and populate the cache (cold-cache story).
    isolated resource function get [string sku]() returns json|http:Response|http:NotFound {
        int? injected = applyChaos();
        if injected is int {
            return chaosErrorResponse(injected);
        }

        // Cache lookup (graceful on Redis errors or unavailability → treat as miss).
        redis:Client|error cacheRef = cache;
        string|redis:Error? cached;
        if cacheRef is redis:Client {
            cached = cacheRef->get(cacheKey(sku));
        } else {
            cached = ();
        }
        if cached is string {
            int|error qty = int:fromString(cached);
            if qty is int {
                logInfo(string `stock hit cache sku=${sku}`);
                return {sku, qty, 'source: "cache"};
            }
        } else if cached is redis:Error {
            logError(string `redis get failed for sku=${sku}, falling back to db`, cached);
        }

        // Cache miss → Postgres.
        int|error? qty = dbQty(sku);
        if qty is error {
            logError(string `db read failed for sku=${sku}`, qty);
            http:Response r = new;
            r.statusCode = 500;
            r.setPayload({'error: "db-read-failed", sku});
            return r;
        }
        if qty is () {
            return http:NOT_FOUND;
        }

        // Populate cache for next time (best-effort).
        if cacheRef is redis:Client {
            string|redis:Error setRes = cacheRef->set(cacheKey(sku), qty.toString());
            if setRes is redis:Error {
                logError(string `redis set failed for sku=${sku}`, setRes);
            }
        }
        logInfo(string `stock miss db sku=${sku}`);
        return {sku, qty, 'source: "db"};
    }
}

service /reserve on mainListener {

    // POST /reserve {sku, qty} → {sku, reserved, remaining}
    // Reads available (cache→db), decrements in Postgres if enough, refreshes the cache.
    isolated resource function post .(@http:Payload ReserveReq req) returns json|http:Response|http:NotFound {
        int? injected = applyChaos();
        if injected is int {
            return chaosErrorResponse(injected);
        }

        // Determine current available qty: cache first, then db.
        redis:Client|error cacheRef = cache;
        int? fromCache = ();
        string|redis:Error? cached;
        if cacheRef is redis:Client {
            cached = cacheRef->get(cacheKey(req.sku));
        } else {
            cached = ();
        }
        if cached is string {
            int|error c = int:fromString(cached);
            if c is int {
                fromCache = c;
            }
        } else if cached is redis:Error {
            logError(string `redis get failed for sku=${req.sku}, falling back to db`, cached);
        }

        int current;
        if fromCache is int {
            current = fromCache;
        } else {
            int|error? dbVal = dbQty(req.sku);
            if dbVal is error {
                logError(string `db read failed for sku=${req.sku}`, dbVal);
                http:Response r = new;
                r.statusCode = 500;
                r.setPayload({'error: "db-read-failed", sku: req.sku});
                return r;
            }
            if dbVal is () {
                return http:NOT_FOUND;
            }
            current = dbVal;
        }

        if !canReserve(current, req.qty) {
            logInfo(string `reserve denied sku=${req.sku} want=${req.qty} have=${current}`);
            return {sku: req.sku, reserved: false, remaining: current};
        }

        // Decrement in Postgres (authoritative).
        postgresql:Client|error dbRef = db;
        if dbRef is error {
            logError(string `db unavailable for sku=${req.sku}`, dbRef);
            http:Response r = new;
            r.statusCode = 503;
            r.setPayload({'error: "db-unavailable", sku: req.sku});
            return r;
        }
        sql:ExecutionResult|sql:Error res =
            dbRef->execute(`UPDATE stock SET qty = qty - ${req.qty} WHERE sku = ${req.sku}`);
        if res is sql:Error {
            logError(string `reserve db update failed for sku=${req.sku}`, res);
            http:Response r = new;
            r.statusCode = 500;
            r.setPayload({'error: "db-update-failed", sku: req.sku});
            return r;
        }

        int remaining = current - req.qty;

        // Refresh the cache entry with the new value (best-effort; on error invalidate).
        if cacheRef is redis:Client {
            string|redis:Error setRes = cacheRef->set(cacheKey(req.sku), remaining.toString());
            if setRes is redis:Error {
                logError(string `redis update failed for sku=${req.sku}, invalidating`, setRes);
                int|redis:Error delRes = cacheRef->del([cacheKey(req.sku)]);
                if delRes is redis:Error {
                    logError(string `redis invalidate failed for sku=${req.sku}`, delRes);
                }
            }
        }

        logInfo(string `reserved sku=${req.sku} qty=${req.qty} remaining=${remaining}`);
        return {sku: req.sku, reserved: true, remaining};
    }
}
