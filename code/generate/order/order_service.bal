import ballerina/http;
import ballerina/log;
import ballerina/random;
import ballerina/sql;
import ballerina/time;

import ballerinax/nats;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;

// ---------------------------------------------------------------------------
// Config / clients (all reads via envOr so local `bal run` works on defaults).
// ---------------------------------------------------------------------------

// Fixed demo unit price per item (USD). Total = sum(qty * UNIT_PRICE).
final decimal UNIT_PRICE = 19.99;

// Shared listener: hosts /health and /orders. Business + health on :9090.
listener http:Listener mainListener = new (9090);

// Downstream synchronous dependencies. HTTP trace-context propagates
// automatically, so each call becomes a child span of the /orders span.
final http:Client customerClient = check new (envOr("CUSTOMER_URL", "http://customer:9090"));
final http:Client inventoryClient = check new (envOr("INVENTORY_URL", "http://inventory:9090"));
final http:Client paymentClient = check new (envOr("PAYMENT_URL", "http://payment:9090"));
final http:Client invoiceClient = check new (envOr("INVOICE_URL", "http://invoice:9090"));

// Postgres (orderdb). Queries auto-traced as child spans.
final postgresql:Client|error db = new (
    host = envOr("DB_HOST", "postgres"),
    port = check int:fromString(envOr("DB_PORT", "5432")),
    username = envOr("DB_USER", "poc"),
    password = envOr("DB_PASSWORD", "pocpass"),
    database = envOr("DB_NAME", "orderdb"));

// NATS publisher for the async order -> notification leg.
final nats:Client|error natsClient = new (envOr("NATS_URL", "nats://nats:4222"));

const string ORDERS_SUBJECT = "orders.created";

// ---------------------------------------------------------------------------
// Request/response shapes.
// ---------------------------------------------------------------------------

type OrderItem record {|
    string sku;
    int qty;
|};

type OrderRequest record {|
    int customerId;
    OrderItem[] items;
|};

type ReserveResponse record {|
    boolean reserved;
|};

// ---------------------------------------------------------------------------
// Startup: ensure the orders table exists.
// ---------------------------------------------------------------------------

