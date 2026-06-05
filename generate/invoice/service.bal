import ballerina/http;
import ballerina/sql;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;

// Shared listener: hosts both /health and the business routes.
listener http:Listener mainListener = new (9090);

final postgresql:Client db = check new (
    host = envOr("DB_HOST", "postgres"),
    port = check int:fromString(envOr("DB_PORT", "5432")),
    username = envOr("DB_USER", "poc"),
    password = envOr("DB_PASSWORD", "pocpass"),
    database = envOr("DB_NAME", "invoicedb")
);

// Wire shape returned to callers.
type Invoice record {|
    int invoiceId;
    string orderId;
    decimal amount;
    string status;
|};

// Request body for invoice creation (order-service posts this during checkout).
type NewInvoice record {|
    string orderId;
    decimal amount;
|};

// Row as stored in Postgres.
type InvoiceRow record {|
    int id;
    string order_id;
    decimal amount;
    string status;
|};

// Pure helpers (kept module-level for unit testing).

// Validate a NewInvoice request body: orderId must be non-empty and amount > 0.
// Returns an error with a human-readable reason when invalid.
isolated function validateNewInvoice(NewInvoice req) returns error? {
    if req.orderId.trim().length() == 0 {
        return error("orderId must not be empty");
    }
    if req.amount <= 0d {
        return error("amount must be positive");
    }
}

// Map a stored Postgres row into the wire-shape Invoice returned to callers.
isolated function rowToInvoice(InvoiceRow r) returns Invoice =>
    {invoiceId: r.id, orderId: r.order_id, amount: r.amount, status: r.status};

// Build the wire-shape Invoice for a freshly-issued invoice.
isolated function newIssuedInvoice(int invoiceId, NewInvoice req) returns Invoice =>
    {invoiceId, orderId: req.orderId, amount: req.amount, status: "issued"};

// Create the table on startup (idempotent).
function init() returns error? {
    _ = check db->execute(`CREATE TABLE IF NOT EXISTS invoices (
        id SERIAL PRIMARY KEY,
        order_id TEXT,
        amount NUMERIC,
        status TEXT
    )`);
    logInfo("invoice-service schema ready");
}

service /health on mainListener {
    resource function get .() returns json => {status: "UP", 'service: "invoice-service"};
}

service /invoices on mainListener {

    // Create an invoice (called by order-service during checkout).
    isolated resource function post .(@http:Payload NewInvoice req) returns Invoice|http:Response|error {
        int? injected = applyChaos();
        if injected is int {
            return chaosErrorResponse(injected);
        }
        check validateNewInvoice(req);
        sql:ParameterizedQuery insert = `INSERT INTO invoices (order_id, amount, status)
            VALUES (${req.orderId}, ${req.amount}, 'issued') RETURNING id`;
        int invoiceId = check db->queryRow(insert);
        logInfo(string `invoice issued: ${invoiceId} for order ${req.orderId}`);
        return newIssuedInvoice(invoiceId, req);
    }

    // Fetch a single invoice, or 404.
    isolated resource function get [int id]() returns Invoice|http:NotFound|http:Response|error {
        int? injected = applyChaos();
        if injected is int {
            return chaosErrorResponse(injected);
        }
        sql:ParameterizedQuery q = `SELECT id, order_id, amount, status FROM invoices WHERE id = ${id}`;
        InvoiceRow|sql:Error row = db->queryRow(q);
        if row is sql:NoRowsError {
            logInfo(string `invoice not found: ${id}`);
            return http:NOT_FOUND;
        }
        InvoiceRow r = check row;
        return rowToInvoice(r);
    }

    // Mark an invoice paid; returns the updated invoice (404 if absent).
    isolated resource function post [int id]/pay() returns Invoice|http:NotFound|http:Response|error {
        int? injected = applyChaos();
        if injected is int {
            return chaosErrorResponse(injected);
        }
        sql:ParameterizedQuery update = `UPDATE invoices SET status = 'paid' WHERE id = ${id}`;
        sql:ExecutionResult res = check db->execute(update);
        if (res.affectedRowCount ?: 0) == 0 {
            logInfo(string `invoice not found for pay: ${id}`);
            return http:NOT_FOUND;
        }
        sql:ParameterizedQuery q = `SELECT id, order_id, amount, status FROM invoices WHERE id = ${id}`;
        InvoiceRow r = check db->queryRow(q);
        logInfo(string `invoice paid: ${id}`);
        return rowToInvoice(r);
    }
}
