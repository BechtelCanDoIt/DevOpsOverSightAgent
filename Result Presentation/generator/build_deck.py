"""build_deck.py — DevOps OverSight Agent: POC Architecture Review.

Generates a WSO2-branded, ~48-slide deep-dive PowerPoint covering the shared
Level 0 architecture and the two reference solutions (Ballerina + MCP Proxy;
LangChain + A2A). Speaker notes on every slide.
"""
import decklib as D
from decklib import (para, textbox, rect, panel, bullets, callout, stat, node,
                     connect, elbow, edge_label, chip, card_header, make_table,
                     numbered_step, wso2_mark, kicker_title, footer,
                     PP_ALIGN, MSO_ANCHOR, MSO_SHAPE)

M = D.MARGIN
CW = D.CW
SW = D.SLIDE_W
BT = D.BODY_TOP


def notes(slide, text):
    slide.notes_slide.notes_text_frame.text = text.strip()


# ============================================================================
# FRONT MATTER
# ============================================================================
def slide_title(prs):
    s = D.add_slide(prs, D.NAVY)
    rect(s, 0, 0, SW, 0.16, fill=D.ORANGE)
    rect(s, 0, SH_BAND(), SW, 0.10, fill=D.ORANGE)
    wso2_mark(s, M, 0.55, color=D.WHITE, size=22)
    tb, tf = textbox(s, M + 1.15, 0.55, 6, 0.5, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, "|   Forward Deployed Engineering", first=True, size=12.5, color=D.NAVY_TXT)
    # eyebrow
    tb, tf = textbox(s, M, 2.35, 11.5, 0.4)
    para(tf, "POC ARCHITECTURE REVIEW", first=True, size=14, color=D.ORANGE, bold=True)
    # title
    tb, tf = textbox(s, M, 2.78, 11.9, 2.0)
    para(tf, "The DevOps OverSight Agent", first=True, size=46, color=D.WHITE, bold=True, after=4, spacing=1.0)
    # subtitle
    tb, tf = textbox(s, M, 4.35, 11.4, 1.2)
    para(tf, [("AI-assisted incident response that correlates ", {}),
              ("Splunk", {"bold": True, "color": D.WHITE}),
              (" and ", {}),
              ("Datadog", {"bold": True, "color": D.WHITE}),
              (" over MCP", {})],
         first=True, size=17, color=D.NAVY_TXT, spacing=1.2, after=2)
    para(tf, "to diagnose and remediate incidents in a microservice mesh — two reference architectures.",
         size=17, color=D.NAVY_TXT, spacing=1.2)
    # two solution chips
    chip(s, M, 5.75, "Solution 1  ·  Ballerina + MCP Proxy", w=4.05, color=D.TEAL, fill="10333B", size=11.5, h=0.42)
    chip(s, M + 4.35, 5.75, "Solution 2  ·  LangChain + A2A", w=3.75, color="B7A9F5", fill="241E52", size=11.5, h=0.42)
    # meta footer
    rect(s, M, 6.66, CW, 0.014, fill=D.NAVY_2)
    tb, tf = textbox(s, M, 6.82, CW, 0.4, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, [("Scott Bechtel", {"bold": True, "color": D.WHITE}),
              ("   ·   Internal review: FDE team + leadership", {"color": D.NAVY_TXT}),
              ("   ·   July 2026", {"color": D.NAVY_TXT})], first=True, size=12)
    return s


def SH_BAND():
    return D.SLIDE_H - 0.10


def slide_agenda(prs):
    s = D.content_slide(prs, "What we'll cover", "Agenda")
    items = [
        ("01", "The problem", "Why cross-platform incident diagnosis is slow, risky, and manual today.", D.ORANGE),
        ("02", "Level 0 architecture", "The concepts both solutions share: the mesh, telemetry fan-out, MCP, correlation, the human-approval gate.", D.ORANGE),
        ("03", "Solution 1 — Ballerina + MCP Proxy", "One agent, one MCP endpoint that federates Splunk & Datadog behind lazy-loaded tools.", D.TEAL),
        ("04", "Solution 2 — LangChain + A2A", "An orchestrator that delegates to Datadog & Splunk specialist agents over the A2A protocol.", D.VIOLET),
        ("05", "Comparison & path to enterprise", "An honest scorecard, the 5-minute demo, and what production hardening looks like.", D.ORANGE),
    ]
    y = BT + 0.05
    rowh = 0.90
    for num, title, desc, ac in items:
        rect(s, M, y, 0.9, 0.62, fill="F7F9FB", line=D.LINE, shape=MSO_SHAPE.ROUNDED_RECTANGLE, radius=0.14)
        tb, tf = textbox(s, M, y, 0.9, 0.62, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, num, first=True, size=22, color=ac, bold=True, align=PP_ALIGN.CENTER)
        tb, tf = textbox(s, M + 1.15, y - 0.03, CW - 1.15, 0.7, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, title, first=True, size=15.5, color=D.INK, bold=True, after=2, spacing=1.0)
        para(tf, desc, size=11, color=D.GRAY, spacing=1.05)
        y += rowh
    notes(s, """
Quick roadmap. We start with the business problem so everyone shares the 'why', then the Level-0 architecture that is common to both approaches. Then we go deep on each of the two solutions we built, and finish with an honest side-by-side and the road to a production deployment. I've left the recommendation slide open on purpose — we'll decide that together after the scorecard.
""")
    return s


def slide_exec(prs):
    s = D.content_slide(prs, "The one-slide version", "Executive summary")
    # left: narrative
    lw = 6.7
    bullets(s, M, BT + 0.05, lw, 3.6, [
        {"lead": "The pain:", "text": "in a P1, engineers burn the first 20–40 minutes hand-correlating Splunk logs against Datadog metrics — under pressure, by hand."},
        {"lead": "What we built:", "text": "an AI agent that runs that cross-platform investigation automatically, then proposes a specific fix and waits for a human to approve it."},
        {"lead": "Two architectures:", "text": "same POC, same 5-minute demo, built two ways to show the trade-off — a Ballerina MCP Proxy and a LangChain A2A multi-agent system."},
        {"lead": "The durable bets:", "text": "MCP as the contract boundary, correlation kept in one reasoning context, and propose-before-act as a hard rule — never autonomous."},
    ], size=13, gap=11)
    # right: stat rail
    x = M + lw + 0.4
    w = CW - (x - M)
    stat(s, x, BT + 0.05, w, "≤ 5 min", "inject → diagnose → approve → recover", accent=D.ORANGE, h=1.28, big_size=34, lab_size=10.5)
    stat(s, x, BT + 1.5, (w - 0.25) / 2, "< 90s", "AI diagnosis (cloud model)", accent=D.TEAL, h=1.2, big_size=24, lab_size=9.5)
    stat(s, x + (w - 0.25) / 2 + 0.25, BT + 1.5, (w - 0.25) / 2, "0", "vendor creds to demo", accent=D.VIOLET, h=1.2, big_size=24, lab_size=9.5)
    callout(s, x, BT + 2.9, w, 0.95, "Bottom line",
            "Both approaches work. This deck gives you the scorecard to choose.",
            accent=D.ORANGE)
    notes(s, """
If you remember one slide, this is it. The problem is the manual correlation tax during major incidents. Our answer is an AI agent that does the cross-tool detective work in under 90 seconds and then stops and asks a human before it changes anything. We deliberately built it twice — once in Ballerina behind an MCP Proxy, once in Python with LangChain and the A2A protocol — because the interesting question for the client isn't 'does it work' (it does), it's 'which architecture fits us'. The whole cycle runs on a laptop with no vendor credentials, which makes it demo-able anywhere.
""")
    return s


# ============================================================================
# SECTION 1 — THE PROBLEM
# ============================================================================
def slide_silo(prs):
    s = D.content_slide(prs, "The problem", "Best-of-breed tools, siloed by design")
    lw = 6.5
    bullets(s, M, BT + 0.05, lw, 3.8, [
        {"lead": "Two systems of record.", "text": "Logs and search live in Splunk. Metrics, APM, and traces live in Datadog. Both are excellent — and they don't share a query interface."},
        {"lead": "The join is manual.", "text": "During an incident an engineer swivel-chairs between them: spot a metric anomaly, pull a trace, copy the trace ID into a log search, cross-reference in their head."},
        {"lead": "It doesn't scale.", "text": "The work depends on individual institutional knowledge and gets harder as the mesh grows. Under pressure, at 2am, it's slow and error-prone."},
        {"lead": "Financial services raises the bar.", "text": "Any automation must be auditable, bounded, and must never change production without explicit human approval."},
    ], size=13, gap=11)
    # right: the swivel-chair visual
    x = M + lw + 0.45
    w = CW - (x - M)
    node(s, x, BT + 0.2, w, 1.0, "Datadog", "metrics · APM · traces", fill=D.DATADOG_LT, line=D.DATADOG, tsize=15)
    node(s, x, BT + 2.55, w, 1.0, "Splunk", "logs · search", fill=D.SPLUNK_LT, line=D.SPLUNK, tsize=15)
    # manual bridge
    connect(s, x + w / 2, BT + 1.2, x + w / 2, BT + 2.55, color=D.GRAY_MD, dashed=True, head=True, tail=True)
    edge_label(s, x + w / 2, BT + 1.87, "manual\ntrace_id copy", w=1.75, size=9, color=D.RED, bold=True, fill=D.WHITE)
    tb, tf = textbox(s, x, BT + 3.75, w, 0.5, anchor=MSO_ANCHOR.TOP)
    para(tf, "The engineer is the integration.", first=True, size=11.5, color=D.INK, bold=True, align=PP_ALIGN.CENTER)
    notes(s, """
Set the scene. Most mature shops have invested in best-of-breed observability: Splunk for logs, Datadog for metrics and APM. Individually they're great. The gap is between them. There's no shared query layer, so the correlation work is done by a human, live, during the incident. The person is the integration point. That's fine on a quiet Tuesday and terrible during a P1 at 2am. And in financial services you can't just bolt on auto-remediation to fix it — anything that touches production has to be governed and approved.
""")
    return s


def slide_tax(prs):
    s = D.content_slide(prs, "The problem", "The manual-correlation tax")
    steps = [
        ("Detect", "An alert fires or a metric looks wrong in Datadog."),
        ("Trace", "Find a representative distributed trace for a failing request."),
        ("Translate", "Hand-convert the trace ID into a Splunk search query."),
        ("Cross-reference", "Correlate logs, metrics, deploy history, and dependencies — mentally."),
        ("Hypothesize", "Form a root-cause guess… or escalate to someone who knows."),
    ]
    n = len(steps)
    gap = 0.28
    bw = (CW - gap * (n - 1)) / n
    y = BT + 0.35
    for i, (t, d) in enumerate(steps):
        x = M + i * (bw + gap)
        panel(s, x, y, bw, 1.9, fill=D.WHITE, line=D.LINE)
        rect(s, x, y, bw, 0.10, fill=D.ORANGE)
        tb, tf = textbox(s, x + 0.14, y + 0.24, bw - 0.28, 0.5, anchor=MSO_ANCHOR.TOP)
        para(tf, f"{i+1}", first=True, size=13, color=D.ORANGE, bold=True, after=1)
        para(tf, t, size=13.5, color=D.INK, bold=True)
        tb, tf = textbox(s, x + 0.14, y + 1.0, bw - 0.28, 0.85, anchor=MSO_ANCHOR.TOP)
        para(tf, d, first=True, size=10, color=D.INK_SOFT, spacing=1.1)
        if i < n - 1:
            connect(s, x + bw + 0.02, y + 0.95, x + bw + gap - 0.02, y + 0.95, color=D.GRAY_MD, width=1.6)
    stat(s, M, y + 2.35, 3.1, "20–40 min", "lost per major incident", accent=D.RED, h=1.15, big_size=27, lab_size=11, fill=D.RED_LT, line=D.RED_LT)
    callout(s, M + 3.4, y + 2.35, CW - 3.4, 1.15, "Why this is the target",
            "Every one of these five steps is exactly what an LLM agent with the right tools can do — fast, consistently, and with its work shown.",
            accent=D.ORANGE)
    notes(s, """
Here's the actual workflow we're compressing. Five steps, all manual, all serial, all dependent on the engineer's memory of the system. The industry number we cite is 20–40 minutes of pure correlation before you even have a hypothesis. The key insight: every one of these steps is a well-defined retrieval-and-reasoning task. That's precisely what a tool-using LLM is good at. We're not replacing the engineer's judgment — we're automating the tedious detective work that precedes it, and showing our work so they can trust it.
""")
    return s


def slide_forces(prs):
    s = D.content_slide(prs, "The problem", "Three forces shaped the design")
    cards = [
        ("Silo tax", D.ORANGE, D.ORANGE_LT,
         "Cut mean-time-to-diagnosis",
         "Federate the two platforms so one investigation spans both — no context-switching, no manual trace-ID translation."),
        ("Approval gap", D.TEAL, D.TEAL_LT,
         "Middle path: assisted, not autonomous",
         "Runbooks are auto-executed only after an explicit human approval. Enforced by the system, not by process or good intentions."),
        ("Lock-in risk", D.VIOLET, D.VIOLET_LT,
         "No AI vendor dependency",
         "Model-agnostic by design — swap between a local model and cloud providers by config. Runs fully offline if needed."),
    ]
    n = len(cards)
    gap = 0.35
    cwid = (CW - gap * (n - 1)) / n
    y = BT + 0.2
    h = 3.9
    for i, (tag, ac, lt, head, body) in enumerate(cards):
        x = M + i * (cwid + gap)
        panel(s, x, y, cwid, h, fill=D.WHITE, line=D.LINE)
        rect(s, x, y, cwid, 0.85, fill=lt, shape=MSO_SHAPE.ROUNDED_RECTANGLE, radius=0.05)
        rect(s, x, y + 0.55, cwid, 0.30, fill=lt)  # square off bottom of the tinted header
        chip(s, x + 0.25, y + 0.26, tag, color=ac, fill=D.WHITE, size=10.5)
        tb, tf = textbox(s, x + 0.25, y + 1.1, cwid - 0.5, 1.0, anchor=MSO_ANCHOR.TOP)
        para(tf, head, first=True, size=15, color=D.INK, bold=True, spacing=1.05)
        tb, tf = textbox(s, x + 0.25, y + 2.05, cwid - 0.5, h - 2.2, anchor=MSO_ANCHOR.TOP)
        para(tf, body, first=True, size=11.5, color=D.INK_SOFT, spacing=1.2)
    notes(s, """
Three business forces, and they map directly to three design decisions you'll see repeated all night. One: the silo tax means we federate Splunk and Datadog into a single investigation. Two: the approval gap — financial services can't do full auto-remediation, so we enforce propose-before-act at the system level. Three: lock-in risk — procurement and resilience both hate single-vendor AI dependencies, so the model is pluggable and can run entirely on-prem with no vendor account at all. Keep these three in mind; every architectural choice ties back to one of them.
""")
    return s


