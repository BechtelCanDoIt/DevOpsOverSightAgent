import ballerina/http;
import ballerina/log;
import ballerina/uuid;

listener http:Listener mainListener = new (9090);

// ---- Request / response shapes ----

type ChargeRequest record {|
    decimal amount;
    string currency = "USD";
    string orderId;
|};

type ChargeResponse record {|
    string paymentId;
    string status;
    decimal amount;
    string authId;
    string note;
|};

// ---- In-process mock bank (no real I/O, no downstream, no DB) ----

type BankAuthorization record {|
    string authId;
    boolean approved;
    string note;
|};

// Simulates a bank authorization response. Plain in-process function — returns a
// dummy approval with a generated auth id. No external call, no database.
isolated function mockBankAuthorize(decimal amount, string currency) returns BankAuthorization => {
    authId: "AUTH-" + uuid:createType1AsString(),
    approved: true,
    note: string `mock-bank approved ${currency} ${amount} (simulated)`
};

// ---- Services ----

service /health on mainListener {
    isolated resource function get .() returns json => {status: "UP", 'service: "payment-service"};
}

service /charge on mainListener {
    isolated resource function post .(@http:Payload ChargeRequest req)
            returns ChargeResponse|http:Response {
        // Chaos gate first — payment-service is the headline demo target.
        int? injected = applyChaos();
        if injected is int {
            logError(string `charge rejected by chaos for order ${req.orderId} (status ${injected})`);
            return chaosErrorResponse(injected);
        }

        BankAuthorization auth = mockBankAuthorize(req.amount, req.currency);
        string paymentId = "PAY-" + uuid:createType1AsString();

        [string, string] [tid, sid] = spanCtx();
        log:printInfo("charge processed", trace_id = tid, span_id = sid,
                order_id = req.orderId, payment_id = paymentId,
                amount = req.amount, currency = req.currency, auth_id = auth.authId);

        return {
            paymentId: paymentId,
            status: auth.approved ? "approved" : "declined",
            amount: req.amount,
            authId: auth.authId,
            note: auth.note
        };
    }
}
