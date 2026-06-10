// Mock log events representing the demo incident scenario.
// payment-service 502 spike with a consistent trace_id.

final string DEMO_TRACE_ID = "abc123def456789012345678deadbeef";

type LogEvent record {|
    string _time;
    string 'service;
    string trace_id;
    string span_id;
    string message;
    int status;
    int latency_ms;
|};

final LogEvent[] & readonly MOCK_EVENTS = [
    {_time: "2026-06-09T10:00:01Z", 'service: "payment-service", trace_id: DEMO_TRACE_ID, span_id: "1234567890abcdef", message: "POST /charge HTTP/1.1 502 Bad Gateway", status: 502, latency_ms: 2150},
    {_time: "2026-06-09T10:00:02Z", 'service: "order-service", trace_id: DEMO_TRACE_ID, span_id: "fedcba0987654321", message: "payment charge failed — retrying", status: 200, latency_ms: 2200},
    {_time: "2026-06-09T10:00:03Z", 'service: "payment-service", trace_id: DEMO_TRACE_ID, span_id: "1234567890abcdef", message: "POST /charge HTTP/1.1 502 Bad Gateway", status: 502, latency_ms: 2100},
    {_time: "2026-06-09T10:00:04Z", 'service: "order-service", trace_id: DEMO_TRACE_ID, span_id: "fedcba0987654321", message: "order creation failed: payment-service 502", status: 500, latency_ms: 4400},
    {_time: "2026-06-09T10:01:00Z", 'service: "inventory-service", trace_id: "99887766554433221100ffeeddccbbaa", span_id: "aabbccdd11223344", message: "cache miss — falling back to postgres", status: 200, latency_ms: 450},
    {_time: "2026-06-09T10:02:00Z", 'service: "notification-service", trace_id: "11223344556677889900aabbccddeeff", span_id: "0011223344556677", message: "order confirmation sent — order_id=ORD-001", status: 200, latency_ms: 55}
];

final string[] & readonly INDEXES = ["main", "devops-poc", "logs", "traces", "metrics"];

type SavedSearch record {|
    string name;
    string search;
|};

final SavedSearch[] & readonly SAVED_SEARCHES = [
    {name: "Error Rate by Service", search: "index=devops-poc status>=400 | stats count by service | sort -count"},
    {name: "P99 Latency by Service", search: "index=devops-poc | stats p99(latency_ms) by service"},
    {name: "payment-service 502s", search: "index=devops-poc service=payment-service status=502"},
    {name: "Trace Correlation", search: "index=devops-poc trace_id=$trace_id$ | table _time,service,message,span_id"}
];

// Filter events by query string. Simple heuristic: check for trace_id=, service=, and error keywords.
isolated function filterEvents(string query) returns LogEvent[] {
    LogEvent[] events = MOCK_EVENTS.clone();

    // trace_id filter
    if query.includes("trace_id=") {
        int? idx = query.indexOf("trace_id=");
        if idx is int {
            string remainder = re`"`.replaceAll(query.substring(idx + 9), "");
            string tid;
            int? spaceIdx = remainder.indexOf(" ");
            if spaceIdx is int {
                tid = remainder.substring(0, spaceIdx);
            } else {
                tid = remainder;
            }
            int prefixLen = tid.length() > 8 ? 8 : tid.length();
            string prefix = tid.substring(0, prefixLen);
            LogEvent[] filtered = [];
            foreach LogEvent e in events {
                if e.trace_id.startsWith(prefix) {
                    filtered.push(e);
                }
            }
            events = filtered;
        }
    }

    // error/502 filter
    if query.includes("502") || query.toLowerAscii().includes("error") {
        LogEvent[] filtered = [];
        foreach LogEvent e in events {
            if e.status >= 400 {
                filtered.push(e);
            }
        }
        if filtered.length() > 0 {
            events = filtered;
        }
    }

    return events;
}