def slide_stakeholders(prs):
    s = D.content_slide(prs, "The problem", "Who we're building for")
    rows = [
        ("On-call / SRE", "Primary user in a live incident", "Plain-language root cause + blast radius + a specific action to approve — with evidence links back to both platforms.", D.ORANGE),
        ("Platform / Observability Eng", "Operates & extends the system", "Swap model or backend by config alone; the agent's own behavior is visible in the same stack it monitors.", D.TEAL),
        ("Security & Compliance", "Governance, change mgmt, audit", "No state change without prior approval; a fixed action allowlist; every action recorded; secrets never in code.", D.VIOLET),
        ("Demo / Sales Engineering", "Presents the capability", "Full incident in ~5 minutes, offline, no vendor accounts, resettable to a clean state.", D.SPLUNK),
        ("Service / App owners", "Own individual services", "Ownership, runbooks, and SLA metadata surfaced per service so response routes correctly.", D.DATADOG),
    ]
    y = BT + 0.05
    rh = 0.94
    for name, role, need, ac in rows:
        rect(s, M, y + 0.05, 0.10, rh - 0.22, fill=ac)
        tb, tf = textbox(s, M + 0.28, y, 3.2, rh - 0.12, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, name, first=True, size=13.5, color=D.INK, bold=True, after=2, spacing=1.0)
        para(tf, role, size=10, color=D.GRAY, spacing=1.0)
        tb, tf = textbox(s, M + 3.75, y, CW - 3.75, rh - 0.12, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, need, first=True, size=11.5, color=D.INK_SOFT, spacing=1.1)
        if y > BT:
            rect(s, M, y - 0.02, CW, 0.012, fill=D.LINE)
        y += rh
    notes(s, """
Five stakeholder classes, but the one that drives the design is the on-call SRE. They need a plain-language answer — what broke, what's affected, what to do — with links back so they can verify the AI's reasoning rather than take it on faith. Everyone else adds constraints: platform engineering wants config-not-code flexibility and wants to watch the watcher; security wants the hard approval gate and a bounded action list; sales wants the offline five-minute demo; service owners supply the ownership metadata that makes routing work. The design satisfies all five, but the SRE experience is the north star.
""")
    return s


def slide_success(prs):
    s = D.content_slide(prs, "The problem", "What 'good' looks like — the POC bar")
    cards = [
        ("< 90s", "AI diagnosis (cloud)", "Under 3 min on a local model", D.TEAL),
        ("≤ 5 min", "Full incident cycle", "Inject → diagnose → approve → recover", D.ORANGE),
        ("2", "platforms, every time", "Evidence from BOTH Splunk & Datadog", D.SPLUNK),
        ("0", "vendor credentials", "Full cycle runs offline", D.VIOLET),
    ]
    n = len(cards); gap = 0.3
    cwid = (CW - gap * (n - 1)) / n
    y = BT + 0.1
    for i, (big, lab, sub, ac) in enumerate(cards):
        x = M + i * (cwid + gap)
        stat(s, x, y, cwid, big, lab, accent=ac, h=1.75, big_size=36, lab_size=12, sub=sub)
    # two hard rules below
    y2 = y + 2.15
    callout(s, M, y2, (CW - 0.35) / 2, 1.35, "Propose-before-act",
            "The agent must list available runbooks and receive an approval signal before it ever executes one. No exceptions.",
            accent=D.ORANGE)
    callout(s, M + (CW - 0.35) / 2 + 0.35, y2, (CW - 0.35) / 2, 1.35, "Model portability",
            "The same investigation must run on at least two providers (e.g. local Ollama and Anthropic) with no change beyond the provider selector.",
            accent=D.TEAL, fill=D.TEAL_LT)
    notes(s, """
These are the acceptance criteria we held ourselves to, straight from the business requirements. Diagnosis in under 90 seconds on a cloud model, the full inject-to-recover loop in five minutes, evidence pulled from both platforms on every single investigation, and — importantly — the whole thing runs with zero vendor credentials so it's demo-able on any laptop. The two hard rules at the bottom are non-negotiable: the agent never acts without approval, and the model is swappable. We met all of these; that's what makes it a credible POC rather than a scripted demo.
""")
    return s


# ============================================================================
# SECTION 2 — LEVEL 0 ARCHITECTURE
# ============================================================================
def slide_twotier(prs):
    s = D.content_slide(prs, "Level 0 · shared", "The big picture: two tiers")
    # Agent tier panel
    ay = BT + 0.15
    panel(s, M, ay, CW, 1.75, fill=D.GRAY_LT, line=D.LINE)
    chip(s, M + 0.2, ay + 0.16, "AGENT TIER  ·  governed", color=D.ORANGE_DK, fill=D.WHITE, size=9.5, w=2.9)
    node(s, M + 0.35, ay + 0.62, 3.4, 0.9, "Incident-Response Agent", "native tool-use loop", fill=D.WHITE, line=D.INK, tsize=12)
    node(s, M + 4.15, ay + 0.62, 3.0, 0.9, "MCP tool surface", "logs · metrics · topology · runbooks", fill=D.ORANGE_LT, line=D.ORANGE, tsize=12, ssize=8.5)
    node(s, M + 7.55, ay + 0.62, 2.7, 0.9, "LLM (pluggable)", "local or cloud", fill=D.WHITE, line=D.GRAY_MD, tsize=12)
    node(s, M + 10.45, ay + 0.62, CW - 10.45 - 0.35, 0.9, "WSO2 AMP", "governance / AI gateway", fill=D.WHITE, line=D.GRAY_MD, tsize=11, ssize=8)
    # Workload tier panel
    wy = ay + 2.05
    panel(s, M, wy, CW, 2.35, fill=D.GRAY_LT, line=D.LINE)
    chip(s, M + 0.2, wy + 0.16, "WORKLOAD + OBSERVABILITY TIER", color=D.INK_SOFT, fill=D.WHITE, size=9.5, w=3.5)
    node(s, M + 0.35, wy + 0.65, 3.6, 1.4, "7-service Ballerina mesh", "+ load generator", fill=D.WHITE, line=D.INK, tsize=12.5)
    node(s, M + 4.3, wy + 0.65, 2.6, 1.4, "OTel Collector", "one shipper, fans out", fill=D.WHITE, line=D.GRAY_MD, tsize=12)
    node(s, M + 7.2, wy + 0.65, 2.9, 0.62, "Datadog (SaaS)", "metrics · traces", fill=D.DATADOG_LT, line=D.DATADOG, tsize=11.5, ssize=8.5)
    node(s, M + 7.2, wy + 1.43, 2.9, 0.62, "Splunk (SaaS)", "logs · traces", fill=D.SPLUNK_LT, line=D.SPLUNK, tsize=11.5, ssize=8.5)
    node(s, M + 10.3, wy + 0.65, CW - 10.3 - 0.35, 1.4, "Infra", "Postgres · Redis · NATS", fill=D.WHITE, line=D.GRAY_MD, tsize=11, ssize=8.5)
    # arrows
    connect(s, M + 3.95, wy + 1.35, M + 4.3, wy + 1.35, color=D.INK)
    connect(s, M + 6.9, wy + 1.1, M + 7.2, wy + 0.96, color=D.DATADOG)
    connect(s, M + 6.9, wy + 1.6, M + 7.2, wy + 1.74, color=D.SPLUNK)
    # agent reaches observability (dashed up from MCP surface to SaaS)
    connect(s, M + 5.6, ay + 1.52, M + 8.6, wy + 0.65, color=D.ORANGE, dashed=True)
    edge_label(s, M + 7.15, wy + 0.30, "MCP tool calls", w=1.7, size=8.5, color=D.ORANGE_DK, bold=True)
    notes(s, """
The whole system is two tiers. The bottom tier is the thing being watched: a realistic seven-service retail mesh with a load generator, plus the infra it depends on, all emitting telemetry through a single OpenTelemetry collector that fans out to Datadog and Splunk as SaaS. The top tier is the thing doing the watching: the incident-response agent, its pluggable LLM, and — optionally — WSO2 Agent Manager providing governance and an AI gateway. The agent reaches the observability data as MCP tool calls, shown by the dashed orange arrow. Everything below the agent is identical across both of our solutions; the interesting differences are all in how that MCP tool surface is wired, which is the next few sections.
""")
    return s


def slide_mesh(prs):
    s = D.content_slide(prs, "Level 0 · shared", "The mesh we observe & remediate")
    # load-gen -> front doors; order fans out
    lg = node(s, M, BT + 1.5, 1.7, 0.9, "load-gen", "traffic driver", fill=D.INK, line=D.INK, tcolor=D.WHITE, scolor=D.NAVY_TXT, tsize=12)
    # front door: order-service center
    ox = M + 2.6
    order = node(s, ox, BT + 1.5, 2.3, 0.9, "order-service", "POST /orders — front door", fill=D.ORANGE_LT, line=D.ORANGE, tsize=12.5, ssize=8)
    # downstream sync services (right column)
    dsx = ox + 3.4
    ds = [("customer-service", "validate"), ("inventory-service", "reserve · Redis"), ("payment-service", "charge · mock-bank"), ("invoice-service", "bill")]
    dy = BT + 0.15
    dh = 0.66
    dgap = 0.20
    for i, (nm, role) in enumerate(ds):
        yy = dy + i * (dh + dgap)
        fill = D.RED_LT if "payment" in nm else D.WHITE
        line = D.RED if "payment" in nm else D.GRAY_MD
        node(s, dsx, yy, 3.0, dh, nm, role, fill=fill, line=line, tsize=11.5, ssize=8)
        connect(s, ox + 2.3, BT + 1.75, dsx, yy + dh / 2, color=D.GRAY_MD, width=1.3)
    # async notification bottom
    notif = node(s, dsx, dy + 4 * (dh + dgap) + 0.1, 3.0, dh, "notification-service", "async confirm", fill=D.WHITE, line=D.GRAY_MD, tsize=11.5, ssize=8)
    connect(s, ox + 1.15, BT + 2.4, dsx, dy + 4 * (dh + dgap) + 0.1 + dh / 2, color=D.VIOLET, dashed=True, width=1.4)
    edge_label(s, ox + 1.4, dy + 4 * (dh + dgap) + 0.05, "NATS", w=0.9, size=8.5, color=D.VIOLET, bold=True)
    # store-service
    node(s, ox, BT + 0.3, 2.3, 0.75, "store-service", "browse → inventory", fill=D.WHITE, line=D.GRAY_MD, tsize=11.5, ssize=8)
    connect(s, M + 1.7, BT + 1.7, ox, BT + 1.85, color=D.INK, width=1.4)
    connect(s, M + 1.7, BT + 1.9, ox + 0.4, BT + 1.05, color=D.INK, width=1.2)
    # payment call-out
    chip(s, dsx, dy + 2 * (dh + dgap) - 0.34, "◀ headline chaos target", color=D.RED, fill=D.RED_LT, size=9, w=2.6)
    # right note panel
    px = dsx + 3.35
    pw = CW - (px - M)
    if pw > 1.6:
        panel(s, px, BT + 0.15, pw, 4.3, fill=D.PANEL, line=D.LINE)
        card_header(s, px + 0.18, BT + 0.35, pw - 0.36, "Why a mesh?", accent=D.ORANGE)
        bullets(s, px + 0.2, BT + 0.85, pw - 0.42, 3.4, [
            {"text": "Blast radius only exists across services."},
            {"text": "order fans out sync to 4 services + one async NATS hop to notification."},
            {"text": "Each service has a token-gated /chaos endpoint to inject faults."},
            {"text": "payment-service is the demo's failure point."},
        ], size=10.5, gap=9)
    notes(s, """
This is the workload — a believable retail mesh, not a toy. load-gen drives traffic. order-service is the front door: a POST /orders fans out synchronously to customer, inventory, payment, and invoice, and fires one asynchronous NATS message to notification. We need a real mesh because the interesting problems — blast radius, 'which downstream actually caused this' — only exist when services call each other. Every service has a token-gated chaos endpoint so we can inject latency or errors on demand. payment-service is our headline failure point: in the demo it starts throwing 502s, and the agent has to figure out why and what else is affected.
""")
    return s


def slide_fanout(prs):
    s = D.content_slide(prs, "Level 0 · shared", "Telemetry fan-out: one collector, routed by signal")
    # services box
    svc = node(s, M, BT + 1.1, 2.5, 1.5, "Services + agent", "emit OTLP", fill=D.WHITE, line=D.INK, tsize=13)
    # collector
    cx = M + 3.6
    col = node(s, cx, BT + 1.1, 2.7, 1.5, "OTel Collector", ":4317 gRPC / :4318 HTTP", fill=D.ORANGE_LT, line=D.ORANGE, tsize=13.5, ssize=9)
    connect(s, M + 2.5, BT + 1.85, cx, BT + 1.85, color=D.INK, width=2)
    edge_label(s, M + 3.05, BT + 1.85, "OTLP", w=0.95, size=9, color=D.INK_SOFT, bold=True)
    # three destinations
    dx = cx + 3.7
    dw = CW - (dx - M)
    dests = [
        ("Datadog", "METRICS + TRACES", "monitors fire the alert", D.DATADOG, D.DATADOG_LT, BT + 0.02),
        ("Splunk", "LOGS (HEC) + TRACES", "log-of-record", D.SPLUNK, D.SPLUNK_LT, BT + 1.18),
        ("Jaeger", "TRACES (dev only)", "local inspection", D.GRAY, D.GRAY_LT, BT + 2.34),
    ]
    for nm, tag, sub, ac, lt, yy in dests:
        node(s, dx, yy, dw, 0.9, nm, sub, fill=lt, line=ac, tag=tag, tag_color=ac, tsize=13, ssize=8.5)
        connect(s, cx + 2.7, BT + 1.85, dx, yy + 0.45, color=ac, width=1.8)
    callout(s, M, BT + 3.5, CW, 1.05, "The routing rule",
            "Traces → both platforms (so the agent can pivot by trace_id).   Logs → Splunk only.   Metrics → Datadog only.   DD_LOGS_ENABLED=false avoids double-billing.",
            accent=D.ORANGE)
    notes(s, """
No new pipeline — we feed off the telemetry that's already flowing. Everything, including the agent itself, emits OTLP to a single collector, and the collector fans out by signal type. This is the important detail: traces go to BOTH platforms deliberately, because that dual-shipping is what lets the agent pivot from a Datadog trace to the matching Splunk logs using a shared trace ID. Logs go only to Splunk — it's the log-of-record — and metrics go only to Datadog, which owns the monitors that fire the alert. We turn off Datadog logs to avoid paying twice. Jaeger is there for us during development and gets removed for the customer demo.
""")
    return s


def slide_mcp(prs):
    s = D.content_slide(prs, "Level 0 · shared", "MCP: the contract boundary", accent=D.ORANGE)
    lw = 6.4
    bullets(s, M, BT + 0.05, lw, 3.8, [
        {"lead": "Everything is a tool.", "text": "Splunk search, Datadog metrics, service topology, correlation, runbooks — the agent sees one uniform tool surface over MCP (Model Context Protocol)."},
        {"lead": "Mock ⇄ live is config, not code.", "text": "Swapping a mock backend for a real vendor MCP is a URL/token change. The agent's code never changes."},
        {"lead": "MCP fills what vendors can't.", "text": "Splunk MCP knows logs. Datadog MCP knows metrics. Neither knows YOUR catalog, dependency graph, owners, or runbooks — we add those as local tools."},
        {"lead": "One place for policy.", "text": "Routing, auth, and result hygiene get a single home at the boundary."},
    ], size=12.5, gap=10)
    # right: layered stack
    x = M + lw + 0.45
    w = CW - (x - M)
    node(s, x, BT + 0.1, w, 0.75, "AI Agent", "reasons, calls tools", fill=D.INK, line=D.INK, tcolor=D.WHITE, scolor=D.NAVY_TXT, tsize=13)
    connect(s, x + w / 2, BT + 0.85, x + w / 2, BT + 1.25, color=D.ORANGE, width=2)
    edge_label(s, x + w / 2, BT + 1.05, "MCP  (JSON-RPC / streamable HTTP)", w=w - 0.2, size=8.5, color=D.ORANGE_DK, bold=True, fill=D.WHITE)
    tools = [("Splunk tools", D.SPLUNK, D.SPLUNK_LT), ("Datadog tools", D.DATADOG, D.DATADOG_LT),
             ("Topology & correlation", D.TEAL, D.TEAL_LT), ("Runbooks (allowlist)", D.ORANGE, D.ORANGE_LT)]
    yy = BT + 1.35
    for nm, ac, lt in tools:
        node(s, x, yy, w, 0.66, nm, None, fill=lt, line=ac, tsize=12)
        yy += 0.78
    notes(s, """
MCP is the load-bearing abstraction. The agent doesn't know or care whether it's talking to a real Splunk or a mock — it just calls tools. That gives us the config-not-code swap between mock and live, which is what lets us stage a rollout safely. The other half is just as important: the vendor MCPs only know their own data. They don't know your service catalog, your dependency graph, who owns what, or what runbooks are safe to run. So we add those as local topology, correlation, and runbook tools on the same MCP surface. Where those local tools LIVE is exactly where our two solutions differ — hold that thought.
""")
    return s


