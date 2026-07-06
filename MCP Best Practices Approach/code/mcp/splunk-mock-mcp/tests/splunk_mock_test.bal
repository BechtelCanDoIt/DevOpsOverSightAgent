import ballerina/test;

@test:Config {}
function testFilterEventsNoFilter() {
    LogEvent[] events = filterEvents("index=devops-poc");
    test:assertEquals(events.length(), MOCK_EVENTS.length());
}

@test:Config {}
function testFilterEventsByTraceId() {
    LogEvent[] events = filterEvents(string `index=* trace_id="${DEMO_TRACE_ID}"`);
    test:assertTrue(events.length() > 0, "must find events for demo trace_id");
    foreach LogEvent e in events {
        test:assertTrue(e.trace_id.startsWith("abc123"), "filtered events must match trace_id prefix");
    }
}

@test:Config {}
function testFilterEventsBy502() {
    LogEvent[] events = filterEvents("index=devops-poc status=502");
    test:assertTrue(events.length() > 0, "must find 502 events");
    foreach LogEvent e in events {
        test:assertTrue(e.status >= 400);
    }
}

@test:Config {}
function testIndexesNotEmpty() {
    test:assertTrue(INDEXES.length() > 0);
    boolean hasMain = false;
    foreach string idx in INDEXES {
        if idx == "main" {
            hasMain = true;
        }
    }
    test:assertTrue(hasMain, "indexes must include 'main'");
}

@test:Config {}
function testSavedSearchesNotEmpty() {
    test:assertTrue(SAVED_SEARCHES.length() > 0);
}

@test:Config {}
function testDemoTraceIdIsHex() {
    test:assertTrue(DEMO_TRACE_ID.length() == 32, "demo trace_id must be 32 hex chars");
}

@test:Config {}
function testMockEventsContainPaymentService() {
    boolean found = false;
    foreach LogEvent e in MOCK_EVENTS {
        if e.'service == "payment-service" {
            found = true;
        }
    }
    test:assertTrue(found, "mock events must include payment-service events");
}

@test:Config {}
function testMockEventsContain502Status() {
    boolean found = false;
    foreach LogEvent e in MOCK_EVENTS {
        if e.status == 502 {
            found = true;
        }
    }
    test:assertTrue(found, "mock events must include 502 status events");
}
