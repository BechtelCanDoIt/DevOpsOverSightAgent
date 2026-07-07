"""SplunkAgent — an A2A server wrapping a LangChain agent over the Splunk MCP.

Boot sequence mirrors DataDogAgent: OTel + LLM readiness, eagerly load the
Splunk MCP tools (retry while the mock comes up), build the ReAct agent, then
serve A2A JSON-RPC. The orchestrator reaches this agent via ``ask_splunk_agent``.

Run: python -m splunk_agent
"""

from __future__ import annotations

import asyncio
import logging

from a2a.types import AgentSkill
from langchain.agents import create_agent
from oversight_common.a2a_server import LangChainAgentExecutor, build_agent_card, run_a2a_agent
from oversight_common.config import env_or
from oversight_common.llm_factory import check_llm_ready, make_llm
from oversight_common.otel import setup_otel

from splunk_agent.mcp_client import SplunkMCPClient
from splunk_agent.prompts import SYSTEM_PROMPT

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("oversight")

SERVICE_NAME = "splunk-agent"
LLM_PREFIX = "SPLUNK_AGENT"

SKILL = AgentSkill(
    id="splunk_log_search",
    name="Search Splunk logs",
    description=(
        "Runs SPL queries against Splunk (indexes, saved searches, query "
        "explain). Correlates log events by trace_id/service and returns "
        "matching events with timestamps and messages."
    ),
    tags=["splunk", "logs", "spl", "indexes", "correlation"],
    examples=[
        "Run: index=main service=payment-service status=502 earliest=-1h",
        "Find all log events for trace_id abc123def456789012345678deadbeef.",
        "Which saved searches exist for error rate by service?",
    ],
)


async def build() -> LangChainAgentExecutor:
    setup_otel(SERVICE_NAME)
    check_llm_ready(LLM_PREFIX)
    tools = await SplunkMCPClient().load_tools()
    model = make_llm(LLM_PREFIX)
    agent = create_agent(model=model, tools=tools, system_prompt=SYSTEM_PROMPT, name="splunk-agent")
    return LangChainAgentExecutor(agent, csv_model_fallback=SERVICE_NAME)


def main() -> None:
    host = env_or("SPLUNK_AGENT_HOST", "0.0.0.0")
    port = int(env_or("SPLUNK_AGENT_PORT", "8102"))
    advertised = env_or("SPLUNK_AGENT_URL", f"http://splunk-agent:{port}")
    executor = asyncio.run(build())
    card = build_agent_card(
        name="SplunkAgent",
        description=(
            "Read-only Splunk investigator for the devops-poc mesh: SPL queries, "
            "indexes, saved searches, and query-explain — via the Splunk MCP server."
        ),
        url=advertised,
        skill=SKILL,
    )
    run_a2a_agent(card, executor, host, port)


if __name__ == "__main__":
    main()