def slide_correlation(prs):
    s = D.content_slide(prs, "Level 0 · shared", "The core trick: correlate by trace_id", accent=D.ORANGE)
    # flow: DD trace -> correlate -> splunk logs
    y = BT + 0.3
    node(s, M, y, 3.0, 1.0, "Datadog APM", "trace_id abc123…deadbeef", fill=D.DATADOG_LT, line=D.DATADOG, tsize=12.5, ssize=8.5)
    cor = node(s, M + 3.6, y, 3.2, 1.0, "correlate_trace()", "builds the Splunk query + deep-links", fill=D.ORANGE_LT, line=D.ORANGE, tsize=12.5, ssize=8)
    node(s, M + 7.4, y, 3.0, 1.0, "Splunk logs", "index=* trace_id=\"…\"", fill=D.SPLUNK_LT, line=D.SPLUNK, tsize=12.5, ssize=8.5)
    connect(s, M + 3.0, y + 0.5, M + 3.6, y + 0.5, color=D.INK)
    connect(s, M + 6.8, y + 0.5, M + 7.4, y + 0.5, color=D.INK)
    tb, tf = textbox(s, M, y + 1.15, CW, 0.4)
    para(tf, "Both platforms carry the same trace_id in structured logs — that shared key is the whole game.",
         first=True, size=11.5, color=D.INK, bold=True, align=PP_ALIGN.CENTER)
    # the gotcha
    callout(s, M, y + 1.7, CW, 1.55, "⚠ The #1 correctness gotcha — trace-ID width",
            "Datadog surfaces a 64-bit dd.trace_id; OpenTelemetry & Splunk hold a 128-bit trace_id. Search Splunk with the wrong width and the agent wrongly concludes \"no logs found.\" The correlation layer MUST normalize both. (The mock's single demo ID masks this — real traffic exposes it.)",
            accent=D.AMBER, fill=D.AMBER_LT)
    notes(s, """
This is the single most important technical concept in the whole deck. The reason cross-platform correlation is even possible is that every service stamps the same trace ID into its structured logs, so a Datadog trace can be matched to its Splunk log lines. correlate_trace is the tool that takes a trace ID and builds the ready-to-run Splunk query and the Datadog deep-link. Now the gotcha, and please remember this one for the client: Datadog shows a 64-bit trace ID while OpenTelemetry and Splunk use 128-bit. If you naively search Splunk with the 64-bit number Datadog gave you, you get zero results and the agent falsely concludes there are no logs. The correlation layer has to normalize between the two widths. Our mocks use one fixed demo ID, which hides the problem — so this is the first thing to harden against real traffic.
""")
    return s


def slide_agentjob(prs):
    s = D.content_slide(prs, "Level 0 · shared", "The agent's job — and the gate", accent=D.ORANGE)
    lw = 6.3
    bullets(s, M, BT + 0.05, lw, 3.6, [
        {"lead": "Investigate.", "text": "On an incident signal, run a structured cross-platform investigation in a native tool-use loop."},
        {"lead": "Synthesize.", "text": "Produce a root-cause summary with blast radius and evidence links into both Splunk and Datadog."},
        {"lead": "Propose.", "text": "Name a specific, vetted runbook and the parameters it would use — e.g. disable-chaos on payment-service."},
        {"lead": "Wait.", "text": "Stop. Do nothing to production until a human approves. This is the hard line."},
        {"lead": "Remediate & record.", "text": "On approval, run the runbook, stream progress, write an audit entry, and post a postmortem."},
    ], size=12.5, gap=9)
    x = M + lw + 0.45
    w = CW - (x - M)
    # gate visual
    node(s, x, BT + 0.1, w, 0.8, "Agent proposes fix", None, fill=D.WHITE, line=D.INK, tsize=13)
    connect(s, x + w / 2, BT + 0.9, x + w / 2, BT + 1.35, color=D.INK)
    rect(s, x, BT + 1.4, w, 0.95, fill=D.ORANGE_LT, line=D.ORANGE, line_w=1.6, shape=MSO_SHAPE.ROUNDED_RECTANGLE, radius=0.08)
    tb, tf = textbox(s, x + 0.15, BT + 1.4, w - 0.3, 0.95, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, "🔒  HUMAN APPROVAL GATE", first=True, size=13, color=D.ORANGE_DK, bold=True, align=PP_ALIGN.CENTER, after=2)
    para(tf, "explicit approve required", size=10, color=D.INK_SOFT, align=PP_ALIGN.CENTER)
    connect(s, x + w / 2, BT + 2.35, x + w / 2, BT + 2.8, color=D.GREEN)
    node(s, x, BT + 2.85, w, 0.8, "Runbook executes", "audit logged", fill=D.GREEN_LT, line=D.GREEN, tsize=13, ssize=9)
    callout(s, x, BT + 3.9, w, 0.85, "Bounded",
            "Only a fixed, pre-approved runbook list. No arbitrary command execution — ever.",
            accent=D.TEAL, fill=D.TEAL_LT, tsize=11)
    notes(s, """
Here's the agent's actual loop and the guardrail. It investigates, synthesizes a root cause with blast radius and evidence links, and then proposes a specific named runbook — not vague advice like 'consider restarting something,' but 'run disable-chaos on payment-service.' Then it stops. Nothing touches production until a human approves. And critically, the agent can only propose from a fixed allowlist of vetted runbooks — there is no general command-execution tool it could be talked into using. That combination — specific proposal, hard approval gate, bounded action set — is what makes this acceptable in a regulated environment. The two solutions implement the gate differently, and that difference matters a lot; we'll get to it.
""")
    return s


def slide_e2e(prs):
    s = D.content_slide(prs, "Level 0 · shared", "End-to-end: the 10-step investigation", accent=D.ORANGE)
    steps = [
        "Alert / webhook triggers the agent",
        "Check Datadog monitors",
        "Pull metrics → find the error spike",
        "Get a sample trace from APM",
        "correlate_trace → build Splunk query",
        "Run Splunk query → see the log evidence",
        "Assess blast radius (dependencies)",
        "Check recent deploys → rule in/out",
        "Propose runbook → WAIT for approval",
        "Remediate + write postmortem",
    ]
    cols = 5
    gap = 0.28
    bw = (CW - gap * (cols - 1)) / cols
    bh = 1.35
    for i, txt in enumerate(steps):
        r = i // cols
        c = i % cols
        x = M + c * (bw + gap)
        y = BT + 0.25 + r * (bh + 0.55)
        is_gate = (i == 8)
        fill = D.ORANGE_LT if is_gate else D.WHITE
        line = D.ORANGE if is_gate else D.LINE
        panel(s, x, y, bw, bh, fill=fill, line=line)
        d = 0.4
        rect(s, x + 0.12, y + 0.12, d, d, fill=(D.ORANGE if is_gate else D.INK), shape=MSO_SHAPE.OVAL)
        tb, tf = textbox(s, x + 0.12, y + 0.12, d, d, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, str(i + 1), first=True, size=12.5, color=D.WHITE, bold=True, align=PP_ALIGN.CENTER)
        tb, tf = textbox(s, x + 0.14, y + 0.58, bw - 0.28, bh - 0.66, anchor=MSO_ANCHOR.TOP)
        para(tf, txt, first=True, size=10, color=(D.ORANGE_DK if is_gate else D.INK), bold=is_gate, spacing=1.08)
        # arrows within a row
        if c < cols - 1 and i < len(steps) - 1:
            connect(s, x + bw + 0.02, y + 0.32, x + bw + gap - 0.02, y + 0.32, color=D.GRAY_MD, width=1.3)
    # wrap arrow row1->row2 (down)
    connect(s, M + CW - bw / 2, BT + 0.25 + bh + 0.03, M + CW - bw / 2, BT + 0.25 + bh + 0.52, color=D.GRAY_MD, width=1.3)
    tb, tf = textbox(s, M, BT + 0.25 + bh + 0.05, CW - bw - 0.4, 0.45, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, "One OTel trace spans the entire investigation — the agent is observable in the same stack it uses.",
         first=True, size=10.5, color=D.GRAY, align=PP_ALIGN.RIGHT)
    notes(s, """
This is the triage protocol, the same ten steps both agents follow. Notice the shape: it mirrors exactly what a good SRE does manually — monitors, metrics, a trace, correlate to logs, blast radius, deploy history — but compressed to seconds. Step nine is the gate, highlighted: propose and wait. Only after approval does step ten run the fix and write the postmortem. And a nice property for the governance folks: the agent's own reasoning is emitted as one OpenTelemetry trace, so every tool call and model call is visible in the same Datadog you use to watch your services. The watcher is watched.
""")
    return s


def slide_amp(prs):
    s = D.content_slide(prs, "Level 0 · shared", "WSO2 Agent Manager's role", accent=D.ORANGE)
    cards = [
        ("Runtime & governance", "◆", "Hosts the agent as a platform-managed workload from a Git project. Lifecycle, identity, and policy live here.", D.ORANGE, D.ORANGE_LT),
        ("AI gateway", "◆", "All LLM traffic can route through AMP for rate-limiting, quota, model routing, and model-level audit — injected by config.", D.TEAL, D.TEAL_LT),
        ("Self-observability", "◆", "The agent's own spans — reasoning, tool calls, token use, latency — flow through the same collector. Detect runaway agents.", D.VIOLET, D.VIOLET_LT),
    ]
    n = len(cards); gap = 0.35
    cwid = (CW - gap * (n - 1)) / n
    y = BT + 0.15
    h = 2.7
    for i, (head, ic, body, ac, lt) in enumerate(cards):
        x = M + i * (cwid + gap)
        panel(s, x, y, cwid, h, fill=D.WHITE, line=D.LINE)
        rect(s, x, y, cwid, 0.10, fill=ac)
        tb, tf = textbox(s, x + 0.22, y + 0.32, cwid - 0.44, 0.7, anchor=MSO_ANCHOR.TOP)
        para(tf, f"{ic} {head}", first=True, size=14, color=ac, bold=True, spacing=1.0)
        tb, tf = textbox(s, x + 0.22, y + 1.0, cwid - 0.44, h - 1.15, anchor=MSO_ANCHOR.TOP)
        para(tf, body, first=True, size=11.5, color=D.INK_SOFT, spacing=1.2)
    callout(s, M, y + 2.95, CW, 1.15, "Honest scoping for tonight",
            "In Solution 1 (Ballerina) AMP is the agent runtime. In Solution 2 (LangChain) the agents run as plain processes and AMP appears only as an optional LLM gateway. AMP is the enterprise governance plane — not a hard dependency of the POC.",
            accent=D.INK, fill=D.PANEL, tsize=11.5)
    notes(s, """
WSO2 Agent Manager — AMP — is the governance plane. Three jobs: it hosts and manages the agent as a workload, it can front all the model traffic as an AI gateway for rate-limiting and audit, and it gives you self-observability of the agent itself. Now, I want to be precise and not oversell, because this room will call it out: AMP shows up differently in the two solutions. In the Ballerina approach it's the actual agent runtime. In the LangChain approach the agents are just Python processes and AMP is only an optional model gateway. So think of AMP as the enterprise governance layer you'd wrap around either solution in production — it's not required to make the POC run.
""")
    return s


def slide_models(prs):
    s = D.content_slide(prs, "Level 0 · shared", "No lock-in: the model is a config flag", accent=D.ORANGE)
    provs = [
        ("Ollama", "LOCAL · CREDS-FREE", "qwen2.5 / qwen3.5 family", "On-prem, zero cost, offline demo", D.TEAL, D.TEAL_LT),
        ("Anthropic", "CLOUD", "claude-sonnet-4-6", "Fastest, highest-quality tool use", D.ORANGE, D.ORANGE_LT),
        ("OpenAI", "CLOUD", "gpt-4o", "Alternative managed provider", D.INK, D.PANEL),
        ("WSO2 AMP", "ENTERPRISE GATEWAY", "OpenAI-compatible", "Governed model access + audit", D.VIOLET, D.VIOLET_LT),
    ]
    n = len(provs); gap = 0.3
    cwid = (CW - gap * (n - 1)) / n
    y = BT + 0.2
    h = 2.6
    for i, (nm, tag, model, note, ac, lt) in enumerate(provs):
        x = M + i * (cwid + gap)
        panel(s, x, y, cwid, h, fill=D.WHITE, line=D.LINE)
        rect(s, x, y, cwid, 0.66, fill=lt, shape=MSO_SHAPE.ROUNDED_RECTANGLE, radius=0.06)
        rect(s, x, y + 0.4, cwid, 0.26, fill=lt)
        tb, tf = textbox(s, x + 0.16, y + 0.06, cwid - 0.32, 0.6, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, nm, first=True, size=15, color=D.INK, bold=True, after=1)
        para(tf, tag, size=7.5, color=ac, bold=True)
        tb, tf = textbox(s, x + 0.16, y + 0.85, cwid - 0.32, h - 1.0, anchor=MSO_ANCHOR.TOP)
        para(tf, model, first=True, size=11, color=ac, bold=True, font=D.MONO, after=6, spacing=1.0)
        para(tf, note, size=10.5, color=D.INK_SOFT, spacing=1.12)
        y_flag = y
    tb, tf = textbox(s, M, y + 2.85, CW, 0.9, anchor=MSO_ANCHOR.TOP)
    para(tf, [("Switch with one variable:   ", {"color": D.INK, "bold": True}),
              ("LLM_PROVIDER = ollama | anthropic | openai | amp", {"font": D.MONO, "color": D.ORANGE_DK, "bold": True})],
         first=True, size=13, align=PP_ALIGN.CENTER)
    para(tf, "The default demo runs fully offline on a local model — no vendor account required.",
         size=11, color=D.GRAY, align=PP_ALIGN.CENTER, before=4)
    notes(s, """
This directly answers the lock-in worry. The LLM provider is a single environment variable. Four backends: a local Ollama model for a completely offline, zero-cost run — that's the default for the demo; Anthropic's Claude for the best tool-calling quality; OpenAI as an alternative; and routing through WSO2's AMP gateway when you want governed, audited model access. Same investigation, same code, different provider. That's not a slide-ware claim — the acceptance criteria required us to demonstrate the same run on at least two providers with nothing changed but this flag. For a procurement conversation, this is the answer: you are never married to one AI vendor.
""")
    return s


