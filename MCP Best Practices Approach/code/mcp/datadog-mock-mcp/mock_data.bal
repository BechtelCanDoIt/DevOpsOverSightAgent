// Demo scenario: payment-service 502 spike — metric time series, trace, monitors.

final string DD_DEMO_TRACE_ID = "abc123def456789012345678deadbeef";

type MetricPoint record {|
    int timestamp;
    decimal value;
|};

type MetricSeries record {|
    string metric;
    string display_name;
    string unit;
    MetricPoint[] series;
|};

final map<MetricSeries> & readonly MOCK_METRICS = {
    "payment.request.errors": {
        metric: "payment.request.errors", display_name: "Payment Request Errors", unit: "count",
        series: [
            {timestamp: 1749470400, value: 2.0d}, {timestamp: 1749470460, value: 18.0d},
            {timestamp: 1749470520, value: 47.0d}, {timestamp: 1749470580, value: 53.0d},
            {timestamp: 1749470640, value: 12.0d}
        ]
    },
    "payment.request.duration": {
        metric: "payment.request.duration", display_name: "Payment Duration (ms)", unit: "millisecond",
        series: [
            {timestamp: 1749470400, value: 120.0d}, {timestamp: 1749470460, value: 1850.0d},
            {timestamp: 1749470520, value: 2150.0d}, {timestamp: 1749470580, value: 2200.0d},
            {timestamp: 1749470640, value: 250.0d}
        ]
    },
    "order.request.errors": {
        metric: "order.request.errors", display_name: "Order Request Errors", unit: "count",
        series: [
            {timestamp: 1749470400, value: 0.0d}, {timestamp: 1749470460, value: 15.0d},
            {timestamp: 1749470520, value: 40.0d}, {timestamp: 1749470580, value: 45.0d}
        ]
    }
};

type ApmSpan record {|
    string 'service;
    string operation;
    int duration_ms;
    string status;
    string? 'error = ();
|};

type TraceData record {|
    string trace_id;
    ApmSpan[] spans;
    string[] services;
|};

final TraceData MOCK_TRACE = {
    trace_id: DD_DEMO_TRACE_ID,
    spans: [
        {'service: "order-service", operation: "POST /orders", duration_ms: 4400, status: "error"},
        {'service: "customer-service", operation: "GET /customers/{id}", duration_ms: 45, status: "ok"},
        {'service: "inventory-service", operation: "POST /reserve", duration_ms: 55, status: "ok"},
        {'service: "payment-service", operation: "POST /charge", duration_ms: 2150, status: "error", 'error: "502 Bad Gateway"}
    ],
    services: ["order-service", "customer-service", "inventory-service", "payment-service"]
};

type MonitorRecord record {|
    string id;
    string name;
    string status;
    string 'type;
    string[] tags;
|};

final MonitorRecord[] & readonly MOCK_MONITORS = [
    {id: "MON-001", name: "payment-service error rate > 10%", status: "Alert", 'type: "metric alert",
     tags: ["service:payment-service", "env:demo"]},
    {id: "MON-002", name: "order-service p99 latency > 2s", status: "OK", 'type: "metric alert",
     tags: ["service:order-service"]},
    {id: "MON-003", name: "inventory cache miss rate spike", status: "OK", 'type: "metric alert",
     tags: ["service:inventory-service"]}
];

type LogRecord record {|
    string timestamp;
    string 'service;
    string message;
    string status;
    string trace_id;
|};

final LogRecord[] & readonly MOCK_LOGS = [
    {timestamp: "2026-06-09T10:00:01Z", 'service: "payment-service", message: "POST /charge 502 Bad Gateway", status: "error", trace_id: DD_DEMO_TRACE_ID},
    {timestamp: "2026-06-09T10:00:02Z", 'service: "order-service", message: "payment charge failed — retrying", status: "warn", trace_id: DD_DEMO_TRACE_ID},
    {timestamp: "2026-06-09T10:00:03Z", 'service: "payment-service", message: "POST /charge 502 Bad Gateway", status: "error", trace_id: DD_DEMO_TRACE_ID}
];

isolated function lookupMetric(string name) returns MetricSeries? {
    MetricSeries? m = MOCK_METRICS[name];
    if m is MetricSeries {
        return m;
    }
    // Fuzzy: first word match
    int? dotIdx = name.indexOf(".");
    string prefix = dotIdx is int ? name.substring(0, dotIdx) : name;
    foreach var [k, v] in MOCK_METRICS.entries() {
        if k.startsWith(prefix) {
            return v;
        }
    }
    return ();
}

isolated function filterMonitors(string query) returns MonitorRecord[] {
    if query == "" {
        return MOCK_MONITORS.clone();
    }
    MonitorRecord[] results = [];
    foreach MonitorRecord m in MOCK_MONITORS {
        if m.name.toLowerAscii().includes(query.toLowerAscii()) {
            results.push(m);
        } else {
            boolean tagMatched = false;
            foreach string t in m.tags {
                if t.includes(query.toLowerAscii()) {
                    tagMatched = true;
                    break;
                }
            }
            if tagMatched {
                results.push(m);
            }
        }
    }
    return results;
}

isolated function filterLogs(string query) returns LogRecord[] {
    if query == "" {
        return MOCK_LOGS.clone();
    }
    LogRecord[] results = [];
    foreach LogRecord l in MOCK_LOGS {
        if l.message.toLowerAscii().includes(query.toLowerAscii()) || l.'service.includes(query) {
            results.push(l);
        }
    }
    return results;
}
