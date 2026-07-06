# Business Requirements Specification
## DevOps OverSight Agent — Business Requirements

**Generated**: 2026-07-06
**Source**: Derived from technical-requirements.md and codebase analysis
**Status**: Point-in-time snapshot — reflects the POC as built
**Audience**: Business stakeholders, product managers, enterprise architects evaluating adoption

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Business Problem Statement](#2-business-problem-statement)
3. [Business Objectives](#3-business-objectives)
4. [Stakeholder Requirements](#4-stakeholder-requirements)
5. [Business Capabilities](#5-business-capabilities)
6. [Business Use Cases](#6-business-use-cases)
7. [Governance & Compliance Requirements](#7-governance--compliance-requirements)
8. [Business Constraints](#8-business-constraints)
9. [Success Metrics](#9-success-metrics)
10. [Assumptions & Dependencies](#10-assumptions--dependencies)
11. [POC to Enterprise Path](#11-poc-to-enterprise-path)

---

## 1. Executive Summary

Financial services organizations running complex microservice environments face a structural problem in incident response: their observability data lives in separate, siloed platforms. Engineers spend the first 20–40 minutes of any major incident manually correlating log data in one tool against performance metrics in another — by hand, under pressure, with no automated synthesis.

The DevOps OverSight Agent addresses this directly. It connects to both observability platforms simultaneously, correlates evidence using the same identifiers that already link logs to traces to metrics, and produces a root-cause summary — in minutes, not an hour. Critically, it does not act autonomously: every proposed fix is presented to an on-call engineer for approval before anything changes in the environment.

This document defines the business requirements that system must satisfy: what outcomes it delivers, who benefits, what constraints it must respect, and how success is measured.

---

## 2. Business Problem Statement

### 2.1 The Observability Silo Problem

Modern SRE and platform engineering teams operate under a fundamental tension: they have invested in best-of-breed observability tooling — typically a dedicated log management platform alongside a dedicated metrics and APM platform — but those platforms do not share a common query interface, and the correlation work between them is entirely manual.

During an incident, an engineer must:
1. Detect an anomaly in metrics or receive an automated alert
2. Retrieve the relevant distributed trace from the metrics platform
3. Manually convert trace identifiers into a search query in the log platform
4. Cross-reference log lines, metric series, deployment history, and dependency topology in their head
5. Arrive at a hypothesis — or escalate

This process is slow, error-prone under stress, and depends heavily on individual institutional knowledge. It does not scale as service mesh complexity grows.

### 2.2 The Human Approval Gap

Existing automation approaches (runbooks, scripts, auto-remediation) tend to go one of two extremes: fully manual (slow) or fully automated (risky). The financial services industry requires a middle path — AI-assisted diagnosis with mandatory human approval before any system change is executed. Most tools do not enforce this boundary at the system level; it relies on process and culture.

### 2.3 The Vendor Lock-in Risk

Any AI-assisted operations capability that ties the organization to a single AI model vendor introduces unacceptable procurement and resilience risk. The capability must function with the organization's choice of AI model — including the option to run entirely on-premises with no model vendor dependency at all.

---

## 3. Business Objectives

| ID | Objective | Priority |
|----|-----------|----------|
| BO-1 | Reduce the mean time to diagnosis for P1/P2 microservice incidents by automating cross-platform evidence correlation | Critical |
| BO-2 | Enforce a human approval gate before any automated remediation action is executed, satisfying governance and change-management requirements | Critical |
| BO-3 | Provide a single investigation interface that spans both the log management platform and the metrics/APM platform without requiring engineers to context-switch | High |
| BO-4 | Demonstrate that AI-assisted incident response is viable with full vendor flexibility — no lock-in to a specific AI model provider | High |
| BO-5 | Ensure the AI agent's own behavior is auditable and observable through the same tooling used to monitor the services it investigates | High |
| BO-6 | Enable the full incident-to-recovery scenario to be demonstrated to technical and executive stakeholders in under five minutes, without requiring live vendor credentials | Medium |
| BO-7 | Establish a clear architectural path from this proof of concept to a production-hardened enterprise deployment | Medium |

---

## 4. Stakeholder Requirements

### 4.1 On-Call / SRE Engineer

**Primary user during an active incident.**

| Requirement | Description |
|-------------|-------------|
| SR-E1 | The system MUST surface a plain-language root-cause summary — what failed, why, what was affected — without requiring the engineer to query multiple tools manually |
| SR-E2 | The system MUST identify which other services are impacted by a failure (blast radius) before a fix is applied |
| SR-E3 | The system MUST present a specific, named remediation action for the engineer to approve or reject — not a generic recommendation |
| SR-E4 | The system MUST include evidence links back to the source data in both observability platforms so the engineer can verify the AI's reasoning |
| SR-E5 | The system MUST NOT take any corrective action without explicit engineer approval |
| SR-E6 | The investigation MUST complete within a time that is meaningfully shorter than a manual investigation (target: under 90 seconds for the AI-driven diagnosis phase) |

### 4.2 Platform / Observability Engineering

**Responsible for operating and extending the system.**

| Requirement | Description |
|-------------|-------------|
| SR-P1 | The system MUST be switchable between AI model providers (including a local, credential-free model) via configuration alone — no code changes |
| SR-P2 | The system MUST be switchable between mock and live observability backends via configuration alone, enabling staged rollout |
| SR-P3 | The AI agent's own activity — reasoning steps, tool calls, model response times — MUST be visible in the same observability stack as the services it monitors |
| SR-P4 | The system MUST provide a fixed, bounded set of permitted remediation actions; arbitrary command execution MUST NOT be possible through the AI interface |
| SR-P5 | Every remediation action taken through the system MUST be recorded in an audit log |

### 4.3 Security & Compliance

**Responsible for governance, change management, and audit.**

| Requirement | Description |
|-------------|-------------|
| SR-S1 | Every automated action that modifies system state MUST require prior human approval — there MUST be no path by which the AI executes a change without an explicit approval signal |
| SR-S2 | The set of actions the AI may propose MUST be a fixed, pre-approved list; the AI MUST NOT be able to construct or execute arbitrary operations |
| SR-S3 | All credentials (AI model keys, observability platform keys) MUST be supplied through a secrets mechanism — never embedded in source code or committed configuration |
| SR-S4 | The system MUST maintain a record of which remediation actions were taken, by which agent, at what time, with what parameters |
| SR-S5 | The AI component's access to observability data MUST operate through a controlled interface with a defined tool surface — not through unrestricted API access |

### 4.4 Demo Operator / Sales Engineering

**Responsible for presenting the capability to prospects and internal stakeholders.**

| Requirement | Description |
|-------------|-------------|
| SR-D1 | The full incident scenario MUST be demonstrable in approximately five minutes |
| SR-D2 | The demonstration MUST be runnable without live vendor accounts or API keys (offline/mock mode) |
| SR-D3 | A controlled fault MUST be injectable into a target service on demand, and resettable cleanly after the demonstration |
| SR-D4 | The demonstration environment MUST start from a clean state reliably, without manual environment preparation beyond standard laptop tooling |
| SR-D5 | The system MUST support freeform conversational queries about service topology and health, not just structured incident investigations — enabling exploratory demo interactions |

### 4.5 Service / Application Owners

**Responsible for individual services within the mesh.**

| Requirement | Description |
|-------------|-------------|
| SR-A1 | The system MUST expose ownership metadata (team, contact channel, repository) per service so incident response is routed to the correct owner |
| SR-A2 | The system MUST surface which runbooks apply to each service |
| SR-A3 | The system MUST track and expose each service's declared SLA for context during incident triage |

---

## 5. Business Capabilities

The following capabilities are required. Each maps to one or more technical components but is stated here in business terms.

### 5.1 Unified Incident Investigation

The system must be capable of receiving an incident signal (an alert, a webhook, or a freeform operator query) and autonomously conducting a structured investigation across both the log management platform and the metrics/APM platform, returning a synthesized finding. The operator does not need to know which platform holds which data; the system handles routing and correlation.

**Enabled by**: AI agent with cross-platform tool access via a single federated interface.

### 5.2 Cross-Platform Signal Correlation

The system must be able to take a single distributed trace identifier surfaced by the metrics platform and use it to locate the corresponding log lines in the log management platform — linking the two platforms' data into one causal chain. This is the core analytical capability that manual investigation performs slowly and inconsistently.

**Enabled by**: Trace correlation tool, structured logging with trace identifiers in both platforms.

### 5.3 Blast-Radius Assessment

Given a failing service, the system must determine which upstream services are affected (i.e., which services depend on the failing one and are therefore experiencing degraded behavior) and which downstream services the failing service depends on (to rule them out as root cause). This prevents fixing a symptom rather than the cause.

**Enabled by**: Service dependency graph in the catalog, dependency-traversal tool.

### 5.4 Propose-Before-Act Remediation

The system must formulate a specific remediation recommendation — naming a vetted, pre-approved action and the parameters it would use — and surface this to the engineer for approval before taking any action. This is a hard system-level requirement, not a process guideline.

**Enabled by**: Runbook catalog (fixed allowlist), human approval step embedded in the investigation protocol.

### 5.5 Controlled Fault Simulation

For training, validation, and demonstration purposes, the system must be able to inject realistic faults into target services (error rates, latency) on demand and reset them cleanly. This capability is internal to the platform team and must be appropriately access-controlled.

**Enabled by**: Token-gated chaos endpoints on a separate control port, isolated from production traffic paths.

### 5.6 AI Model Flexibility

The business must not be locked to a single AI model vendor. The system must support seamless switching between a locally-hosted model (zero vendor dependency, zero cost, on-premises), a managed cloud model (Anthropic, OpenAI), and an enterprise AI gateway — all via configuration.

**Enabled by**: Configurable LLM provider abstraction with four supported backends.

### 5.7 Agent Self-Observability

The AI agent's behavior must be visible to the same teams and tools that monitor the production services it operates on. This is both an operational requirement (to detect misbehavior or runaway tool calls) and a governance requirement (to audit AI-driven activity).

**Enabled by**: Agent telemetry emitted through the same collection pipeline as the workload.

---

## 6. Business Use Cases

### UC-1: P1 Incident — Payment Service Degradation (Headline Scenario)

**Trigger**: Automated alert fires: payment-service error rate has exceeded threshold.

**Actors**: On-call SRE, DevOps OverSight Agent.

**Flow**:
1. Alert delivered to the agent (webhook or manual trigger).
2. Agent investigates: retrieves monitor state from metrics platform, pulls error-rate and latency metrics, locates a distributed trace for a failed request, correlates that trace to log lines in the log platform, assesses which other services are affected, checks recent deployment history and incident history.
3. Agent presents findings: root cause identified as payment-service, order-service affected as a downstream consumer, no recent deployment correlated, matching historical incident found.
4. Agent proposes a specific runbook: "disable-chaos on payment-service" (or equivalent production action), and halts.
5. On-call SRE reviews the summary, evidence links, and proposed action. Approves.
6. Agent executes the approved runbook. Records the action in the audit log. Reports steps taken.
7. Services recover.

**Business outcome**: Incident resolved in ~5 minutes. No manual log/metric correlation required by the engineer. Full audit trail preserved.

### UC-2: Exploratory Health Query

**Trigger**: Engineer asks: "What services have the most dependencies, and which ones are currently unhealthy?"

**Actors**: Platform engineer, DevOps OverSight Agent.

**Flow**:
1. Engineer submits conversational query.
2. Agent retrieves service topology, dependency graph, and live health status for each service.
3. Agent returns a structured summary identifying high-dependency services and their current health.

**Business outcome**: Situational awareness without manual multi-platform lookups. Useful for shift handoff, pre-release reviews, and capacity planning conversations.

### UC-3: Pre-Incident Baseline Check

**Trigger**: Engineer triggers a low-severity investigation on a service before an anticipated load event.

**Actors**: Platform engineer, DevOps OverSight Agent.

**Flow**:
1. Engineer submits a P3 investigation for a service.
2. Agent checks monitors, metrics, recent deploys, and service health.
3. Agent returns a clean bill of health (or surfaces a pre-existing condition).

**Business outcome**: Proactive risk identification before a load event. Documents a known-good baseline.

### UC-4: Demo for Technical Stakeholders

**Trigger**: Sales engineer or architect needs to demonstrate the full incident-to-recovery cycle.

**Actors**: Demo operator, technical prospect.

**Flow**:
1. Operator starts the stack (offline, no vendor credentials required).
2. Operator injects a controlled fault into the payment service.
3. Agent is triggered to investigate.
4. Agent returns a diagnosis with evidence links and a proposed fix.
5. Operator resets the fault, demonstrating recovery.

**Business outcome**: A convincing, repeatable, five-minute demonstration requiring no production access or vendor accounts. Runnable on a laptop.

---

## 7. Governance & Compliance Requirements

### 7.1 Change Management

- **GC-1** No change to system state may be executed by the AI agent without a documented approval signal from an authorized human operator.
- **GC-2** All remediation actions must be drawn from a pre-approved, fixed catalog. The catalog must be reviewed and approved as part of the system's change management process.
- **GC-3** The audit log recording AI-driven actions must be immutable during a session and must be accessible to platform engineering and security teams.

### 7.2 Data Handling

- **GC-4** Observability data accessed by the AI agent during an investigation (logs, traces, metrics) must not be retained beyond the scope of the investigation session.
- **GC-5** Credentials used to access observability platforms or AI model providers must be managed through the organization's approved secrets management process. They must not appear in source code, version control, or container images.
- **GC-6** In enterprise deployment, bearer tokens or session credentials that flow through the AI interface must be redacted before reaching any trace or log store.

### 7.3 AI Model Governance

- **GC-7** The AI model used for investigation must be configurable and auditable. The organization must retain the ability to switch models, restrict model access, or disable AI-assisted features without application code changes.
- **GC-8** Where an enterprise AI gateway is in use, all AI model traffic must route through it to enable rate limiting, quota management, and model-level audit.

---

## 8. Business Constraints

| Constraint | Description |
|------------|-------------|
| BC-1 | The system must operate in a hybrid mode: some components run in the organization's container infrastructure; observability backends (Splunk, Datadog) remain as existing SaaS investments |
| BC-2 | The system must function as a proof of concept on a single developer machine without external vendor accounts or licenses |
| BC-3 | No new data pipeline infrastructure may be introduced; the system must feed off existing telemetry already flowing to Splunk and Datadog |
| BC-4 | The AI model used must be replaceable without modifying service code — the integration approach must be model-agnostic |
| BC-5 | Remediation capability must be strictly bounded; the system may not provide a general-purpose command execution interface |
| BC-6 | The proof-of-concept scenario must be completable end-to-end within a five-minute demonstration window |

---

## 9. Success Metrics

### 9.1 POC Acceptance Criteria

The POC is considered successful when:

| Metric | Target |
|--------|--------|
| Time from incident alert to AI-generated root-cause summary | < 90 seconds (cloud model) / < 3 minutes (local model) |
| End-to-end incident cycle (inject → diagnose → approve → remediate → recover) | ≤ 5 minutes |
| Evidence coverage | Agent must surface findings from both observability platforms in every investigation |
| Propose-before-act compliance | Agent must never call a remediation runbook without first listing available runbooks and receiving an approval signal |
| Offline operation | Full investigation cycle must complete with zero external vendor credentials |
| Model portability | Same investigation must be demonstrable with at least two different LLM providers (e.g., local Ollama and Anthropic) with no configuration change beyond the provider selector |

### 9.2 Enterprise Success Indicators (post-POC)

| Indicator | Description |
|-----------|-------------|
| MTTR reduction | Measurable reduction in mean time to resolution for P1/P2 incidents where the agent is used |
| Alert-to-diagnosis latency | Time from alert receipt to AI summary delivered to on-call engineer |
| Escalation rate | Percentage of incidents where the AI's proposed runbook was approved (vs. engineer overriding to a different action) |
| Audit completeness | Percentage of AI-driven remediation actions with a complete audit record |
| Platform adoption | Number of services and teams onboarded to the dependency catalog |

---

## 10. Assumptions & Dependencies

| ID | Assumption / Dependency |
|----|------------------------|
| AD-1 | The organization already has both Splunk and Datadog deployed and receiving telemetry from the target services. This system does not replace either platform — it federates them. |
| AD-2 | Services emit distributed tracing data with a common trace identifier that appears in both the log platform and the metrics/APM platform. Without this shared identifier, cross-platform correlation is not possible. |
| AD-3 | At least one AI model is accessible: either a locally-hosted Ollama instance (no vendor account required) or a cloud provider API key. |
| AD-4 | The organization's change management process will define which runbooks are approved for AI-proposed execution and under what incident severity conditions. |
| AD-5 | The system does not manage or replace the alerting configuration in Datadog or Splunk. Alerts are configured in those platforms and delivered to this system via webhook. |
| AD-6 | Service ownership metadata (team, contact channel, SLA) must be provided and maintained by the teams who own each service. The system will not infer ownership from telemetry. |
| AD-7 | In production deployment, a WSO2 API Manager or equivalent gateway will provide authentication, rate limiting, and quota management for both the AI model traffic and the MCP tool interface. |

---

## 11. POC to Enterprise Path

The following table identifies the business capabilities present in the POC and what changes are required to deploy them in a production enterprise environment. No new business requirements are introduced here; this section maps existing requirements to the work remaining.

| Capability | POC State | Enterprise Requirement |
|------------|-----------|----------------------|
| Identity & access control | Unauthenticated (trusted local network) | OIDC/SSO for human operators; workload identity for the AI agent; per-tool RBAC enforced at the MCP gateway |
| Credentials management | Environment variables in `.env` | Organization-approved secrets manager (e.g., Vault, AWS Secrets Manager) |
| Audit log | In-memory, session-scoped | Durable, tamper-evident log tied to human identity; integrated with SIEM |
| Runbook execution | `disable-chaos` live; others stubbed | All runbooks wired to production actions; per-runbook idempotency locks; concurrent execution safety |
| Propose-before-act gate | Prompt-level instruction to the model | Hard code-level interception: `run_runbook` must be blocked unless a preceding approval signal is recorded |
| Service catalog | Static file in source control | CMDB-backed, team-maintained, version-controlled catalog with ownership lifecycle |
| Observability backends | Mock servers (offline) | Live Splunk Cloud and Datadog SaaS via their official MCP integrations; credential rotation handled by secrets manager |
| AI model | Local Ollama default; Anthropic/OpenAI optional | Enterprise AI gateway (e.g., WSO2 AMP) fronting approved models; model-level audit, rate limiting, and quota |
| Scalability | Single-node demo | Agent tier on Kubernetes with horizontal scaling; MCP Proxy behind a load balancer; stateful infra on managed services |
| Trace-ID reconciliation | Verbatim substitution (known limitation) | True 64-bit / 128-bit trace-ID normalization so cross-platform lookups succeed on real traffic |
| Multi-team / multi-mesh | Single mesh, single team | Agent-to-agent decomposition by trust domain: one agent per org boundary, coordinated by a platform-level orchestrator |