def slide_tworoads(prs):
    s = D.add_slide(prs, D.NAVY)
    tb, tf = textbox(s, M, 0.75, CW, 0.5)
    para(tf, "THE FORK", first=True, size=13, color=D.ORANGE, bold=True)
    tb, tf = textbox(s, M, 1.15, CW, 1.0)
    para(tf, "Two roads to the same goal", first=True, size=32, color=D.WHITE, bold=True)
    tb, tf = textbox(s, M, 2.05, CW, 0.6)
    para(tf, "Everything so far is shared. Here's where the two solutions diverge — and it comes down to one question:",
         first=True, size=14, color=D.NAVY_TXT, spacing=1.2)
    # the question
    rect(s, M, 2.85, CW, 0.85, fill=D.NAVY_2, shape=MSO_SHAPE.ROUNDED_RECTANGLE, radius=0.06)
    tb, tf = textbox(s, M + 0.3, 2.85, CW - 0.6, 0.85, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, "Where do the topology/correlation tools live, and how do we keep the agent's context small?",
         first=True, size=15, color=D.WHITE, bold=True, align=PP_ALIGN.CENTER)
    # two cards
    y = 4.05
    h = 2.55
    cwid = (CW - 0.5) / 2
    # S1
    panel(s, M, y, cwid, h, fill="10333B", line=D.TEAL, line_w=1.4)
    chip(s, M + 0.25, y + 0.22, "SOLUTION 1", color=D.TEAL, fill="0A2830", size=10, w=1.7)
    tb, tf = textbox(s, M + 0.25, y + 0.7, cwid - 0.5, h - 0.85, anchor=MSO_ANCHOR.TOP)
    para(tf, "Ballerina + MCP Proxy", first=True, size=18, color=D.WHITE, bold=True, after=6)
    para(tf, "One agent talks to one MCP Proxy that federates the backends and lazy-loads their tools. Low-context by a server-side registry.",
         size=12, color="BFE3EA", spacing=1.25)
    # S2
    x2 = M + cwid + 0.5
    panel(s, x2, y, cwid, h, fill="241E52", line=D.VIOLET, line_w=1.4)
    chip(s, x2 + 0.25, y + 0.22, "SOLUTION 2", color="B7A9F5", fill="1B1640", size=10, w=1.7)
    tb, tf = textbox(s, x2 + 0.25, y + 0.7, cwid - 0.5, h - 0.85, anchor=MSO_ANCHOR.TOP)
    para(tf, "LangChain + A2A", first=True, size=18, color=D.WHITE, bold=True, after=6)
    para(tf, "An orchestrator delegates to specialist agents over A2A. Low-context by decomposition — each specialist owns only its own small toolset.",
         size=12, color="D6CEFB", spacing=1.25)
    notes(s, """
This is the pivot slide. Everything up to now is common ground. The two solutions answer one design question differently: where do the local topology and correlation tools live, and how do you stop the agent's context from exploding when the real vendor MCPs expose fifty-plus tools each? Solution one keeps a single agent and puts a proxy in front that federates the backends and reveals their tools lazily from a server-side registry. Solution two breaks the work into specialist agents that each hold only their own small toolset, and coordinates them over the A2A protocol. Same goal, two philosophies. Let's go deep on each.
""")
    return s


# ============================================================================
# SECTION 3 — SOLUTION 1: BALLERINA + MCP PROXY
# ============================================================================
def slide_s1_overview(prs):
    s = D.content_slide(prs, "Solution 1 · Ballerina + MCP Proxy", "The core idea", accent=D.TEAL)
    lw = 6.5
    bullets(s, M, BT + 0.05, lw, 3.8, [
        {"lead": "One agent, one endpoint.", "text": "The Ballerina agent connects to exactly one MCP server — the MCP Proxy on :8290. It never touches Splunk or Datadog directly.", "bc": D.TEAL, "lead_color": D.TEAL_DK},
        {"lead": "The proxy federates.", "text": "Behind that one endpoint it fans out to the Splunk and Datadog MCP backends and adds local topology, correlation, and runbook tools.", "bc": D.TEAL, "lead_color": D.TEAL_DK},
        {"lead": "Small context by lazy loading.", "text": "The proxy hides the big vendor tool manifests in a server-side registry and reveals only what the agent asks for.", "bc": D.TEAL, "lead_color": D.TEAL_DK},
        {"lead": "Full-stack Ballerina.", "text": "Agent, proxy, mock backends, and the 7-service mesh are all Ballerina 2201.13.3 — one language, one build.", "bc": D.TEAL, "lead_color": D.TEAL_DK},
    ], size=12.5, gap=11)
    x = M + lw + 0.45
    w = CW - (x - M)
    callout(s, x, BT + 0.1, w, 1.5, "The best-practice claim",
            "Cross-system correlation is a single-context reasoning task. Keep it in ONE agent — federate the tools, don't fragment the reasoning.",
            accent=D.TEAL, fill=D.TEAL_LT, tsize=12.5)
    stat(s, x, BT + 1.85, w, "1", "MCP endpoint the agent sees", accent=D.TEAL, h=1.15, big_size=40)
    stat(s, x, BT + 3.2, (w - 0.25) / 2, "12", "topology tools", accent=D.INK, h=1.1, big_size=26, lab_size=9.5)
    stat(s, x + (w - 0.25) / 2 + 0.25, BT + 3.2, (w - 0.25) / 2, "1", "language", accent=D.INK, h=1.1, big_size=26, lab_size=9.5)
    notes(s, """
Solution one in a sentence: one agent, one MCP endpoint, and a smart proxy behind it. The agent connects only to the MCP Proxy on port 8290 — it has no idea Splunk and Datadog exist as separate things. The proxy does the federating: it fans out to both vendor backends and adds the local tools that know your topology and runbooks. The headline argument for this shape is on the right: correlation is a single-context reasoning task, so you keep it in one agent's head and federate the tools underneath, rather than splitting the reasoning across multiple agents. And it's full-stack Ballerina — the agent, the proxy, the mocks, and the mesh are all one language, one toolchain.
""")
    return s


def slide_s1_arch(prs):
    s = D.content_slide(prs, "Solution 1 · Ballerina + MCP Proxy", "Architecture", accent=D.TEAL)
    # agent
    node(s, M, BT + 1.3, 2.5, 1.1, "DevOps Agent", "Ballerina · :8092", fill=D.INK, line=D.INK, tcolor=D.WHITE, scolor=D.NAVY_TXT, tsize=13)
    # proxy (big center)
    px = M + 3.5
    pw = 3.6
    panel(s, px, BT + 0.4, pw, 3.4, fill=D.TEAL_LT, line=D.TEAL, line_w=1.6)
    chip(s, px + 0.2, BT + 0.58, "MCP PROXY  ·  :8290", color=D.TEAL_DK, fill=D.WHITE, size=10, w=2.7)
    node(s, px + 0.25, BT + 1.05, pw - 0.5, 0.62, "Federation + routing", None, fill=D.WHITE, line=D.TEAL, tsize=11)
    node(s, px + 0.25, BT + 1.77, pw - 0.5, 0.62, "discover_tools (lazy)", None, fill=D.WHITE, line=D.TEAL, tsize=11)
    node(s, px + 0.25, BT + 2.49, pw - 0.5, 0.62, "topology · correlation · runbooks", None, fill=D.WHITE, line=D.TEAL, tsize=10)
    # connection agent<->proxy
    connect(s, M + 2.5, BT + 1.85, px, BT + 1.85, color=D.INK, width=2, tail=True)
    edge_label(s, M + 3.0, BT + 1.55, "one MCP\nhop", w=1.0, size=8.5, color=D.INK_SOFT, bold=True)
    # backends
    bx = px + pw + 0.6
    bw = CW - (bx - M)
    node(s, bx, BT + 0.75, bw, 1.0, "splunk-mock-mcp", "logs · :8400  ·  4 tools", fill=D.SPLUNK_LT, line=D.SPLUNK, tag="SPLUNK BACKEND", tag_color=D.SPLUNK, tsize=12, ssize=8.5)
    node(s, bx, BT + 2.4, bw, 1.0, "datadog-mock-mcp", "metrics/traces · :8401  ·  8 tools", fill=D.DATADOG_LT, line=D.DATADOG, tag="DATADOG BACKEND", tag_color=D.DATADOG, tsize=12, ssize=8.5)
    connect(s, px + pw, BT + 1.6, bx, BT + 1.25, color=D.SPLUNK, width=1.8, tail=True)
    connect(s, px + pw, BT + 2.6, bx, BT + 2.9, color=D.DATADOG, width=1.8, tail=True)
    edge_label(s, (px + pw + bx) / 2, BT + 2.08, "swap → live\nvendor MCPs", w=1.7, size=8.5, color=D.INK_SOFT, bold=True, h=0.5)
    notes(s, """
Here's the picture. On the left, the Ballerina agent. In the center, the star of the show — the MCP Proxy on 8290. It does three things: federation and routing to the backends, lazy tool discovery, and it hosts the local topology, correlation, and runbook tools. On the right, the two backends — mock Splunk and mock Datadog — which in production you swap for the real vendor MCPs by changing one environment variable ON THE PROXY. The agent never changes. The single most important invariant: the Splunk and Datadog URLs live on the proxy, never on the agent. That's what makes mock-to-live a config flip with zero agent code change.
""")
    return s


def slide_s1_proxy(prs):
    s = D.content_slide(prs, "Solution 1 · Ballerina + MCP Proxy", "Why a proxy?", accent=D.TEAL)
    reasons = [
        ("Small agent context", "The vendor MCPs expose 50+ tools each. Injecting all of them would blow the context window. The proxy keeps them server-side.", D.TEAL),
        ("Mock ⇄ live isolation", "One env var on the proxy switches mock to SaaS. The agent is untouched, so you can stage a rollout safely.", D.ORANGE),
        ("Single policy chokepoint", "Routing, auth (via a gateway), and result hygiene get exactly one home instead of being smeared across the agent.", D.VIOLET),
        ("Fills the vendor gap", "It's Ballerina, so it can also ACT — hit chaos endpoints, run runbooks — and it owns the catalog the vendors don't have.", D.SPLUNK),
    ]
    n = len(reasons)
    gap = 0.3
    cwid = (CW - gap) / 2
    rh = 1.7
    for i, (head, body, ac) in enumerate(reasons):
        r = i // 2
        c = i % 2
        x = M + c * (cwid + gap)
        y = BT + 0.15 + r * (rh + 0.3)
        panel(s, x, y, cwid, rh, fill=D.WHITE, line=D.LINE)
        rect(s, x, y, 0.10, rh, fill=ac)
        tb, tf = textbox(s, x + 0.28, y + 0.2, cwid - 0.5, rh - 0.35, anchor=MSO_ANCHOR.TOP)
        para(tf, head, first=True, size=14.5, color=D.INK, bold=True, after=5, spacing=1.0)
        para(tf, body, size=11.5, color=D.INK_SOFT, spacing=1.18)
    notes(s, """
Four reasons the proxy earns its place. First and most practical: context economics. The real Splunk and Datadog MCPs expose fifty-plus tools each — dump all hundred-plus into the agent's prompt and you've wrecked the context window before it does any work. The proxy keeps them server-side. Second, the mock-to-live swap is isolated to the proxy, so you can stage a rollout. Third, it's the one place for policy — routing, auth, result hygiene — instead of scattering that logic. Fourth, because it's Ballerina and not just a dumb pass-through, it can also act: it runs the runbooks and owns the service catalog that neither vendor MCP knows about.
""")
    return s


def slide_s1_lazy(prs):
    s = D.content_slide(prs, "Solution 1 · Ballerina + MCP Proxy", "Lazy tool loading — the low-context pattern", accent=D.TEAL)
    # flow
    y = BT + 0.35
    node(s, M, y, 2.7, 1.05, "Agent", "tools/list", fill=D.INK, line=D.INK, tcolor=D.WHITE, scolor=D.NAVY_TXT, tsize=13)
    node(s, M + 3.3, y, 3.4, 1.05, "Proxy returns 12 tools", "discover_tools + 11 topology", fill=D.TEAL_LT, line=D.TEAL, tsize=12, ssize=8.5)
    node(s, M + 7.3, y, CW - 7.3, 1.05, "Registry (hidden)", "21+ vendor tools, server-side", fill=D.PANEL, line=D.GRAY_MD, tsize=12, ssize=8.5)
    connect(s, M + 2.7, y + 0.52, M + 3.3, y + 0.52, color=D.INK, tail=True)
    connect(s, M + 6.7, y + 0.52, M + 7.3, y + 0.52, color=D.GRAY_MD, dashed=True)
    # second row: discover
    y2 = y + 1.65
    node(s, M, y2, 2.7, 1.05, "Agent", "discover_tools(\"DD metric\")", fill=D.INK, line=D.INK, tcolor=D.WHITE, scolor=D.NAVY_TXT, tsize=13, ssize=8)
    node(s, M + 3.3, y2, 3.4, 1.05, "Keyword scorer", "top-5 matching manifests", fill=D.ORANGE_LT, line=D.ORANGE, tsize=12, ssize=8.5)
    node(s, M + 7.3, y2, CW - 7.3, 1.05, "Agent absorbs schemas", "calls datadog__get_datadog_metric", fill=D.DATADOG_LT, line=D.DATADOG, tsize=11.5, ssize=8)
    connect(s, M + 2.7, y2 + 0.52, M + 3.3, y2 + 0.52, color=D.INK, tail=True)
    connect(s, M + 6.7, y2 + 0.52, M + 7.3, y2 + 0.52, color=D.ORANGE, tail=True)
    callout(s, M, y2 + 1.5, CW, 1.05, "POC honesty",
            "Today the router is a keyword scorer — accurate enough at ~21 tools. Production swaps in a pgvector + embedding semantic router when the live MCPs bring 50+ tools each.",
            accent=D.AMBER, fill=D.AMBER_LT)
    notes(s, """
This is how the proxy keeps the agent lean. When the agent asks 'what tools do you have,' the proxy answers with just twelve: a discover_tools gateway plus eleven topology tools. The fifty-plus vendor tools stay hidden in a server-side registry. When the agent needs Datadog metrics, it calls discover_tools with a query, the proxy scores the registry and returns the top five matching tool definitions, and the agent folds those schemas into its active toolset and calls them. So the context only ever holds the handful of tools currently relevant. One honest note for the engineers: today that scorer is keyword-based, which is plenty accurate at twenty-odd tools. When you point it at the real MCPs with hundreds of tools, you'd swap in a proper vector-embedding semantic router. That's a known, planned upgrade.
""")
    return s


def slide_s1_routing(prs):
    s = D.content_slide(prs, "Solution 1 · Ballerina + MCP Proxy", "Prefix routing keeps it simple", accent=D.TEAL)
    # center router
    rx = M + CW / 2 - 1.6
    node(s, rx, BT + 0.3, 3.2, 0.95, "routeToolCall()", "split on \"__\"", fill=D.TEAL_LT, line=D.TEAL, tsize=14, ssize=9)
    routes = [
        ("splunk__*", "→ Splunk backend", "de-prefixed & forwarded", D.SPLUNK, D.SPLUNK_LT),
        ("datadog__*", "→ Datadog backend", "de-prefixed & forwarded", D.DATADOG, D.DATADOG_LT),
        ("topology__* / discover", "→ local dispatch", "handled in the proxy", D.TEAL, D.TEAL_LT),
    ]
    n = len(routes); gap = 0.35
    cwid = (CW - gap * (n - 1)) / n
    y = BT + 1.9
    for i, (pat, dest, note, ac, lt) in enumerate(routes):
        x = M + i * (cwid + gap)
        node(s, x, y, cwid, 1.2, dest, note, fill=lt, line=ac, tsize=13, ssize=9)
        cxs = rx + 1.6
        connect(s, cxs, BT + 1.25, x + cwid / 2, y, color=ac, width=1.6, tail=True)
        chip(s, x + cwid / 2 - 0.9, y - 0.42, pat, color=ac, fill=D.WHITE, size=10, w=1.8)
    # tool inventory strip
    y2 = y + 1.65
    panel(s, M, y2, CW, 1.1, fill=D.PANEL, line=D.LINE)
    tb, tf = textbox(s, M + 0.25, y2 + 0.14, CW - 0.5, 0.85, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, [("What the agent can reach:  ", {"bold": True, "color": D.INK}),
              ("11 topology__ ", {"font": D.MONO, "color": D.TEAL_DK, "bold": True}),
              ("(lookup / dependencies / health / correlate_trace / deploys / incidents / runbooks / audit)   +   ", {"color": D.INK_SOFT, "size": 10.5}),
              ("4 splunk__ ", {"font": D.MONO, "color": D.SPLUNK, "bold": True}),
              ("+   ", {"color": D.INK_SOFT}),
              ("8 datadog__", {"font": D.MONO, "color": D.DATADOG, "bold": True})],
         first=True, size=11.5, spacing=1.2)
    notes(s, """
Routing is deliberately boring, which is a compliment. Every tool name is namespaced with a double-underscore prefix. The router splits on that prefix: splunk-underscore-underscore goes to the Splunk backend with the prefix stripped, datadog to Datadog, and everything else — topology and discover_tools — is handled locally inside the proxy. No service mesh, no dynamic discovery magic. The strip at the bottom shows the full inventory the agent can eventually reach: eleven topology tools that we own, plus four Splunk and eight Datadog tools it discovers on demand. Simple routing, powerful surface.
""")
    return s


