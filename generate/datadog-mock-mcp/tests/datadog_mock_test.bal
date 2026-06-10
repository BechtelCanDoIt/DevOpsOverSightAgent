import ballerina/test;

@test:Config {}
function testLookupKnownMetric() {
    MetricSeries? ms = lookupMetric("payment.request.errors");
    test:assertFalse(ms is (), "payment.request.errors must be in mock metrics");
    if ms is MetricSeries {
        test:assertTrue(ms.series.length() > 0, "metric must have data points");
    }
}

@test:Config {}
function testMetricSpikeVisible() {
    MetricSeries? ms = lookupMetric("payment.request.errors");
    if ms is MetricSeries {
        decimal maxVal = 0.0d;
        foreach MetricPoint p in ms.series {
            if p.value > maxVal {
                maxVal = p.value;
            }
        }
        test:assertTrue(maxVal > 10.0d, "mock data must show error spike above 10");
    }
}

@test:Config {}
function testLookupUnknownMetricReturnsNil() {
    test:assertTrue(lookupMetric("no.such.metric.xyz") is (), "unknown metric returns ()");
}

@test:Config {}
function testFuzzyMetricLookup() {
    // "payment" prefix should match payment.request.errors
    MetricSeries? ms = lookupMetric("payment.latency");
    test:assertFalse(ms is (), "fuzzy lookup on payment prefix must find a metric");
}

@test:Config {}
function testMockTraceHasFourSpans() {
    test:assertEquals(MOCK_TRACE.spans.length(), 4);
}

@test:Config {}
function testMockTracePaymentSpanIsError() {
    boolean found = false;
    foreach ApmSpan s in MOCK_TRACE.spans {
        if s.'service == "payment-service" {
            found = true;
            test:assertEquals(s.status, "error", "payment-service span must be error");
        }
    }
    test:assertTrue(found, "must have a payment-service span in demo trace");
}

@test:Config {}
function testFilterMonitorsNoQuery() {
    MonitorRecord[] monitors = filterMonitors("");
    test:assertEquals(monitors.length(), 3, "must return all 3 mock monitors");
}

@test:Config {}
function testFilterMonitorsAlertingMonitor() {
    MonitorRecord[] monitors = filterMonitors("payment-service");
    test:assertTrue(monitors.length() >= 1, "must find payment-service monitor");
    boolean hasAlert = false;
    foreach MonitorRecord m in monitors {
        if m.status == "Alert" {
            hasAlert = true;
        }
    }
    test:assertTrue(hasAlert, "payment-service monitor must be in Alert state");
}

@test:Config {}
function testFilterLogsNoQuery() {
    test:assertEquals(filterLogs("").length(), MOCK_LOGS.length());
}

@test:Config {}
function testFilterLogsPaymentService() {
    LogRecord[] logs = filterLogs("payment-service");
    test:assertTrue(logs.length() >= 1);
    foreach LogRecord l in logs {
        test:assertTrue(l.'service.includes("payment"));
    }
}

@test:Config {}
function testDemoTraceIdInLogs() {
    boolean found = false;
    foreach LogRecord l in MOCK_LOGS {
        if l.trace_id == DD_DEMO_TRACE_ID {
            found = true;
        }
    }
    test:assertTrue(found, "mock logs must include the demo trace_id");
}
