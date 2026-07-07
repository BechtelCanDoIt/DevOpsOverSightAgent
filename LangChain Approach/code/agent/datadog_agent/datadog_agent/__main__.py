"""DataDogAgent — an A2A server wrapping a LangChain agent over the Datadog MCP.

Boot sequence: OTel + LLM readiness probe, eagerly load the Datadog MCP tools
(retry while the mock comes up), build the ReAct agent, then serve A2A
JSON-RPC. The orchestrator reaches this agent via ``ask_datadog_agent``.

Run: python -m datadog_agent
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

from datadog_agent.mcp_client import DataDogMCPClient
from datadog_agent.prompts import SYSTEM_PROMPT

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("oversight")

SERVICE_NAME = "datadog-agent"
LLM_PREFIX = "DATADOG_AGENT"

SKILL = AgentSkill(
    id="datadog_evidence",
    name="Gather Datadog evidence",
    description=(
        "Investigates a service incident in Datadog: alerting monitors, metric "
        "series (error-rate/latency spikes), APM trace samples with span "
        "breakdown, error-tracking issues, and log search. Returns concrete "
        "values, timestamps, and trace_ids."
    ),
    tags=["datadog", "monitors", "metrics", "apm", "traces", "error-tracking", "logs"],
    examples=[
        "Which monitors are alerting for payment-service?",
        "Get payment-service error-rate and latency for the last 30 minutes and one sample trace_id.",
        "Fetch trace abc123def456789012345678deadbeef and summarize the failing span.",
    ],
)


async def build() -> LangChainAgentExecutor:
    setup_otel(SERVICE_NAME)
    check_llm_ready(LLM_PREFIX)
    tools = await DataDogMCPClient().load_tools()
    model = make_llm(LLM_PREFIX)
    agent = create_agent(model=model, tools=tools, system_prompt=SYSTEM_PROMPT, name="datadog-agent")
    return LangChainAgentExecutor(agent, csv_model_fallback=SERVICE_NAME)


def main() -> None:
    host = env_or("DATADOG_AGENT_HOST", "0.0.0.0")
    port = int(env_or("DATADOG_AGENT_PORT", "8101"))
    advertised = env_or("DATADOG_AGENT_URL", f"http://datadog-agent:{port}")
    executor = asyncio.run(build())
    card = build_agent_card(
        name="DataDogAgent",
        description=(
            "Read-only Datadog investigator for the devops-poc mesh: monitors, "
            "metrics, APM traces/spans, error tracking, and logs — via the "
            "Datadog MCP server."
        ),
        url=advertised,
        skill=SKILL,
    )
    run_a2a_agent(card, executor, host, port)


if __name__ == "__main__":
    main()