def slide_s1_flow(prs):
    s = D.content_slide(prs, "Solution 1 · Ballerina + MCP Proxy", "The investigation loop in action", accent=D.TEAL)
    steps = [
        ("discover_tools(\"Datadog metric\")", "reveal the metric tools"),
        ("datadog__get_datadog_metric", "error-rate spike → payment-service"),
        ("topology__get_dependencies", "blast radius → order-service affected"),
        ("datadog__get_datadog_trace", "grab a failing trace"),
        ("topology__correlate_trace", "build the Splunk query + links"),
        ("splunk__splunk_run_query", "logs show mock-bank timeouts"),
        ("topology__find_recent_deploys", "nothing → rule out a deploy"),
        ("topology__list_runbooks → PROPOSE", "disable-chaos, then WAIT"),
    ]
    y = BT + 0.1
    for i, (call, res) in enumerate(steps):
        yy = y + i * 0.58
        is_gate = (i == len(steps) - 1)
        d = 0.36
        rect(s, M, yy, d, d, fill=(D.ORANGE if is_gate else D.TEAL), shape=MSO_SHAPE.OVAL)
        tb, tf = textbox(s, M, yy, d, d, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, str(i + 1), first=True, size=11, color=D.WHITE, bold=True, align=PP_ALIGN.CENTER)
        tb, tf = textbox(s, M + 0.5, yy - 0.04, 5.6, 0.5, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, call, first=True, size=11.5, color=(D.ORANGE_DK if is_gate else D.INK), bold=True, font=D.MONO)
        tb, tf = textbox(s, M + 6.3, yy - 0.04, CW - 6.3, 0.5, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, "→ " + res, first=True, size=11.5, color=D.INK_SOFT)
        if i < len(steps) - 1:
            connect(s, M + d / 2, yy + d, M + d / 2, yy + 0.58, color=D.GRAY_MD, width=1.2)
    notes(s, """
Let's make it concrete — this is a real trace of the agent working the payment incident. It discovers the Datadog metric tools, pulls metrics and sees the error-rate spike on payment-service. It checks dependencies and learns order-service is downstream and affected — that's the blast radius. It grabs a failing trace, correlates it to build the Splunk query, runs that query, and sees the actual log evidence: mock-bank timeouts. It checks recent deploys, finds none, and rules out a bad release. Having gathered evidence from both platforms, it lists runbooks, proposes disable-chaos — and stops at the gate. Notice how it interleaves discover_tools with real tool calls; that's the lazy-loading pattern doing its job mid-investigation.
""")
    return s


def slide_s1_stack(prs):
    s = D.content_slide(prs, "Solution 1 · Ballerina + MCP Proxy", "Stack, tools & runbooks", accent=D.TEAL)
    # left: stack table
    data = [
        ["Layer", "Choice"],
        ["Language / runtime", "Ballerina Swan Lake 2201.13.3"],
        ["MCP transport", "Streamable HTTP · JSON-RPC 2.0"],
        ["Telemetry", "ballerinax/jaeger (OTLP) + prometheus"],
        ["LLM loop", "native tool-use, no SDK · maxTurns 30"],
        ["Default model", "Ollama qwen (local) / claude-sonnet-4-6"],
    ]
    make_table(s, M, BT + 0.1, 6.5, [0.4, 0.6], data, header_fill=D.TEAL_DK,
               first_col_bold=True, row_h=0.56, header_h=0.46, fsize=10.5)
    # right: runbooks
    x = M + 6.9
    w = CW - (x - M)
    panel(s, x, BT + 0.1, w, 3.7, fill=D.PANEL, line=D.LINE)
    card_header(s, x + 0.2, BT + 0.3, w - 0.4, "Runbooks — the fixed allowlist", accent=D.ORANGE)
    rbs = [
        ("disable-chaos", "LIVE — POST /chaos/reset. The demo's recovery lever.", D.GREEN),
        ("restart-service", "stub — kubectl rollout restart", D.GRAY),
        ("clear-cache", "stub — Redis FLUSHDB on inventory", D.GRAY),
        ("freeze-deploys", "stub — sets an in-memory flag", D.GRAY),
    ]
    yy = BT + 0.85
    for nm, desc, ac in rbs:
        chip(s, x + 0.22, yy, nm, color=ac, fill=D.WHITE, size=10, w=1.85)
        tb, tf = textbox(s, x + 2.2, yy - 0.03, w - 2.4, 0.5, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, desc, first=True, size=10, color=D.INK_SOFT, spacing=1.05)
        yy += 0.62
    tb, tf = textbox(s, x + 0.22, yy + 0.05, w - 0.44, 0.7, anchor=MSO_ANCHOR.TOP)
    para(tf, "Every execution appends to an in-memory audit log. No run_cli, ever.",
         first=True, size=10, color=D.GRAY, spacing=1.1)
    notes(s, """
The stack, briefly. It's Ballerina Swan Lake, one pinned version across everything. MCP rides plain JSON-RPC over streamable HTTP — no SDK, no stdio, because stdio doesn't work in Kubernetes. The tool-use loop is hand-rolled with a turn cap of thirty, which we bumped up to absorb the discover_tools round-trips. Telemetry uses the Ballerina Jaeger and Prometheus exporters. On the right, the runbooks — and this is the safety story. There are exactly four, it's a fixed typed allowlist, and only disable-chaos actually acts today; the rest are stubs. There is no general command tool. Every run is audited. For a bank, 'the agent physically cannot do anything not on this list' is the sentence that matters.
""")
    return s


def slide_s1_tradeoffs(prs):
    s = D.content_slide(prs, "Solution 1 · Ballerina + MCP Proxy", "Strengths & honest limits", accent=D.TEAL)
    cwid = (CW - 0.4) / 2
    # strengths
    panel(s, M, BT + 0.1, cwid, 4.35, fill=D.TEAL_LT, line=D.TEAL)
    card_header(s, M + 0.22, BT + 0.32, cwid - 0.44, "✓  Strengths", accent=D.TEAL_DK)
    bullets(s, M + 0.28, BT + 0.85, cwid - 0.55, 3.4, [
        {"lead": "Small, stable context", "text": "no matter how many tools the real MCPs expose.", "bc": D.TEAL},
        {"lead": "Correlation in one context", "text": "logs + spans + topology join in one working set.", "bc": D.TEAL},
        {"lead": "Mock ⇄ live is config", "text": "one env var, proxy-side.", "bc": D.TEAL},
        {"lead": "Single policy chokepoint", "text": "routing, auth, hygiene in one place.", "bc": D.TEAL},
        {"lead": "Bounded remediation", "text": "typed runbook allowlist + approval gate.", "bc": D.TEAL},
        {"lead": "Clean migration path", "text": "wrap with A2A at org boundaries later.", "bc": D.TEAL},
    ], size=11, gap=8)
    # limits
    x2 = M + cwid + 0.4
    panel(s, x2, BT + 0.1, cwid, 4.35, fill=D.AMBER_LT, line=D.AMBER)
    card_header(s, x2 + 0.22, BT + 0.32, cwid - 0.44, "⚠  Known limits (POC)", accent=D.AMBER)
    bullets(s, x2 + 0.28, BT + 0.85, cwid - 0.55, 3.4, [
        {"lead": "Keyword router", "text": "not vector-based; fine at ~21 tools, upgrade for 50+.", "bc": D.AMBER},
        {"lead": "No result hygiene", "text": "live payloads need truncation/neutralization.", "bc": D.AMBER},
        {"lead": "No endpoint auth", "text": "trusted local net; prod defers to the WSO2 gateway.", "bc": D.AMBER},
        {"lead": "Static catalog", "text": "in-code map today; production reads a CMDB.", "bc": D.AMBER},
        {"lead": "Stub runbooks", "text": "only disable-chaos is wired to a real action.", "bc": D.AMBER},
        {"lead": "SSE buffering risk", "text": "a buffering gateway breaks streaming run_runbook.", "bc": D.AMBER},
    ], size=11, gap=8)
    notes(s, """
The honest ledger for solution one. Strengths: the context stays small and stable regardless of vendor tool sprawl; correlation happens in a single reasoning context; mock-to-live is a config flip; there's one place for policy; remediation is bounded; and there's a clean path to wrap it with A2A at organizational boundaries later. The limits are all things we consciously deferred, not surprises: the router is keyword-based for now, there's no result-hygiene layer yet, no endpoint auth because it runs on a trusted network, the catalog is a static file rather than a CMDB, most runbooks are stubs, and you have to make sure any gateway in front doesn't buffer the streaming responses. None of these are architectural dead-ends — they're the production to-do list.
""")
    return s


