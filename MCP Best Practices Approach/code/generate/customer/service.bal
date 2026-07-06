import ballerina/http;
import ballerina/sql;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;

// Shared listener: hosts both /health and the business routes.
listener http:Listener mainListener = new (9090);

// ---- Data types ----
type NewCustomer record {|
    string name;
    string email;
|};

type Customer record {|
    int id;
    string name;
    string email;
|};

// ---- Postgres client (connection read from env, with compose defaults) ----
final postgresql:Client|error db = new (
    host = envOr("DB_HOST", "postgres"),
    port = check int:fromString(envOr("DB_PORT", "5432")),
    username = envOr("DB_USER", "poc"),
    password = envOr("DB_PASSWORD", "pocpass"),
    database = envOr("DB_NAME", "customerdb")
);

// On startup: ensure the schema exists and seed ~5 customers (ids 1..5) when empty,
// so order-service's varied customerIds resolve.
function init() {
    do {
        postgresql:Client dbClient = check db;
        _ = check dbClient->execute(`CREATE TABLE IF NOT EXISTS customers (
            id SERIAL PRIMARY KEY,
            name TEXT,
            email TEXT
        )`);
        int count = check dbClient->queryRow(`SELECT count(*) FROM customers`);
        if count == 0 {
            NewCustomer[] seed = [
                {name: "Alice Johnson", email: "alice@example.com"},
                {name: "Bob Smith", email: "bob@example.com"},
                {name: "Carol Diaz", email: "carol@example.com"},
                {name: "Dan Wright", email: "dan@example.com"},
                {name: "Eve Park", email: "eve@example.com"}
            ];
            foreach NewCustomer c in seed {
                _ = check dbClient->execute(`INSERT INTO customers (name, email) VALUES (${c.name}, ${c.email})`);
            }
            logInfo("seeded customers table");
        }
        logInfo("customer-service started");
    } on fail var e {
        logError("DB unavailable at startup — schema init skipped", e);
    }
}

// ---- Health ----
service /health on mainListener {
    resource function get .() returns json => {status: "UP", 'service: "customer-service"};
}

// ---- Business routes ----
service /customers on mainListener {

    // Create a customer profile.
    isolated resource function post .(@http:Payload NewCustomer payload) returns Customer|http:Response|error {
        int? injected = applyChaos();
        if injected is int {
            return chaosErrorResponse(injected);
        }
        postgresql:Client dbClient = check db;
        sql:ExecutionResult res = check dbClient->execute(
            `INSERT INTO customers (name, email) VALUES (${payload.name}, ${payload.email})`);
        int|string? lastId = res.lastInsertId;
        int id = lastId is int ? lastId : check getLastCustomerId();
        logInfo("created customer");
        return {id, name: payload.name, email: payload.email};
    }

    // Look up a customer; 404 when missing (order-service validation depends on this).
    isolated resource function get [int id]() returns Customer|http:NotFound|http:Response|error {
        int? injected = applyChaos();
        if injected is int {
            return chaosErrorResponse(injected);
        }
        postgresql:Client dbClient = check db;
        Customer|sql:Error result = dbClient->queryRow(
            `SELECT id, name, email FROM customers WHERE id = ${id}`);
        if result is sql:NoRowsError {
            logInfo("customer not found");
            return http:NOT_FOUND;
        }
        if result is sql:Error {
            logError("customer lookup failed", result);
            return result;
        }
        logInfo("fetched customer");
        return result;
    }
}

// Fallback when the JDBC driver does not surface a generated key.
isolated function getLastCustomerId() returns int|error {
    postgresql:Client dbClient = check db;
    int id = check dbClient->queryRow(`SELECT max(id) FROM customers`);
    return id;
}

// ---- Pure helpers (unit-testable; no DB) ----

// Build a Customer response record from a generated id + the inbound payload.
isolated function buildCustomer(int id, NewCustomer payload) returns Customer =>
    {id, name: payload.name, email: payload.email};

// Lightweight validation for inbound customer payloads. Returns an error
// describing the first problem found, or () when the payload is acceptable.
// (Kept defensive but loose: real schema validation is at the DB/JSON binding.)
isolated function validateNewCustomer(NewCustomer payload) returns error? {
    if payload.name.trim() == "" {
        return error("customer name must be non-empty");
    }
    if payload.email.trim() == "" {
        return error("customer email must be non-empty");
    }
    if payload.email.indexOf("@") is () {
        return error("customer email must contain '@'");
    }
    return ();
}

// Validate a path-supplied customer id (route accepts int, but we still gate
// on positivity for defensive logging / future-proofing against route changes).
isolated function isValidCustomerId(int id) returns boolean => id > 0;
