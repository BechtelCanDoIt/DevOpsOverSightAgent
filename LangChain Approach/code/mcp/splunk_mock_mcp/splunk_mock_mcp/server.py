"""splunk-mock-mcp: FastMCP streamable-http mock of the Splunk MCP server.

Serves the 4 Splunk tools at /mcp (streamable-http) on 0.0.0.0:$PORT
(default 8400), plus a plain GET /health route. Ported from
splunk_mock_mcp.bal; tool names, descriptions, parameter defaults, and
result JSON shapes match the Ballerina source.

Run: python -m splunk_mock_mcp.server
"""

from __future__ import annotations

import json
import logging
import os

from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

from splunk_mock_mcp.mock_data import INDEXES, SAVED_SEARCHES, filter_events

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("splunk-mock-mcp")

mcp = FastMCP(
    "splunk-mock-mcp",
    host="0.0.0.0",
    port=int(os.environ.get("PORT", "8400")),
    stateless_http=True,
)


@mcp.tool()
def splunk_run_query(
    query: str,
    earliest: str = "-1h",
    latest: str = "now",
    max_results: int = 100,
) -> str:
    """Run an SPL query against Splunk (mock). Returns matching log events."""
    events = filter_events(query, max_results)
    return json.dumps({"query": query, "result_count": len(events), "events": events})


@mcp.tool()
def splunk_get_indexes() -> str:
    """List available Splunk indexes."""
    # The Ballerina tool returns the bare array (not wrapped in an object).
    return json.dumps(INDEXES)


@mcp.tool()
def splunk_get_knowledge_objects(object_type: str = "saved_searches") -> str:
    """Get knowledge objects like saved searches."""
    # Matches the Ballerina behavior: object_type is accepted but ignored;
    # saved searches are always returned.
    return json.dumps(SAVED_SEARCHES)


@mcp.tool()
def splunk_describe_query(query: str) -> str:
    """Explain what an SPL query does."""
    return json.dumps(
        {
            "query": query,
            "explanation": f"SPL query searches Splunk for: {query}",
            "estimated_events": 42,
        }
    )


@mcp.custom_route("/health", methods=["GET"])
async def health(_request: Request) -> JSONResponse:
    return JSONResponse({"status": "UP", "service": "splunk-mock-mcp"})


def main() -> None:
    logger.info(
        "starting splunk-mock-mcp (streamable-http) on %s:%d",
        mcp.settings.host,
        mcp.settings.port,
    )
    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    main()