# ============================================================================
# SECTION 4 — SOLUTION 2: LANGCHAIN + A2A
# ============================================================================
def slide_s2_overview(prs):
    s = D.content_slide(prs, "Solution 2 · LangChain + A2A", "The core idea", accent=D.VIOLET)
    lw = 6.5
    bullets(s, M, BT + 0.05, lw, 3.8, [
        {"lead": "Three agents.", "text": "An orchestrator (DevOpsOverSightAgent) delegates to two specialists — a DataDogAgent and a SplunkAgent — over the A2A protocol.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
        {"lead": "Low-context by decomposition.", "text": "Each specialist eagerly loads only its own small toolset (8 Datadog / 4 Splunk). The vendor manifests never enter the orchestrator's context.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
        {"lead": "No proxy, no discover_tools.", "text": "The proxy dissolves: federation becomes the A2A boundary; correlation & runbooks stay in-process in the orchestrator.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
        {"lead": "Familiar ecosystem.", "text": "Python 3.12, LangChain 1.x on the LangGraph runtime — the stack most teams already know.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
    ], size=12.5, gap=10)
    x = M + lw + 0.45
    w = CW - (x - M)
    callout(s, x, BT + 0.1, w, 1.5, "Same principle, other shape",
            "A2A is used ONLY at the platform-team boundary — not to split correlation. The fusion still happens in one orchestrator context.",
            accent=D.VIOLET, fill=D.VIOLET_LT, tsize=12.5)
    stat(s, x, BT + 1.85, (w - 0.25) / 2, "3", "agents", accent=D.VIOLET, h=1.15, big_size=32)
    stat(s, x + (w - 0.25) / 2 + 0.25, BT + 1.85, (w - 0.25) / 2, "8+4", "specialist tools", accent=D.INK, h=1.15, big_size=26, lab_size=9.5)
    stat(s, x, BT + 3.2, w, "Python 3.12", "LangChain 1.x · LangGraph", accent=D.INK, h=1.1, big_size=24, lab_size=10)
    notes(s, """
Solution two takes the opposite tack. Instead of one agent behind a proxy, you have three agents: an orchestrator and two specialists, a Datadog agent and a Splunk agent, talking over the A2A protocol. The low-context trick here is decomposition — each specialist only ever holds its own eight or four tools, so the big vendor manifests never reach the orchestrator. There's no proxy and no discover_tools; the proxy's job is split between the A2A boundary and in-process tools on the orchestrator. Crucially — and this is the subtle bit — A2A is used only at the platform-team boundary, to delegate to 'the Datadog team' and 'the Splunk team.' The actual correlation still happens in the orchestrator's single context. Same principle as solution one, achieved a different way. And it's the Python-LangChain stack most teams already have muscle memory for.
""")
    return s


def slide_s2_arch(prs):
    s = D.content_slide(prs, "Solution 2 · LangChain + A2A", "Architecture", accent=D.VIOLET)
    # orchestrator center-left
    ox = M
    node(s, ox, BT + 1.4, 3.1, 1.5, "DevOpsOverSightAgent", "orchestrator · :18092", fill=D.INK, line=D.INK, tcolor=D.WHITE, scolor=D.NAVY_TXT, tsize=13, ssize=9)
    tb, tf = textbox(s, ox + 0.1, BT + 2.35, 2.9, 0.5, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, "+ 11 in-process topology / correlation / runbook tools", first=True, size=8, color=D.NAVY_TXT, align=PP_ALIGN.CENTER, spacing=1.0)
    # specialists
    sx = ox + 4.0
    dd = node(s, sx, BT + 0.35, 3.3, 1.15, "DataDogAgent", "A2A server · :18101", fill=D.DATADOG_LT, line=D.DATADOG, tag="SPECIALIST", tag_color=D.DATADOG, tsize=12.5, ssize=8.5)
    sp = node(s, sx, BT + 2.7, 3.3, 1.15, "SplunkAgent", "A2A server · :18102", fill=D.SPLUNK_LT, line=D.SPLUNK, tag="SPECIALIST", tag_color=D.SPLUNK, tsize=12.5, ssize=8.5)
    connect(s, ox + 3.1, BT + 1.75, sx, BT + 0.92, color=D.DATADOG, width=1.8, tail=True)
    connect(s, ox + 3.1, BT + 2.4, sx, BT + 3.27, color=D.SPLUNK, width=1.8, tail=True)
    edge_label(s, (ox + 3.1 + sx) / 2, BT + 1.15, "A2A\nask_datadog_agent", w=1.9, size=8, color=D.DATADOG, bold=True)
    edge_label(s, (ox + 3.1 + sx) / 2, BT + 3.05, "A2A\nask_splunk_agent", w=1.9, size=8, color=D.SPLUNK, bold=True)
    # MCP backends
    mx = sx + 3.6
    mw = CW - (mx - M)
    node(s, mx, BT + 0.55, mw, 0.85, "datadog-mock-mcp", ":18401 · 8 tools", fill=D.WHITE, line=D.DATADOG, tsize=11.5, ssize=8.5)
    node(s, mx, BT + 2.9, mw, 0.85, "splunk-mock-mcp", ":18400 · 4 tools", fill=D.WHITE, line=D.SPLUNK, tsize=11.5, ssize=8.5)
    connect(s, sx + 3.3, BT + 0.92, mx, BT + 0.97, color=D.DATADOG, width=1.5, tail=True)
    connect(s, sx + 3.3, BT + 3.27, mx, BT + 3.32, color=D.SPLUNK, width=1.5, tail=True)
    edge_label(s, (sx + 3.3 + mx) / 2, BT + 1.9, "MCP\n(own client)", w=1.4, size=8, color=D.GRAY, bold=True)
    notes(s, """
The topology. The orchestrator on the far left holds the eleven topology and correlation tools in-process — same tools as solution one, just living inside the orchestrator instead of a proxy. It delegates to two specialist agents: the Datadog agent and the Splunk agent, each a full A2A server on its own port. Each specialist has its own MCP client to its own mock backend. So the flow is: orchestrator calls ask_datadog_agent over A2A, the Datadog agent runs its own little reasoning loop hitting the Datadog MCP, and returns evidence as text. Notice the port numbers are all 1-prefixed — that's deliberate, so this whole stack runs side by side with the Ballerina stack for a live A-B comparison on one machine.
""")
    return s


def slide_s2_a2a(prs):
    s = D.content_slide(prs, "Solution 2 · LangChain + A2A", "The A2A protocol", accent=D.VIOLET)
    lw = 6.4
    bullets(s, M, BT + 0.05, lw, 3.8, [
        {"lead": "Agent cards.", "text": "Each specialist publishes /.well-known/agent-card.json declaring its skill (datadog_evidence, splunk_log_search) and capabilities.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
        {"lead": "JSON-RPC delegation.", "text": "The orchestrator resolves the card, then sends a message and streams the reply. One-way: orchestrator → specialist.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
        {"lead": "Request/response, not long-running tasks.", "text": "Each call is a single round-trip — verified against the SDK, no Task lifecycle.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
        {"lead": "The output contract is load-bearing.", "text": "Evidence crosses as prose, so specialists MUST return trace_ids verbatim, metric values, timestamps. A vague reply starves the orchestrator.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
    ], size=12, gap=9)
    x = M + lw + 0.45
    w = CW - (x - M)
    panel(s, x, BT + 0.1, w, 2.15, fill=D.PANEL, line=D.LINE)
    card_header(s, x + 0.2, BT + 0.3, w - 0.4, "The delegation call", accent=D.VIOLET)
    tb, tf = textbox(s, x + 0.25, BT + 0.85, w - 0.5, 1.3, anchor=MSO_ANCHOR.TOP)
    para(tf, "orchestrator LLM", first=True, size=10.5, color=D.INK, bold=True, after=2)
    para(tf, "  → ask_datadog_agent(\"...\")", size=10, color=D.VIOLET_DK, font=D.MONO, after=2)
    para(tf, "  → A2ACardResolver.get_card()", size=10, color=D.INK_SOFT, font=D.MONO, after=2)
    para(tf, "  → SendMessageRequest (JSON-RPC)", size=10, color=D.INK_SOFT, font=D.MONO, after=2)
    para(tf, "  → specialist ReAct loop → MCP", size=10, color=D.INK_SOFT, font=D.MONO)
    callout(s, x, BT + 2.5, w, 1.5, "Version pin matters",
            "a2a-sdk ≥1.1,<2 is protobuf-based. The older 0.2.x tutorials do NOT apply — build against the installed SDK.",
            accent=D.AMBER, fill=D.AMBER_LT, tsize=11.5)
    notes(s, """
A2A is Google's agent-to-agent protocol, and here's how it actually works in our system. Each specialist publishes an agent card at a well-known URL — think of it as a service descriptor announcing 'I'm the Datadog agent, here's my skill.' The orchestrator resolves that card and sends a JSON-RPC message; the specialist runs its own reasoning loop against its MCP backend and streams back an answer. It's one-way delegation and a simple request/response — we verified there's no long-running task lifecycle needed. The subtle risk, and I want the engineers to hear this: evidence crosses the A2A boundary as prose. So the specialists are prompted to return trace IDs verbatim, exact metric values, timestamps. If a specialist gives a vague summary, the orchestrator can't correlate. That output contract is the quiet bottleneck of this architecture. And a practical gotcha — the A2A SDK went protobuf-based at 1.1, so ignore the older blog tutorials.
""")
    return s


def slide_s2_decomp(prs):
    s = D.content_slide(prs, "Solution 2 · LangChain + A2A", "Low-context by decomposition", accent=D.VIOLET)
    # comparison: proxy lazy vs decomposition
    cwid = (CW - 0.4) / 2
    # left: what it avoids
    panel(s, M, BT + 0.1, cwid, 1.5, fill=D.PANEL, line=D.LINE)
    card_header(s, M + 0.2, BT + 0.3, cwid - 0.4, "The problem (shared)", accent=D.INK)
    tb, tf = textbox(s, M + 0.25, BT + 0.78, cwid - 0.5, 0.7, anchor=MSO_ANCHOR.TOP)
    para(tf, "Real vendor MCPs expose 50+ tools each. Load them all into one agent and the context window is gone.",
         first=True, size=11.5, color=D.INK_SOFT, spacing=1.2)
    # right approach
    panel(s, M + cwid + 0.4, BT + 0.1, cwid, 1.5, fill=D.VIOLET_LT, line=D.VIOLET)
    card_header(s, M + cwid + 0.6, BT + 0.3, cwid - 0.4, "S2's answer", accent=D.VIOLET_DK)
    tb, tf = textbox(s, M + cwid + 0.65, BT + 0.78, cwid - 0.5, 0.7, anchor=MSO_ANCHOR.TOP)
    para(tf, "Give each platform its own agent. The orchestrator only ever sees 2 delegate tools, never the vendor manifests.",
         first=True, size=11.5, color=D.INK_SOFT, spacing=1.2)
    # visual: orchestrator sees 2 tools
    y = BT + 1.95
    node(s, M + 2.0, y, 3.0, 0.9, "Orchestrator", "sees 2 delegate tools + 11 topology", fill=D.INK, line=D.INK, tcolor=D.WHITE, scolor=D.NAVY_TXT, tsize=12.5, ssize=8)
    node(s, M + 0.4, y + 1.5, 3.0, 0.85, "DataDogAgent", "holds 8 tools", fill=D.DATADOG_LT, line=D.DATADOG, tsize=12, ssize=8.5)
    node(s, M + 6.5, y + 1.5, 3.0, 0.85, "SplunkAgent", "holds 4 tools", fill=D.SPLUNK_LT, line=D.SPLUNK, tsize=12, ssize=8.5)
    connect(s, M + 3.0, y + 0.9, M + 1.9, y + 1.5, color=D.DATADOG, tail=True)
    connect(s, M + 4.2, y + 0.9, M + 8.0, y + 1.5, color=D.SPLUNK, tail=True)
    callout(s, M + 9.8, y + 0.2, CW - (9.8), 2.2, "Trade",
            "Cleaner separation & familiar code — at the cost of another network hop and 3× the model non-determinism.",
            accent=D.VIOLET, fill=D.VIOLET_LT, tsize=11)
    notes(s, """
This slide is the direct counterpart to the lazy-loading slide from solution one. Same problem — vendor MCPs have too many tools — different answer. Instead of hiding tools in a proxy registry, you give each platform its own agent that holds only its tools. The orchestrator's context only ever contains two delegate tools plus the eleven topology tools. The Datadog agent quietly holds its eight, the Splunk agent its four, and the orchestrator never sees either manifest. The trade, on the right: you get cleaner separation and code every Python team already knows, but you pay for it with an extra network hop per delegation and — this is real — you now have three models that each have to emit tool calls reliably instead of one, which multiplies the non-determinism you have to manage.
""")
    return s


def slide_s2_gate(prs):
    s = D.content_slide(prs, "Solution 2 · LangChain + A2A", "The hard approval gate", accent=D.VIOLET)
    lw = 6.3
    bullets(s, M, BT + 0.05, lw, 3.8, [
        {"lead": "Code-level, not prompt-level.", "text": "A LangGraph HumanInTheLoopMiddleware physically interrupts the graph before topology__run_runbook executes.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
        {"lead": "The graph pauses.", "text": "/investigate returns the proposal + a sessionId. State is checkpointed by InMemorySaver keyed to that session.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
        {"lead": "Human resumes it.", "text": "Operator POSTs \"approve\" to /chat; the graph resumes with a Command(resume=...) and only then runs the runbook.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
        {"lead": "Fail-safe by default.", "text": "Any non-approval reply is treated as rejection. The runbook does not run.", "bc": D.GREEN, "lead_color": D.GREEN},
    ], size=12, gap=10)
    x = M + lw + 0.45
    w = CW - (x - M)
    node(s, x, BT + 0.1, w, 0.72, "LLM calls run_runbook", None, fill=D.WHITE, line=D.INK, tsize=12)
    connect(s, x + w / 2, BT + 0.82, x + w / 2, BT + 1.2, color=D.INK)
    rect(s, x, BT + 1.25, w, 1.0, fill=D.VIOLET_LT, line=D.VIOLET, line_w=1.8, shape=MSO_SHAPE.ROUNDED_RECTANGLE, radius=0.08)
    tb, tf = textbox(s, x + 0.15, BT + 1.25, w - 0.3, 1.0, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, "⛔  GRAPH INTERRUPT", first=True, size=13.5, color=D.VIOLET_DK, bold=True, align=PP_ALIGN.CENTER, after=2)
    para(tf, "execution physically paused", size=10, color=D.INK_SOFT, align=PP_ALIGN.CENTER)
    tb, tf = textbox(s, x, BT + 2.4, w, 0.4, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, "↓  human POSTs \"approve\"", first=True, size=11, color=D.GREEN, bold=True, align=PP_ALIGN.CENTER)
    node(s, x, BT + 2.9, w, 0.72, "Graph resumes → runbook runs", None, fill=D.GREEN_LT, line=D.GREEN, tsize=12)
    callout(s, x, BT + 3.8, w, 0.85, "Why it's stronger",
            "The model literally cannot execute without a recorded approval — it's enforced by the runtime.",
            accent=D.GREEN, fill=D.GREEN_LT, tsize=11)
    notes(s, """
This is where solution two has a genuine edge worth calling out. In solution one the approval gate is a prompt instruction — the agent is TOLD to list runbooks and wait. Here it's enforced by the runtime. LangGraph's human-in-the-loop middleware physically interrupts the execution graph the instant the model tries to run a runbook. The graph pauses, the state is checkpointed against a session ID, and the investigate call returns the proposal. Nothing resumes until a human posts 'approve,' which fires a resume command — and only then does the runbook execute. And it's fail-safe: anything that isn't a clear approval counts as rejection. For a compliance officer, 'the model cannot execute without a recorded approval, enforced in code' is a stronger sentence than 'we told the model to ask first.'
""")
    return s


def slide_s2_flow(prs):
    s = D.content_slide(prs, "Solution 2 · LangChain + A2A", "The investigation loop with A2A", accent=D.VIOLET)
    steps = [
        ("ask_datadog_agent(...)", "A2A → DataDogAgent → monitors, metrics, sample trace_id", D.DATADOG),
        ("topology__correlate_trace(id)", "in-process → normalize width, build SPL + links", D.VIOLET),
        ("ask_splunk_agent(SPL)", "A2A → SplunkAgent → 502 logs, no deploys", D.SPLUNK),
        ("topology__get_dependencies", "in-process → blast radius", D.VIOLET),
        ("topology__find_recent_deploys", "in-process → none → chaos suspected", D.VIOLET),
        ("run_runbook → INTERRUPT", "graph pauses → returns proposal + sessionId", D.ORANGE),
        ("POST /chat \"approve\"", "graph resumes → disable-chaos → recovery", D.GREEN),
    ]
    y = BT + 0.15
    for i, (call, res, ac) in enumerate(steps):
        yy = y + i * 0.63
        d = 0.36
        rect(s, M, yy, d, d, fill=ac, shape=MSO_SHAPE.OVAL)
        tb, tf = textbox(s, M, yy, d, d, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, str(i + 1), first=True, size=11, color=D.WHITE, bold=True, align=PP_ALIGN.CENTER)
        tb, tf = textbox(s, M + 0.5, yy - 0.04, 5.2, 0.5, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, call, first=True, size=11.5, color=D.INK, bold=True, font=D.MONO)
        tb, tf = textbox(s, M + 5.9, yy - 0.04, CW - 5.9, 0.5, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, "→ " + res, first=True, size=11, color=D.INK_SOFT)
        if i < len(steps) - 1:
            connect(s, M + d / 2, yy + d, M + d / 2, yy + 0.63, color=D.GRAY_MD, width=1.2)
    # legend
    tb, tf = textbox(s, M + 0.5, y + len(steps) * 0.63 + 0.02, CW - 0.5, 0.4, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, [("A2A delegation", {"color": D.DATADOG, "bold": True}),
              ("   ·   ", {"color": D.GRAY}),
              ("in-process tool", {"color": D.VIOLET, "bold": True}),
              ("   ·   ", {"color": D.GRAY}),
              ("gate", {"color": D.ORANGE, "bold": True})], first=True, size=9.5)
    notes(s, """
Same investigation, solution-two mechanics. The orchestrator delegates to the Datadog agent over A2A and gets back monitor state, metrics, and a sample trace ID. Then — in-process — it correlates that trace, normalizing the width and building the Splunk query. It hands that query to the Splunk agent over A2A and gets the 502 logs and 'no deploys' back. It checks dependencies and deploys in-process, concludes chaos, and tries to run the runbook — which trips the graph interrupt. The proposal comes back with a session ID, a human approves via chat, the graph resumes, and disable-chaos runs. The color coding shows the rhythm: it alternates between A2A delegation for evidence and in-process tools for correlation and topology, with the fusion always happening in the orchestrator.
""")
    return s


def slide_s2_stack(prs):
    s = D.content_slide(prs, "Solution 2 · LangChain + A2A", "Stack & the Timeout Chain", accent=D.VIOLET)
    data = [
        ["Layer", "Choice"],
        ["Language / runtime", "Python 3.12 · single uv workspace"],
        ["Agent framework", "LangChain 1.x on LangGraph 1.x (create_agent)"],
        ["A2A", "a2a-sdk ≥1.1,<2 (protobuf)"],
        ["MCP", "official mcp SDK · langchain-mcp-adapters"],
        ["Gate / state", "HumanInTheLoopMiddleware + InMemorySaver"],
    ]
    make_table(s, M, BT + 0.1, 6.5, [0.36, 0.64], data, header_fill=D.VIOLET_DK,
               first_col_bold=True, row_h=0.56, header_h=0.46, fsize=10.5)
    # timeout chain on the right
    x = M + 6.9
    w = CW - (x - M)
    panel(s, x, BT + 0.1, w, 3.7, fill=D.PANEL, line=D.LINE)
    card_header(s, x + 0.2, BT + 0.3, w - 0.4, "The Timeout Chain (must stay ordered)", accent=D.VIOLET)
    chain = [("uvicorn", "600s", 1.0), ("A2A client", "300s", 0.78),
             ("sub-agent LLM", "180s", 0.55), ("MCP call", "30s", 0.32)]
    yy = BT + 0.9
    for nm, val, frac in chain:
        bw = (w - 0.5) * frac
        rect(s, x + 0.25, yy, bw, 0.44, fill=D.VIOLET_LT, line=D.VIOLET, shape=MSO_SHAPE.ROUNDED_RECTANGLE, radius=0.12)
        tb, tf = textbox(s, x + 0.35, yy, w - 0.55, 0.44, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, [(nm + "  ", {"bold": True, "color": D.INK, "size": 10.5}),
                  (val, {"color": D.VIOLET_DK, "bold": True, "font": D.MONO, "size": 10.5})], first=True)
        yy += 0.6
    tb, tf = textbox(s, x + 0.25, yy + 0.02, w - 0.5, 0.55, anchor=MSO_ANCHOR.TOP)
    para(tf, "Largest-outermost. assert_timeout_chain() fails fast at startup if misordered.",
         first=True, size=10, color=D.GRAY, spacing=1.1)
    notes(s, """
The stack: Python 3.12 in a single uv workspace, LangChain 1.x on LangGraph, the official A2A and MCP SDKs, and the human-in-the-loop middleware plus an in-memory checkpointer for the gate. The thing I want to highlight on the right is the Timeout Chain, because it's a lovely example of the operational complexity multi-agent buys you. You now have four nested timeouts across process boundaries — the web server, the A2A client, the sub-agent's LLM call, and the MCP call — and they MUST be ordered largest-outermost, or a timeout fires at the wrong layer and you get confusing hangs. There's a startup assertion that refuses to boot if they're misordered. That's a discipline you simply don't need with a single in-process agent.
""")
    return s


def slide_s2_tradeoffs(prs):
    s = D.content_slide(prs, "Solution 2 · LangChain + A2A", "Strengths & honest limits", accent=D.VIOLET)
    cwid = (CW - 0.4) / 2
    panel(s, M, BT + 0.1, cwid, 4.35, fill=D.VIOLET_LT, line=D.VIOLET)
    card_header(s, M + 0.22, BT + 0.32, cwid - 0.44, "✓  Strengths", accent=D.VIOLET_DK)
    bullets(s, M + 0.28, BT + 0.85, cwid - 0.55, 3.4, [
        {"lead": "Familiar ecosystem", "text": "Python + LangChain; low ramp for most teams.", "bc": D.VIOLET},
        {"lead": "Hard, code-level gate", "text": "graph interrupt, not a prompt instruction.", "bc": D.VIOLET},
        {"lead": "Structural low-context", "text": "specialists cap tools by construction.", "bc": D.VIOLET},
        {"lead": "Clean protocol separation", "text": "A2A at the boundary, MCP for tools, in-process fusion.", "bc": D.VIOLET},
        {"lead": "Same model flexibility", "text": "4 providers, config-swappable.", "bc": D.VIOLET},
        {"lead": "Full self-observability", "text": "one trace spans user → A2A → specialist → MCP.", "bc": D.VIOLET},
    ], size=11, gap=8)
    x2 = M + cwid + 0.4
    panel(s, x2, BT + 0.1, cwid, 4.35, fill=D.AMBER_LT, line=D.AMBER)
    card_header(s, x2 + 0.22, BT + 0.32, cwid - 0.44, "⚠  Known limits (POC)", accent=D.AMBER)
    bullets(s, x2 + 0.28, BT + 0.85, cwid - 0.55, 3.4, [
        {"lead": "3× model non-determinism", "text": "three agents must each emit clean tool calls.", "bc": D.AMBER},
        {"lead": "Prose output contract", "text": "vague specialist replies starve correlation.", "bc": D.AMBER},
        {"lead": "Extra network hop", "text": "A2A adds latency vs an in-process call.", "bc": D.AMBER},
        {"lead": "Timeout Chain to maintain", "text": "four nested timeouts, order-sensitive.", "bc": D.AMBER},
        {"lead": "In-memory state", "text": "restart mid-approval drops the pending runbook.", "bc": D.AMBER},
        {"lead": "SDK version drift", "text": "a2a-sdk 1.1 is protobuf; pin carefully.", "bc": D.AMBER},
    ], size=11, gap=8)
    notes(s, """
The ledger for solution two. Strengths: it's the ecosystem most teams already know, the approval gate is enforced in code, low-context is structural rather than a clever trick, the protocol separation is clean, and it keeps the same model flexibility and self-observability as solution one. The limits skew operational: you've tripled the model non-determinism because three agents must each behave; the prose output contract between agents is a real correlation risk; every delegation is a network hop; the timeout chain needs maintaining; state is in-memory so a restart mid-approval loses the pending action; and you have to pin the A2A SDK carefully. Notice the pattern versus solution one — solution one's risks are mostly 'we deferred this feature,' solution two's are mostly 'distributed systems are harder to operate.'
""")
    return s


# ============================================================================
# SECTION 5 — COMPARISON & PATH FORWARD
# ============================================================================
def slide_crux(prs):
    s = D.content_slide(prs, "Comparison", "The architectural crux")
    # center principle
    rect(s, M, BT + 0.05, CW, 0.95, fill=D.INK, shape=MSO_SHAPE.ROUNDED_RECTANGLE, radius=0.05)
    tb, tf = textbox(s, M + 0.3, BT + 0.05, CW - 0.6, 0.95, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, "Both keep correlation in ONE reasoning context. They differ only in how they keep the toolset small.",
         first=True, size=15, color=D.WHITE, bold=True, align=PP_ALIGN.CENTER)
    cwid = (CW - 0.4) / 2
    y = BT + 1.3
    # S1
    panel(s, M, y, cwid, 3.15, fill=D.TEAL_LT, line=D.TEAL, line_w=1.4)
    card_header(s, M + 0.22, y + 0.25, cwid - 0.44, "Solution 1 — federate the tools", accent=D.TEAL_DK)
    bullets(s, M + 0.3, y + 0.78, cwid - 0.6, 2.2, [
        {"lead": "Low-context via", "text": "a proxy with a server-side registry + lazy discover_tools.", "bc": D.TEAL},
        {"lead": "Correlation locus", "text": "one Ballerina agent holds all evidence directly.", "bc": D.TEAL},
        {"lead": "Boundary", "text": "one process federates; nothing is fragmented.", "bc": D.TEAL},
    ], size=11.5, gap=9)
    # S2
    x2 = M + cwid + 0.4
    panel(s, x2, y, cwid, 3.15, fill=D.VIOLET_LT, line=D.VIOLET, line_w=1.4)
    card_header(s, x2 + 0.22, y + 0.25, cwid - 0.44, "Solution 2 — decompose the agents", accent=D.VIOLET_DK)
    bullets(s, x2 + 0.3, y + 0.78, cwid - 0.6, 2.2, [
        {"lead": "Low-context via", "text": "specialist agents that each own a small toolset.", "bc": D.VIOLET},
        {"lead": "Correlation locus", "text": "the orchestrator fuses prose evidence from specialists.", "bc": D.VIOLET},
        {"lead": "Boundary", "text": "A2A at the platform-team line — NOT inside correlation.", "bc": D.VIOLET},
    ], size=11.5, gap=9)
    notes(s, """
Zoom out. The headline is on the black bar: both solutions keep correlation in one reasoning context. That's the shared conviction — you do NOT want to split the Splunk-versus-Datadog join across separate agents, because then each has to lossily summarize into text before anyone can correlate, and you've put a compression step at exactly the wrong place. Given that, the only real difference is how each keeps the toolset small. Solution one federates the tools behind a proxy and reveals them lazily. Solution two decomposes into specialist agents that each hold few tools, and uses A2A only at the platform-team boundary — never inside the correlation itself. If a specialist's prose is thin, solution two's fusion suffers; solution one never has that problem because the evidence never leaves the agent as prose. That's the crux of the trade.
""")
    return s


def slide_scorecard(prs):
    s = D.content_slide(prs, "Comparison", "Side-by-side scorecard")
    T, V = D.TEAL_DK, D.VIOLET_DK
    data = [
        ["Dimension", "Solution 1 · Ballerina + Proxy", "Solution 2 · LangChain + A2A"],
        ["Low-context strategy", "Proxy lazy-load (server registry)", "Agent decomposition (specialists)"],
        ["Correlation locus", "One agent, direct", "Orchestrator fuses prose"],
        ["Approval gate", {"text": "Prompt-level instruction", "color": D.AMBER}, {"text": "Code-level graph interrupt", "color": D.GREEN}],
        ["Language / stack", "Ballerina 2201.13.3", "Python 3.12 / LangChain 1.x"],
        ["Moving parts", {"text": "Fewer — 1 agent + proxy", "color": D.GREEN}, {"text": "More — 3 agents + hop", "color": D.AMBER}],
        ["Model non-determinism", {"text": "×1 (single agent)", "color": D.GREEN}, {"text": "×3 (each specialist)", "color": D.AMBER}],
        ["Ecosystem familiarity", {"text": "Ballerina — niche", "color": D.AMBER}, {"text": "Python/LangChain — broad", "color": D.GREEN}],
        ["Tool-sprawl at 50+ tools", "Needs vector router upgrade", "Handled by decomposition"],
        ["WSO2 AMP fit", "Native agent runtime", "Optional LLM gateway only"],
        ["Ops surface", {"text": "Single reasoning process", "color": D.GREEN}, {"text": "Distributed; timeout chain", "color": D.AMBER}],
    ]
    make_table(s, M, BT + 0.02, CW, [0.28, 0.36, 0.36], data,
               header_fill=D.INK, first_col_bold=True, row_h=0.375, header_h=0.42, fsize=9.5, hsize=10.5)
    notes(s, """
Here's the honest side-by-side — and per our plan, I'm NOT going to hand you a verdict on this slide; the next one is where we decide together. Read it by theme. Solution one wins on fewer moving parts, single-model determinism, and being the native fit for WSO2's own agent platform. Solution two wins on the code-level approval gate, ecosystem familiarity — it's Python and LangChain, which everybody has — and it handles tool sprawl structurally. The amber cells aren't dealbreakers, they're the cost of each approach: solution one's proxy needs a smarter router at scale and Ballerina is a niche skill; solution two is a distributed system with the operational weight that implies. Which set of trade-offs fits the client depends on their team, their governance posture, and how much they value WSO2-native versus mainstream tooling.
""")
    return s


def slide_recommendation(prs):
    s = D.content_slide(prs, "Comparison · measured A/B — local vs cloud", "Recommendation — measured on two models")
    G, A, R = D.GREEN, D.AMBER, D.RED
    colw = (CW - 0.5) / 2
    xL, xR = M, M + colw + 0.5
    tb, tf = textbox(s, xL, BT, colw, 0.3, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, "LOCAL  —  qwen2.5:14b (Ollama)", first=True, size=11, color=D.INK_SOFT, bold=True)
    tb, tf = textbox(s, xR, BT, colw, 0.3, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, "CLOUD  —  Claude Haiku 4.5", first=True, size=11, color=D.ORANGE_DK, bold=True)
    localdata = [
        ["18 runs each", "LangChain", "Ballerina"],
        ["Correct-proposal", {"text": "61%  (11/18)", "color": G, "bold": True}, {"text": "28%  (5/18)", "color": R, "bold": True}],
        ["Median latency", {"text": "62 s", "color": G, "bold": True}, {"text": "78 s", "color": A}],
        ["LLM calls / inv.", {"text": "~19", "color": D.INK}, {"text": "~9", "color": D.INK}],
    ]
    clouddata = [
        ["18 runs each", "LangChain", "Ballerina"],
        ["Correct-proposal", {"text": "100%  (18/18)", "color": G, "bold": True}, {"text": "100%  (18/18)", "color": G, "bold": True}],
        ["Median latency", {"text": "36 s", "color": A}, {"text": "14 s", "color": G, "bold": True}],
        ["LLM calls / inv.", {"text": "~19", "color": D.INK}, {"text": "~9", "color": D.INK}],
    ]
    make_table(s, xL, BT + 0.36, colw, [0.42, 0.29, 0.29], localdata, header_fill=D.INK,
               first_col_bold=True, row_h=0.38, header_h=0.38, fsize=10, hsize=9.5)
    make_table(s, xR, BT + 0.36, colw, [0.42, 0.29, 0.29], clouddata, header_fill=D.ORANGE_DK,
               first_col_bold=True, row_h=0.38, header_h=0.38, fsize=10, hsize=9.5)
    # verdict panel
    vy = BT + 2.02
    panel(s, M, vy, CW, 2.15, fill=D.PANEL, line=D.LINE)
    card_header(s, M + 0.22, vy + 0.18, CW - 0.44, "What the two models say", accent=D.ORANGE)
    bullets(s, M + 0.3, vy + 0.62, CW - 0.6, 1.45, [
        {"lead": "Model choice dominates reliability.", "text": "Local 28–61% → cloud 100% for both. The 14B's flakiness (it narrates a tool call instead of making it, and quits early) is a model problem, not an architecture one — don't ship the local model.", "bc": D.ORANGE},
        {"lead": "The speed winner FLIPS with the model.", "text": "Slow local → LangChain wins (small, cheap calls). Fast cloud → Ballerina wins ~2.6× (14 vs 36 s): its ~9 calls beat LangChain's ~19 network round-trips. 'Fewer round-trips = faster' holds — but only once inference is fast.", "bc": D.ORANGE},
        {"lead": "On the model you'd actually ship (cloud):", "text": "both 100% reliable, Ballerina meaningfully faster. So runtime no longer decides it — the qualitative scorecard does, on client context: Ballerina = fewer parts + WSO2-native; LangChain = code-level gate + Python familiarity.", "bc": D.ORANGE},
    ], size=9.5, gap=4, spacing=1.03)
    tb, tf = textbox(s, M, vy + 2.25, CW, 0.4, anchor=MSO_ANCHOR.TOP)
    para(tf, "Method: identical model per column; 3 datasets × 6 runs each (warm-up discarded); stacks run sequentially, never concurrent; mock MCP backends; same chaos + payload. Local = qwen2.5:14b on Ollama; cloud = claude-haiku-4-5 via Anthropic. Latency = time-to-proposal via curl.",
         first=True, size=8, color=D.GRAY, spacing=1.1)
    notes(s, """
We measured both architectures on two very different models — the creds-free local qwen2.5:14b and Anthropic's Claude Haiku 4.5 — 18 runs each, three datasets of six, run sequentially. Two findings dominate. First, model choice matters more than architecture for reliability: on the local 14B, correct-proposal rates were a shaky 28 to 61 percent (the model tends to narrate the tool call it's about to make and then quit without making it); on Haiku, BOTH stacks hit 100 percent, 18 for 18. So the local flakiness is a model problem, full stop — don't ship the 14B. Second, and this is the fun one: the speed winner flips with the model. On the slow local model, LangChain was faster (62 vs 78 seconds) because Ballerina's single big growing context makes each of its calls expensive. On the fast cloud model, that per-call penalty disappears and raw call COUNT dominates — so Ballerina's roughly nine calls beat LangChain's nineteen network round-trips, and Ballerina is about 2.6 times faster, 14 seconds versus 36. My original architecture argument — fewer round-trips is faster — was right after all, but only once inference is fast enough that network round-trips, not per-call compute, are the bottleneck. The practical upshot: on the model you'd actually deploy, both are 100 percent reliable and Ballerina is meaningfully faster, so runtime stops being the deciding factor and the qualitative scorecard — WSO2-native and fewer moving parts versus a code-level gate and Python familiarity — decides it on the client's context.
""")
    return s


def slide_demo(prs):
    s = D.content_slide(prs, "Comparison", "The 5-minute demo — payment-service P1")
    beats = [
        ("0:00", "Inject chaos", "payment-service starts returning 502s + 2s latency.", D.RED),
        ("0:45", "Signals diverge", "Datadog monitor fires; Splunk logs fill with errors.", D.AMBER),
        ("1:15", "Investigate", "Agent runs the cross-platform loop, correlates by trace_id.", D.TEAL),
        ("3:30", "Propose & approve", "Agent proposes disable-chaos; operator approves.", D.ORANGE),
        ("4:15", "Recover", "Runbook runs; mesh recovers; agent posts a postmortem.", D.GREEN),
    ]
    y = BT + 0.3
    # timeline bar
    rect(s, M + 0.2, y + 0.5, CW - 0.4, 0.05, fill=D.LINE)
    n = len(beats)
    seg = (CW - 0.4) / n
    for i, (t, title, desc, ac) in enumerate(beats):
        cx = M + 0.2 + seg * i + seg / 2
        rect(s, cx - 0.09, y + 0.42, 0.18, 0.18, fill=ac, shape=MSO_SHAPE.OVAL)
        tb, tf = textbox(s, cx - seg / 2 + 0.1, y - 0.15, seg - 0.2, 0.4, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, t, first=True, size=13, color=ac, bold=True, align=PP_ALIGN.CENTER, font=D.MONO)
        panel(s, cx - seg / 2 + 0.15, y + 0.85, seg - 0.3, 2.1, fill=D.WHITE, line=D.LINE)
        rect(s, cx - seg / 2 + 0.15, y + 0.85, seg - 0.3, 0.09, fill=ac)
        tb, tf = textbox(s, cx - seg / 2 + 0.3, y + 1.1, seg - 0.6, 1.7, anchor=MSO_ANCHOR.TOP)
        para(tf, title, first=True, size=12.5, color=D.INK, bold=True, after=5, spacing=1.0)
        para(tf, desc, size=10, color=D.INK_SOFT, spacing=1.15)
    callout(s, M, y + 3.3, CW, 1.0, "Runs offline, resets clean",
            "No vendor credentials. A token-gated chaos endpoint injects the fault; disable-chaos (or reset) returns to a clean baseline for the next run.",
            accent=D.ORANGE)
    notes(s, """
This is the demo you'll actually run, and it's the same five beats for both solutions. At zero, you inject chaos into payment-service — 502s and added latency. Within about forty-five seconds the signals diverge: Datadog's monitor fires and Splunk fills with errors. You trigger the agent; it runs the whole cross-platform investigation and correlates by trace ID in a couple of minutes. Around three-thirty it proposes disable-chaos and waits; the operator approves. By four-fifteen the runbook has run, the mesh has recovered, and the agent posts a postmortem. The whole thing runs offline with no vendor accounts, the fault is injected through a token-gated endpoint, and it resets to a clean baseline so you can run it again for the next audience. That repeatability is what makes it a sales asset, not a one-take magic trick.
""")
    return s


def slide_enterprise(prs):
    s = D.content_slide(prs, "Comparison", "POC → Enterprise: the hardening path")
    data = [
        ["Capability", "POC state", "Enterprise requirement"],
        ["Identity & access", "Unauthenticated local net", "OIDC/SSO + workload identity + per-tool RBAC at the gateway"],
        ["Secrets", ".env variables", "Vault / cloud secrets manager; rotation"],
        ["Audit log", "In-memory, session-scoped", "Durable, tamper-evident, tied to identity, SIEM-fed"],
        ["Approval gate", "S1 prompt / S2 code-level", "Hard code-level interception in both; recorded signal"],
        ["Service catalog", "Static in-code map", "CMDB-backed, team-maintained, versioned"],
        ["Observability backends", "Mock MCP servers", "Live Splunk (app 7931) + Datadog (Bits AI) MCPs"],
        ["Trace-ID handling", "Verbatim (demo id)", "True 64/128-bit normalization on real traffic"],
        ["Scale", "Single node", "Agents on K8s; proxy behind LB; managed infra"],
    ]
    make_table(s, M, BT + 0.02, CW, [0.24, 0.30, 0.46], data,
               header_fill=D.INK, first_col_bold=True, row_h=0.44, header_h=0.42, fsize=9.5, hsize=10.5)
    notes(s, """
This is the slide the architects will scrutinize, and the message is: the POC is a faithful vertical slice, not a throwaway. Every row is a known step from here to production, and none of them change the core design. Identity moves from 'trusted local network' to OIDC plus per-tool RBAC at the gateway. Secrets move to a vault. The audit log becomes durable and tamper-evident and feeds your SIEM. The approval gate becomes hard code-level interception in both solutions — solution two already does this. The catalog moves from a file to your CMDB. The mock MCP servers get swapped for the real Splunk and Datadog MCPs — and that's the config-not-code swap we designed for. Trace-ID normalization gets exercised for real. And it scales onto Kubernetes. The point: nothing here requires re-architecting. It's a hardening checklist.
""")
    return s


def slide_gotchas(prs):
    s = D.content_slide(prs, "Comparison", "Cross-cutting gotchas to respect")
    items = [
        ("Trace-ID width (64 vs 128-bit)", "The #1 correctness bug. Normalize or the agent sees 'no logs.' Mocks mask it.", D.RED),
        ("NATS async propagation", "HTTP trace context auto-propagates; NATS does not. Inject traceparent into the envelope.", D.AMBER),
        ("Untraced Postgres", "Turn on SQL connector tracing or DB latency is invisible to the agent.", D.AMBER),
        ("SSE buffering at the gateway", "A buffering proxy breaks streaming run_runbook progress.", D.AMBER),
        ("Model non-determinism (Ollama)", "Keep maxTurns ≥ 25; prefer a cloud model for the live demo.", D.AMBER),
        ("In-memory state", "Audit log & pending approvals are volatile — a restart drops them.", D.AMBER),
    ]
    n = len(items)
    gap = 0.3
    cwid = (CW - gap) / 2
    rh = 1.28
    for i, (head, body, ac) in enumerate(items):
        r = i // 2
        c = i % 2
        x = M + c * (cwid + gap)
        y = BT + 0.15 + r * (rh + 0.22)
        panel(s, x, y, cwid, rh, fill=D.WHITE, line=D.LINE)
        rect(s, x, y, 0.10, rh, fill=ac)
        tb, tf = textbox(s, x + 0.28, y + 0.16, cwid - 0.5, rh - 0.3, anchor=MSO_ANCHOR.TOP)
        para(tf, head, first=True, size=12.5, color=D.INK, bold=True, after=3, spacing=1.0)
        para(tf, body, size=10.5, color=D.INK_SOFT, spacing=1.12)
    notes(s, """
A field guide of the traps, so nobody rediscovers them the hard way. The big one, again, is trace-ID width — normalize between 64 and 128-bit or correlation silently returns nothing. NATS is the async blind spot: HTTP propagates trace context automatically, message queues don't, so you inject the traceparent into the envelope yourself. Turn on Postgres query tracing or database latency is invisible. Don't put a buffering proxy in front of streaming runbook progress. Ollama's tool-calling is non-deterministic, so keep the turn budget generous and use a cloud model when you're live in front of a client. And remember all the state — audit log, pending approvals — is in-memory in the POC, so a restart forgets everything. These six are the difference between 'works in the demo' and 'works on real traffic.'
""")
    return s


def slide_summary(prs):
    s = D.content_slide(prs, "Wrap-up", "Summary & next steps")
    lw = 6.7
    panel(s, M, BT + 0.1, lw, 4.3, fill=D.PANEL, line=D.LINE)
    card_header(s, M + 0.25, BT + 0.32, lw - 0.5, "What we proved", accent=D.ORANGE)
    bullets(s, M + 0.32, BT + 0.85, lw - 0.65, 3.4, [
        {"lead": "The capability works.", "text": "cross-platform diagnosis + approved remediation in a 5-minute, offline, laptop demo."},
        {"lead": "Two credible architectures", "text": "— Ballerina + MCP Proxy and LangChain + A2A — each with clear trade-offs."},
        {"lead": "The durable bets hold:", "text": "MCP as the contract, single-context correlation, propose-before-act, model portability."},
        {"lead": "A clean path to production", "text": "exists for either — a hardening checklist, not a re-architecture."},
    ], size=12, gap=10)
    x = M + lw + 0.4
    w = CW - (x - M)
    panel(s, x, BT + 0.1, w, 4.3, fill=D.INK)
    tb, tf = textbox(s, x + 0.28, BT + 0.35, w - 0.56, 0.5)
    para(tf, "NEXT STEPS", first=True, size=12, color=D.ORANGE, bold=True)
    steps = [
        "Fill in the recommendation with the client's team & governance context.",
        "Pick one architecture for a hardening spike (auth + live MCPs).",
        "Wire real Splunk & Datadog MCPs; exercise trace-ID normalization.",
        "Run the demo live with the client on their own laptop.",
    ]
    tb, tf = textbox(s, x + 0.28, BT + 0.9, w - 0.56, 3.3, anchor=MSO_ANCHOR.TOP)
    for i, st in enumerate(steps):
        para(tf, [(f"{i+1}   ", {"bold": True, "color": D.ORANGE, "size": 13}),
                  (st, {"color": D.WHITE, "size": 11.5})], first=(i == 0), spacing=1.18, after=11)
    notes(s, """
To sum up. We proved the capability is real, not slideware: cross-platform diagnosis and approved remediation, five minutes, offline, on a laptop. We built it two credible ways, each with honest trade-offs you can now weigh. The durable design bets held up under both: MCP as the contract boundary, correlation in one context, propose-before-act, and model portability. And there's a clean, checklist-style path to production for either. Next steps: first, we finish the recommendation together using the client's actual context — that's the one input we deliberately left open. Then pick one architecture for a hardening spike, wire in the real Splunk and Datadog MCPs and prove out trace-ID normalization, and get it running live on the client's own laptop. That last one is what turns a POC into a project.
""")
    return s


def slide_appendix(prs):
    s = D.content_slide(prs, "Appendix", "Ports & endpoints reference")
    cwid = (CW - 0.4) / 2
    d1 = [
        ["Solution 1 · Ballerina", "Port"],
        ["DevOps Agent", "8092 → 8000"],
        ["MCP Proxy", "8290"],
        ["splunk-mock-mcp", "8400"],
        ["datadog-mock-mcp", "8401"],
        ["payment chaos endpoint", "9196"],
        ["Prometheus scrape", "9797"],
    ]
    make_table(s, M, BT + 0.1, cwid, [0.68, 0.32], d1, header_fill=D.TEAL_DK,
               first_col_bold=True, row_h=0.44, header_h=0.44, fsize=10)
    d2 = [
        ["Solution 2 · LangChain", "Port"],
        ["Orchestrator", "18092 → 8000"],
        ["DataDogAgent (A2A)", "18101"],
        ["SplunkAgent (A2A)", "18102"],
        ["datadog-mock-mcp", "18401"],
        ["splunk-mock-mcp", "18400"],
        ["OTLP collector", "14317 / 14318"],
    ]
    make_table(s, M + cwid + 0.4, BT + 0.1, cwid, [0.68, 0.32], d2, header_fill=D.VIOLET_DK,
               first_col_bold=True, row_h=0.44, header_h=0.44, fsize=10)
    tb, tf = textbox(s, M, BT + 3.65, CW, 0.9, anchor=MSO_ANCHOR.TOP)
    para(tf, [("Shared:  ", {"bold": True, "color": D.INK}),
              ("demo trace_id ", {"color": D.INK_SOFT}),
              ("abc123def456789012345678deadbeef", {"font": D.MONO, "color": D.ORANGE_DK, "bold": True}),
              ("   ·   WSO2 AMP console ", {"color": D.INK_SOFT}),
              (":3000", {"font": D.MONO, "color": D.INK, "bold": True}),
              ("   ·   chaos token ", {"color": D.INK_SOFT}),
              ("dev-chaos-token", {"font": D.MONO, "color": D.INK, "bold": True})],
         first=True, size=11, spacing=1.3)
    para(tf, "The LangChain stack 1-prefixes every host port so both stacks run side-by-side for a live A/B on one machine.",
         size=10.5, color=D.GRAY, before=6)
    notes(s, """
A reference card for whoever runs the stacks. The key thing to notice is the port numbering: the LangChain stack deliberately 1-prefixes every port that the Ballerina stack uses — 8092 becomes 18092, 8400 becomes 18400, and so on. That's not an accident; it means you can bring up both stacks on the same laptop at the same time and do a genuine side-by-side A/B of the two architectures against the same workload. The shared demo trace ID, the AMP console login, and the chaos token are all here too. Keep this slide handy during setup.
""")
    return s


def slide_closing(prs):
    s = D.add_slide(prs, D.NAVY)
    rect(s, 0, 0, SW, 0.16, fill=D.ORANGE)
    wso2_mark(s, M, 0.55, color=D.WHITE, size=22)
    tb, tf = textbox(s, M, 2.9, CW, 1.4)
    para(tf, "Thank you.", first=True, size=44, color=D.WHITE, bold=True, after=8)
    para(tf, "Questions, pushback, and better ideas all welcome — this is a team effort.",
         size=16, color=D.NAVY_TXT, spacing=1.2)
    rect(s, M, 5.1, 3.0, 0.05, fill=D.ORANGE)
    tb, tf = textbox(s, M, 5.35, CW, 0.5, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, [("Scott Bechtel", {"bold": True, "color": D.WHITE}),
              ("   ·   WSO2 Forward Deployed Engineering", {"color": D.NAVY_TXT})], first=True, size=13)
    notes(s, """
Close it out. Thank the team explicitly — this was built collaboratively and the design arguments got sharper because people pushed on them. Invite pushback genuinely: if someone sees a flaw in the scorecard or a better way to frame the recommendation, that's exactly the conversation we want before we take a version to the client. Open the floor for questions.
""")
    return s


# ============================================================================
# ASSEMBLY
# ============================================================================
def main():
    prs = D.new_deck()
    pg = {"n": 0}
    foot = []

    def add(fn, content=True):
        s = fn(prs)
        pg["n"] += 1
        if content:
            foot.append((s, pg["n"]))
        return s

    # front matter
    add(slide_title, content=False)
    add(slide_agenda)
    add(slide_exec)
    # section 1
    add(lambda p: D.section_slide(p, "01", "The Problem",
        "Why cross-platform incident diagnosis is slow, risky, and manual — and what 'good' looks like.",
        accent=D.ORANGE), content=False)
    add(slide_silo); add(slide_tax); add(slide_forces); add(slide_stakeholders); add(slide_success)
    # section 2
    add(lambda p: D.section_slide(p, "02", "Level 0 Architecture",
        "The concepts both solutions share: the mesh, telemetry fan-out, MCP, correlation, and the approval gate.",
        accent=D.ORANGE), content=False)
    add(slide_twotier); add(slide_mesh); add(slide_fanout); add(slide_mcp); add(slide_correlation)
    add(slide_agentjob); add(slide_e2e); add(slide_amp); add(slide_models)
    add(slide_tworoads, content=False)
    # section 3
    add(lambda p: D.section_slide(p, "03", "Ballerina + MCP Proxy",
        "One agent, one MCP endpoint that federates Splunk & Datadog behind lazy-loaded tools.",
        accent=D.TEAL), content=False)
    add(slide_s1_overview); add(slide_s1_arch); add(slide_s1_proxy); add(slide_s1_lazy)
    add(slide_s1_routing); add(slide_s1_flow); add(slide_s1_stack); add(slide_s1_tradeoffs)
    # section 4
    add(lambda p: D.section_slide(p, "04", "LangChain + A2A",
        "An orchestrator that delegates to Datadog & Splunk specialist agents over the A2A protocol.",
        accent=D.VIOLET), content=False)
    add(slide_s2_overview); add(slide_s2_arch); add(slide_s2_a2a); add(slide_s2_decomp)
    add(slide_s2_gate); add(slide_s2_flow); add(slide_s2_stack); add(slide_s2_tradeoffs)
    # section 5
    add(lambda p: D.section_slide(p, "05", "Comparison & Path Forward",
        "An honest scorecard, the 5-minute demo, and what production hardening looks like.",
        accent=D.ORANGE), content=False)
    add(slide_crux); add(slide_scorecard); add(slide_recommendation); add(slide_demo)
    add(slide_enterprise); add(slide_gotchas); add(slide_summary); add(slide_appendix)
    add(slide_closing, content=False)

    total = pg["n"]
    for s, p in foot:
        footer(s, p, total)

    out = "$OUT"
    prs.save(out)
    print(f"saved {out}  ({total} slides)")
    issues = D.qa_report(prs)
    real = [i for i in issues if not (i[6].strip().isdigit() and len(i[6].strip()) <= 2)]
    print(f"QA off-slide shapes: {len(issues)} (decorative section numbers excluded: {len(real)} real)")
    for i in real:
        print("  ", i)
    return out


if __name__ == "__main__":
    main()