function init() {
    do {
        postgresql:Client dbClient = check db;
        _ = check dbClient->execute(`CREATE TABLE IF NOT EXISTS orders (
            id TEXT PRIMARY KEY,
            customer_id INT,
            total NUMERIC,
            status TEXT
        )`);
        logInfo("order-service initialized");
    } on fail var e {
        log:printWarn("DB unavailable at startup — schema init skipped", 'error = e);
    }
}

// ---------------------------------------------------------------------------
// Health.
// ---------------------------------------------------------------------------

service /health on mainListener {
    resource function get .() returns json => {status: "UP", 'service: "order-service"};
}

// ---------------------------------------------------------------------------
// Orchestrator.
// ---------------------------------------------------------------------------

service /orders on mainListener {

    resource function post .(@http:Payload OrderRequest req) returns http:Response {
        // Chaos gate first.
        int? injected = applyChaos();
        if injected is int {
            return chaosErrorResponse(injected);
        }

        [string, string] [tid, sid] = spanCtx();
        string orderId = newOrderId();
        log:printInfo("order received", trace_id = tid, span_id = sid,
                order_id = orderId, customer_id = req.customerId);

        // a. Validate customer -> GET {CUSTOMER_URL}/customers/{id}; 404/error -> 400.
        http:Response|error custResp = customerClient->get(string `/customers/${req.customerId}`);
        if custResp is error {
            logError("customer validation call failed", custResp);
            return errorResponse(400, "invalid customer");
        }
        if custResp.statusCode != 200 {
            log:printError("invalid customer", trace_id = tid, span_id = sid,
                    order_id = orderId, customer_id = req.customerId,
                    status = custResp.statusCode);
            return errorResponse(400, "invalid customer");
        }
        log:printInfo("customer validated", trace_id = tid, span_id = sid,
                order_id = orderId, customer_id = req.customerId);

        // b. Reserve stock -> POST {INVENTORY_URL}/reserve per item; reserved:false -> 409.
        decimal total = 0;
        foreach OrderItem item in req.items {
            json reserveBody = {sku: item.sku, qty: item.qty};
            ReserveResponse|error reserved = inventoryClient->post("/reserve", reserveBody);
            if reserved is error {
                logError("stock reservation call failed", reserved);
                return errorResponse(409, "stock reservation failed");
            }
            if !reserved.reserved {
                log:printError("stock not available", trace_id = tid, span_id = sid,
                        order_id = orderId, sku = item.sku, qty = item.qty);
                return errorResponse(409, "insufficient stock");
            }
            total += UNIT_PRICE * item.qty;
        }
        log:printInfo("stock reserved", trace_id = tid, span_id = sid,
                order_id = orderId, total = total);

        // c. Charge payment -> POST {PAYMENT_URL}/charge; error/non-2xx -> 502.
        // This is the headline failure path: surface a clean 502, logged with trace_id.
        json chargeBody = {amount: total, currency: "USD", orderId: orderId};
        http:Response|error chargeResp = paymentClient->post("/charge", chargeBody);
        if chargeResp is error {
            log:printError("payment failed", 'error = chargeResp, trace_id = tid,
                    span_id = sid, order_id = orderId, total = total);
            return errorResponse(502, "payment failed");
        }
        if chargeResp.statusCode < 200 || chargeResp.statusCode >= 300 {
            log:printError("payment failed", trace_id = tid, span_id = sid,
                    order_id = orderId, total = total, status = chargeResp.statusCode);
            return errorResponse(502, "payment failed");
        }
        log:printInfo("payment charged", trace_id = tid, span_id = sid,
                order_id = orderId, total = total);

        // d. Bill -> POST {INVOICE_URL}/invoices.
        json invoiceBody = {orderId: orderId, amount: total};
        http:Response|error invResp = invoiceClient->post("/invoices", invoiceBody);
        if invResp is error {
            log:printError("billing failed", 'error = invResp, trace_id = tid,
                    span_id = sid, order_id = orderId);
            return errorResponse(502, "billing failed");
        }
        if invResp.statusCode < 200 || invResp.statusCode >= 300 {
            log:printError("billing failed", trace_id = tid, span_id = sid,
                    order_id = orderId, status = invResp.statusCode);
            return errorResponse(502, "billing failed");
        }
        log:printInfo("invoice created", trace_id = tid, span_id = sid, order_id = orderId);

        // e. Persist the order (parameterized query).
        sql:ParameterizedQuery insert = `INSERT INTO orders (id, customer_id, total, status)
            VALUES (${orderId}, ${req.customerId}, ${total}, ${"confirmed"})`;
        postgresql:Client|error dbRef = db;
        if dbRef is error {
            log:printError("db unavailable", 'error = dbRef, trace_id = tid, span_id = sid,
                    order_id = orderId);
            return errorResponse(503, "db unavailable");
        }
        sql:ExecutionResult|error persisted = dbRef->execute(insert);
        if persisted is error {
            log:printError("order persist failed", 'error = persisted, trace_id = tid,
                    span_id = sid, order_id = orderId);
            return errorResponse(500, "order persist failed");
        }
        log:printInfo("order persisted", trace_id = tid, span_id = sid, order_id = orderId);

        // f. Publish to NATS with W3C trace context so notification's async leg
        //    joins the same trace_id in Splunk.
        error? published = publishOrderCreated(orderId, req.customerId, total);
        if published is error {
            // Non-fatal: the order is committed; log and continue.
            log:printError("order event publish failed", 'error = published, trace_id = tid,
                    span_id = sid, order_id = orderId);
        } else {
            log:printInfo("order event published", trace_id = tid, span_id = sid,
                    order_id = orderId, subject = ORDERS_SUBJECT);
        }

        log:printInfo("order confirmed", trace_id = tid, span_id = sid,
                order_id = orderId, status = "confirmed", total = total);
        return okResponse({orderId: orderId, status: "confirmed", total: total});
    }
}

// ---------------------------------------------------------------------------
// NATS publish with W3C traceparent envelope (order -> notification).
// ---------------------------------------------------------------------------

isolated function publishOrderCreated(string orderId, int customerId, decimal total) returns error? {
    [string, string] [tid, sid] = spanCtx();
    string traceparent = buildTraceparent(tid, sid);
    json envelope = {
        orderId: orderId,
        customerId: customerId,
        total: total,
        traceparent: traceparent
    };
    nats:Client nc = check natsClient;
    check nc->publishMessage({subject: ORDERS_SUBJECT, content: envelope});
}

// Builds a W3C traceparent header value from the active OTel trace/span IDs.
// Format: `00-<32-hex traceId>-<16-hex spanId>-01`. Kept as a pure function so
// the cross-system correlation contract (see CONVENTIONS.md "NATS trace-propagation
// envelope") is unit-testable without a live NATS connection.
isolated function buildTraceparent(string traceId, string spanId) returns string {
    return string `00-${traceId}-${spanId}-01`;
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

// Timestamp + random suffix order id (avoids pulling the uuid module).
isolated function newOrderId() returns string {
    int millis = time:utcNow()[0] * 1000 + <int>(time:utcNow()[1] * 1000);
    int suffix = checkpanic random:createIntInRange(1000, 9999);
    return string `ORD-${millis}-${suffix}`;
}

isolated function okResponse(json payload) returns http:Response {
    http:Response r = new;
    r.statusCode = 200;
    r.setPayload(payload);
    return r;
}

isolated function errorResponse(int status, string message) returns http:Response {
    http:Response r = new;
    r.statusCode = status;
    r.setPayload({'error: message});
    return r;
}
