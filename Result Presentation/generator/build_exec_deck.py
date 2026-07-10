"""build_exec_deck.py — DevOps OverSight Agent: Executive Overview.

A short, high-level companion to the 48-slide deep dive. Same WSO2-branded
visual system (decklib.py), pitched at CEO/COO/CTO: business framing,
simplified architecture, the workflow cycle, and the measured cloud-model
results table.
"""
import decklib as D
from decklib import (para, textbox, rect, panel, bullets, callout, stat, node,
                     connect, edge_label, chip, card_header, make_table,
                     wso2_mark, footer, PP_ALIGN, MSO_ANCHOR, MSO_SHAPE)

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
    rect(s, 0, D.SLIDE_H - 0.10, SW, 0.10, fill=D.ORANGE)
    wso2_mark(s, M, 0.55, color=D.WHITE, size=22)
    tb, tf = textbox(s, M + 1.15, 0.55, 6, 0.5, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, "|   Executive Briefing", first=True, size=12.5, color=D.NAVY_TXT)
    tb, tf = textbox(s, M, 2.5, 11.5, 0.4)
    para(tf, "EXECUTIVE OVERVIEW", first=True, size=14, color=D.ORANGE, bold=True)
    tb, tf = textbox(s, M, 2.93, 11.9, 1.6)
    para(tf, "The DevOps OverSight Agent", first=True, size=44, color=D.WHITE, bold=True, spacing=1.0)
    tb, tf = textbox(s, M, 4.15, 11.2, 1.2)
    para(tf, "An AI agent that diagnoses production incidents in minutes — across "
              "both your logging and monitoring platforms — and never acts without "
              "a human's sign-off.", first=True, size=16, color=D.NAVY_TXT, spacing=1.25)
    chip(s, M, 5.55, "Measured on a production-grade AI model", w=4.7, color=D.ORANGE, fill="3A2410", size=11, h=0.4)
    rect(s, M, 6.66, CW, 0.014, fill=D.NAVY_2)
    tb, tf = textbox(s, M, 6.82, CW, 0.4, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, [("Scott Bechtel", {"bold": True, "color": D.WHITE}),
              ("   ·   For leadership review", {"color": D.NAVY_TXT}),
              ("   ·   July 2026", {"color": D.NAVY_TXT})], first=True, size=12)
    return s


def slide_execsummary(prs):
    s = D.content_slide(prs, "The one-slide version", "Executive summary")
    lw = 6.7
    bullets(s, M, BT + 0.1, lw, 3.6, [
        {"lead": "The problem:", "text": "engineers lose 20–40 minutes per major incident manually cross-referencing two separate tools before they even know what's wrong."},
        {"lead": "What we built:", "text": "an AI agent that does that cross-tool detective work automatically — then proposes one specific fix and waits for a human to approve it."},
        {"lead": "It never acts alone:", "text": "no fix runs, no system changes, without an explicit human approval. This is enforced, not just policy."},
        {"lead": "It's measured, not promised:", "text": "on a production-grade AI model, it correctly diagnosed the test incident 18 times out of 18."},
    ], size=13.5, gap=13)
    x = M + lw + 0.4
    w = CW - (x - M)
    stat(s, x, BT + 0.1, w, "100%", "correct diagnosis rate (measured)", accent=D.ORANGE, h=1.35, big_size=38, lab_size=11)
    stat(s, x, BT + 1.65, (w - 0.25) / 2, "14–36s", "time to a proposed fix", accent=D.TEAL, h=1.2, big_size=22, lab_size=9.5)
    stat(s, x + (w - 0.25) / 2 + 0.25, BT + 1.65, (w - 0.25) / 2, "0", "vendor lock-in", accent=D.VIOLET, h=1.2, big_size=26, lab_size=9.5)
    callout(s, x, BT + 3.05, w, 1.0, "Bottom line",
            "This isn't a concept — it's a working system with measured, repeatable results.",
            accent=D.ORANGE)
    notes(s, """
If you remember one slide, this is it. Every major incident starts the same painful way — engineers manually cross-referencing a logging tool and a monitoring tool, by hand, under pressure, for 20 to 40 minutes before they even have a theory. We built an AI agent that automates that cross-referencing, proposes one specific fix, and then stops — it will not touch production without a human explicitly approving. And critically, this isn't a pitch: on a production-grade AI model, we measured it getting the diagnosis right 18 times out of 18 in controlled testing.
""")
    return s


def slide_problem(prs):
    s = D.content_slide(prs, "The business problem", "The cost of manually correlating two tools")
    lw = 6.6
    bullets(s, M, BT + 0.1, lw, 3.6, [
        {"lead": "Two systems, no shared language.", "text": "Your logs live in one platform, your metrics and traces in another. They don't talk to each other."},
        {"lead": "A person is the integration.", "text": "During an incident, an engineer manually copies identifiers between tools, cross-referencing by hand and by memory."},
        {"lead": "It doesn't scale.", "text": "The bigger and more complex your systems get, the worse this gets — and it depends on whoever happens to be on call."},
        {"lead": "The stakes are real.", "text": "Every minute of manual correlation is a minute of extended downtime, customer impact, and risk exposure."},
    ], size=13.5, gap=12)
    x = M + lw + 0.45
    w = CW - (x - M)
    stat(s, x, BT + 0.1, w, "20–40 min", "lost per major incident\nto manual correlation alone", accent=D.RED, h=1.9, big_size=34, lab_size=12, fill=D.RED_LT, line=D.RED_LT)
    callout(s, x, BT + 2.2, w, 1.85, "Why it matters at your level",
            "This is a direct, measurable line item in mean-time-to-resolution — and MTTR is a direct line item in customer trust and operational cost.",
            accent=D.ORANGE)
    notes(s, """
This is the business case in plain terms. Your organization almost certainly runs a dedicated logging platform and a separate metrics and monitoring platform — that's standard and it's the right call individually. The problem is the seam between them is entirely manual. During a live incident, an engineer is doing the integration work by hand: copying an identifier from one tool, pasting it into a search in the other, cross-referencing in their head. Industry experience puts that at 20 to 40 minutes per major incident, every time, and it scales badly as your systems grow. That's not a technical curiosity — it's minutes of extended downtime and customer impact on every P1.
""")
    return s


def slide_whatwebuilt(prs):
    s = D.content_slide(prs, "Introduction", "What it is, in plain terms")
    lw = 6.5
    bullets(s, M, BT + 0.1, lw, 3.8, [
        {"lead": "It watches.", "text": "The agent continuously has access to both your logging and monitoring platforms — the same data your engineers already look at."},
        {"lead": "It investigates automatically.", "text": "When something breaks, it pulls evidence from both tools and connects them using the identifier that already links them together."},
        {"lead": "It proposes — it doesn't act.", "text": "It names one specific fix from a pre-approved list. It never invents an action and never runs one unsupervised."},
        {"lead": "A human always decides.", "text": "The fix only executes after an engineer explicitly approves it. Every action is logged."},
    ], size=13, gap=11)
    x = M + lw + 0.45
    w = CW - (x - M)
    node(s, x, BT + 0.2, w, 0.85, "Your telemetry", "logging + monitoring platforms", fill=D.PANEL, line=D.LINE, tsize=13)
    connect(s, x + w / 2, BT + 1.05, x + w / 2, BT + 1.4, color=D.GRAY_MD)
    node(s, x, BT + 1.45, w, 0.85, "AI Agent", "investigates & proposes", fill=D.INK, line=D.INK, tcolor=D.WHITE, scolor=D.NAVY_TXT, tsize=13)
    connect(s, x + w / 2, BT + 2.3, x + w / 2, BT + 2.65, color=D.GRAY_MD)
    node(s, x, BT + 2.7, w, 0.85, "Human approval", "mandatory gate", fill=D.ORANGE_LT, line=D.ORANGE, tsize=13)
    connect(s, x + w / 2, BT + 3.55, x + w / 2, BT + 3.9, color=D.GREEN)
    node(s, x, BT + 3.95, w, 0.75, "Fix executes", "recovery + record", fill=D.GREEN_LT, line=D.GREEN, tsize=12.5)
    notes(s, """
In plain terms: the agent watches the same telemetry your engineers already have access to, and when something breaks, it does the cross-tool detective work automatically instead of a human doing it by hand. The critical distinction: it proposes, it does not act. It names one specific, pre-approved fix, and the fix only runs after a human explicitly signs off. That approval step is not a suggestion in a prompt — it's a hard gate the system enforces. Everything it does is recorded.
""")
    return s


def slide_workflow(prs):
    s = D.content_slide(prs, "How it works", "The workflow cycle")
    steps = [
        ("1", "Detect", "An alert fires — an anomaly in monitoring, or an incoming alert.", D.INK, D.WHITE, D.LINE),
        ("2", "Investigate", "The agent pulls evidence from both platforms and links it by a shared identifier.", D.INK, D.WHITE, D.LINE),
        ("3", "Diagnose", "Root cause is identified, and the agent assesses what else is affected.", D.INK, D.WHITE, D.LINE),
        ("4", "Suggest a runbook", "The agent proposes ONE specific, named fix — never vague advice.", D.INK, D.WHITE, D.LINE),
        ("5", "Approve", "A human reviews the evidence and the proposed fix, then explicitly approves.", D.ORANGE_DK, D.ORANGE_LT, D.ORANGE),
        ("6", "Remediate & recover", "The fix runs, systems recover, and a record is generated automatically.", D.INK, D.WHITE, D.LINE),
    ]
    gap = 0.28
    colw = (CW - 2 * gap) / 3
    row_h = 1.95
    y0 = BT + 0.05
    boxes = []
    for i, (n, title, desc, tcol, fillc, linec) in enumerate(steps):
        r, c = divmod(i, 3)
        x = M + c * (colw + gap)
        y = y0 + r * (row_h + 0.28)
        boxes.append((x, y))
        panel(s, x, y, colw, row_h, fill=fillc, line=linec, line_w=1.4)
        d = 0.46
        rect(s, x + 0.16, y + 0.16, d, d, fill=tcol, shape=MSO_SHAPE.OVAL)
        tb, tf = textbox(s, x + 0.16, y + 0.16, d, d, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, n, first=True, size=17, color=D.WHITE, bold=True, align=PP_ALIGN.CENTER)
        tb, tf = textbox(s, x + 0.18, y + 0.72, colw - 0.36, row_h - 0.85, anchor=MSO_ANCHOR.TOP)
        para(tf, title, first=True, size=14, color=(D.ORANGE_DK if i == 4 else D.INK), bold=True, after=4, spacing=1.0)
        para(tf, desc, size=10.5, color=D.INK_SOFT, spacing=1.14)
    # connectors: within each row only (0->1->2, 3->4->5) — a diagonal
    # row-wrap arrow (2->3) would cross visually through box 5, so the
    # numbering alone carries the reading order across the row break.
    for i in range(2):
        x1, y1 = boxes[i]; x2, y2 = boxes[i + 1]
        connect(s, x1 + colw, y1 + row_h / 2, x2, y2 + row_h / 2, color=D.GRAY_MD, width=1.6)
    for i in range(3, 5):
        x1, y1 = boxes[i]; x2, y2 = boxes[i + 1]
        connect(s, x1 + colw, y1 + row_h / 2, x2, y2 + row_h / 2, color=D.GRAY_MD, width=1.6)
    notes(s, """
This is the cycle, start to finish, and it's the same shape a skilled engineer follows manually — just automated and fast. Detect: something breaks. Investigate: the agent gathers evidence from both platforms and links it by a shared identifier, the same way an engineer would but without the manual copy-paste. Diagnose: it identifies the root cause and checks what else is affected. Suggest a runbook: it names one specific fix — not generic advice, a specific, pre-approved action. Approve — highlighted here in orange because it's the most important box on this slide — a human reviews the evidence and must explicitly say yes before anything happens. Only then: remediate and recover, and the whole thing is documented automatically.
""")
    return s


def slide_tworoads(prs):
    s = D.add_slide(prs, D.NAVY)
    tb, tf = textbox(s, M, 1.5, CW, 0.5)
    para(tf, "TWO WAYS WE BUILT IT", first=True, size=13, color=D.ORANGE, bold=True)
    tb, tf = textbox(s, M, 1.95, CW, 1.0)
    para(tf, "We built it twice, to compare", first=True, size=34, color=D.WHITE, bold=True)
    tb, tf = textbox(s, M, 2.85, 11.2, 0.9)
    para(tf, "Same capability, same test scenario — two different engineering approaches, "
              "so we could evaluate real trade-offs instead of guessing.",
         first=True, size=15, color=D.NAVY_TXT, spacing=1.25)
    y = 4.0
    h = 2.4
    cwid = (CW - 0.5) / 2
    panel(s, M, y, cwid, h, fill="10333B", line=D.TEAL, line_w=1.4)
    chip(s, M + 0.25, y + 0.22, "SOLUTION 1", color=D.TEAL, fill="0A2830", size=10, w=1.7)
    tb, tf = textbox(s, M + 0.25, y + 0.68, cwid - 0.5, h - 0.85, anchor=MSO_ANCHOR.TOP)
    para(tf, "Ballerina + MCP Proxy", first=True, size=18, color=D.WHITE, bold=True, after=6)
    para(tf, "One agent, one gateway to both platforms. Built to run natively on our WSO2 Agent Manager platform.",
         size=11.5, color="BFE3EA", spacing=1.25)
    x2 = M + cwid + 0.5
    panel(s, x2, y, cwid, h, fill="241E52", line=D.VIOLET, line_w=1.4)
    chip(s, x2 + 0.25, y + 0.22, "SOLUTION 2", color="B7A9F5", fill="1B1640", size=10, w=1.7)
    tb, tf = textbox(s, x2 + 0.25, y + 0.68, cwid - 0.5, h - 0.85, anchor=MSO_ANCHOR.TOP)
    para(tf, "LangChain + A2A", first=True, size=18, color=D.WHITE, bold=True, after=6)
    para(tf, "Specialist agents divide the work, one per platform. Built in Python — the most widely adopted AI agent ecosystem.",
         size=11.5, color="D6CEFB", spacing=1.25)
    notes(s, """
We didn't want to guess which engineering approach was better, so we built the exact same capability twice and tested both against the same scenario. Solution one is built in Ballerina, WSO2's own language, and runs natively on our Agent Manager platform — one agent, one connection point, minimal moving parts. Solution two is built in Python using LangChain, the most widely used AI agent framework, and splits the investigation across specialist agents. Both are covered in the next two slides, and then we'll show you what we actually measured.
""")
    return s


def slide_sol1(prs):
    s = D.content_slide(prs, "Solution 1", "Ballerina + MCP Proxy", accent=D.TEAL)
    lw = 6.3
    bullets(s, M, BT + 0.15, lw, 3.6, [
        {"lead": "One agent, one gateway.", "text": "A single AI agent connects through one gateway that reaches both your logging and monitoring platforms.", "bc": D.TEAL, "lead_color": D.TEAL_DK},
        {"lead": "Fewer moving parts.", "text": "Fewer components to operate, secure, and audit — a simpler system to run day to day.", "bc": D.TEAL, "lead_color": D.TEAL_DK},
        {"lead": "Native to our platform.", "text": "Runs directly on WSO2's own Agent Manager, our platform for governing and observing AI agents.", "bc": D.TEAL, "lead_color": D.TEAL_DK},
        {"lead": "One consistent language.", "text": "The entire stack — agent, gateway, and services — is built in a single language end to end.", "bc": D.TEAL, "lead_color": D.TEAL_DK},
    ], size=13, gap=13)
    x = M + lw + 0.5
    w = CW - (x - M)
    node(s, x, BT + 0.3, w, 0.9, "AI Agent", None, fill=D.INK, line=D.INK, tcolor=D.WHITE, scolor=D.NAVY_TXT, tsize=14)
    connect(s, x + w / 2, BT + 1.2, x + w / 2, BT + 1.6, color=D.TEAL, width=2)
    node(s, x, BT + 1.65, w, 0.9, "Gateway", "single connection point", fill=D.TEAL_LT, line=D.TEAL, tsize=14, ssize=9.5)
    connect(s, x + w * 0.28, BT + 2.55, x + w * 0.1, BT + 3.0, color=D.SPLUNK)
    connect(s, x + w * 0.72, BT + 2.55, x + w * 0.9, BT + 3.0, color=D.DATADOG)
    node(s, x, BT + 3.05, w * 0.46, 0.75, "Logging", None, fill=D.SPLUNK_LT, line=D.SPLUNK, tsize=11.5)
    node(s, x + w * 0.54, BT + 3.05, w * 0.46, 0.75, "Monitoring", None, fill=D.DATADOG_LT, line=D.DATADOG, tsize=11.5)
    notes(s, """
Solution one, at a glance: one agent, one gateway, reaching both your logging and monitoring tools. The appeal here is simplicity — fewer components means fewer things to operate, secure, and audit. It's also the option that runs natively on WSO2's own Agent Manager platform, which is our purpose-built way of governing and observing AI agents in production. And the entire stack, top to bottom, is one consistent programming language, which simplifies maintenance for a small platform team.
""")
    return s


def slide_sol2(prs):
    s = D.content_slide(prs, "Solution 2", "LangChain + A2A", accent=D.VIOLET)
    lw = 6.3
    bullets(s, M, BT + 0.15, lw, 3.6, [
        {"lead": "Specialist agents.", "text": "A lead agent delegates to two specialist agents, one dedicated to each platform.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
        {"lead": "Built on Python.", "text": "Uses LangChain, the most widely adopted framework for building AI agents — a large hiring and support pool.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
        {"lead": "Approval enforced in code.", "text": "The human-approval step is built into the system's control flow, not just an instruction to the AI.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
        {"lead": "Scales to many platforms.", "text": "This division-of-labor pattern extends cleanly if more tools or teams are added later.", "bc": D.VIOLET, "lead_color": D.VIOLET_DK},
    ], size=13, gap=13)
    x = M + lw + 0.5
    w = CW - (x - M)
    node(s, x, BT + 0.15, w, 0.85, "Lead Agent", None, fill=D.INK, line=D.INK, tcolor=D.WHITE, scolor=D.NAVY_TXT, tsize=13.5)
    connect(s, x + w * 0.28, BT + 1.0, x + w * 0.15, BT + 1.4, color=D.DATADOG)
    connect(s, x + w * 0.72, BT + 1.0, x + w * 0.85, BT + 1.4, color=D.SPLUNK)
    node(s, x, BT + 1.45, w * 0.46, 0.8, "Monitoring", "specialist agent", fill=D.DATADOG_LT, line=D.DATADOG, tsize=12, ssize=9)
    node(s, x + w * 0.54, BT + 1.45, w * 0.46, 0.8, "Logging", "specialist agent", fill=D.SPLUNK_LT, line=D.SPLUNK, tsize=12, ssize=9)
    connect(s, x + w * 0.23, BT + 2.25, x + w * 0.23, BT + 2.6, color=D.DATADOG)
    connect(s, x + w * 0.77, BT + 2.25, x + w * 0.77, BT + 2.6, color=D.SPLUNK)
    node(s, x, BT + 2.65, w * 0.46, 0.7, "Monitoring", None, fill=D.WHITE, line=D.DATADOG, tsize=11)
    node(s, x + w * 0.54, BT + 2.65, w * 0.46, 0.7, "Logging", None, fill=D.WHITE, line=D.SPLUNK, tsize=11)
    notes(s, """
Solution two takes a divide-and-conquer approach: a lead agent delegates to two specialist agents, one that only knows the monitoring platform and one that only knows the logging platform. It's built in Python on LangChain, which is the most widely adopted framework in the AI agent space — a real advantage for hiring and long-term support. Its other genuine edge: the human-approval step is enforced directly in the system's code, not just as an instruction to the model. And this specialist-agent pattern scales cleanly if you later want to add more tools or more teams into the picture.
""")
    return s


def slide_results(prs):
    s = D.content_slide(prs, "Measured results", "What we actually measured")
    data = [
        ["Metric — measured on a production-grade AI model", "Ballerina + Proxy", "LangChain + A2A"],
        ["Correct diagnosis rate", {"text": "100%  (18 / 18 test runs)", "color": D.GREEN, "bold": True}, {"text": "100%  (18 / 18 test runs)", "color": D.GREEN, "bold": True}],
        ["Median time to a proposed fix", {"text": "~14 seconds", "color": D.GREEN, "bold": True}, {"text": "~36 seconds", "color": D.INK}],
        ["Test runs evaluated", "18  (3 independent batches of 6)", "18  (3 independent batches of 6)"],
    ]
    make_table(s, M, BT + 0.05, CW, [0.42, 0.29, 0.29], data, header_fill=D.INK,
               first_col_bold=True, row_h=0.52, header_h=0.48, fsize=11.5, hsize=11)
    callout(s, M, BT + 2.45, CW, 1.05, "Why this matters",
            "Both are reliable enough to trust in a live environment. Ballerina resolves faster in this "
            "test because it makes fewer hops between agents for the same investigation.",
            accent=D.ORANGE)
    callout(s, M, BT + 3.65, CW, 1.1, "A critical cost finding",
            "A free, locally-hosted AI model is possible for either approach, but was only 28–61% reliable in "
            "the same test. Reliability came from using a production-grade model, not from which architecture we chose — "
            "worth weighing directly against licensing cost.",
            accent=D.VIOLET, fill=D.VIOLET_LT)
    tb, tf = textbox(s, M, BT + 4.85, CW, 0.3, anchor=MSO_ANCHOR.TOP)
    para(tf, "Method: identical simulated incident injected into a test service; timed end-to-end from alert to a proposed fix; "
              "3 independent test batches of 6 runs per approach.", first=True, size=8.5, color=D.GRAY, spacing=1.1)
    notes(s, """
This is the slide with the receipts. We ran a controlled test — the same simulated incident, injected 18 separate times, for each architecture, on a production-grade AI model. Both got the diagnosis right every single time: 18 out of 18. Ballerina resolved faster in this test, about 14 seconds versus 36, because its design makes fewer round trips between agents for the same investigation. But I want to flag the most important finding on this slide, in the purple box: we also tested both approaches on a free, locally-hosted AI model, and reliability dropped to somewhere between 28 and 61 percent — for BOTH architectures. That tells us reliability is primarily a function of which AI model you use, not which of these two architectures you pick. That's a direct, quantifiable input into any cost-versus-reliability conversation about self-hosting a model versus paying for a cloud provider.
""")
    return s


def slide_governance(prs):
    s = D.content_slide(prs, "Trust & governance", "Nothing changes without a human")
    cards = [
        ("Propose, never act alone", "The agent names a fix and stops. It cannot execute a change without an explicit, recorded human approval.", D.ORANGE, D.ORANGE_LT),
        ("A bounded set of actions", "The agent can only ever propose from a fixed, pre-approved list of fixes — never an arbitrary command.", D.TEAL, D.TEAL_LT),
        ("Every action is logged", "Every proposal, approval, and executed action is recorded in an audit trail.", D.VIOLET, D.VIOLET_LT),
    ]
    n = len(cards); gap = 0.35
    cwid = (CW - gap * (n - 1)) / n
    y = BT + 0.2
    h = 3.6
    for i, (head, body, ac, lt) in enumerate(cards):
        x = M + i * (cwid + gap)
        panel(s, x, y, cwid, h, fill=D.WHITE, line=D.LINE)
        rect(s, x, y, cwid, 0.85, fill=lt, shape=MSO_SHAPE.ROUNDED_RECTANGLE, radius=0.05)
        rect(s, x, y + 0.55, cwid, 0.3, fill=lt)
        tb, tf = textbox(s, x + 0.25, y + 0.2, cwid - 0.5, 0.5, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, f"{i+1}", first=True, size=22, color=ac, bold=True)
        tb, tf = textbox(s, x + 0.25, y + 1.05, cwid - 0.5, h - 1.2, anchor=MSO_ANCHOR.TOP)
        para(tf, head, first=True, size=15, color=D.INK, bold=True, spacing=1.05, after=8)
        para(tf, body, size=11.5, color=D.INK_SOFT, spacing=1.25)
    notes(s, """
For anyone in this room thinking about risk and governance, this is the slide that matters most. Three hard rules, and they're enforced by the system, not by policy documents. One: the agent proposes a fix and stops — it cannot execute a change without an explicit human approval recorded against that specific incident. Two: it can only ever choose from a small, pre-approved list of fixes; there is no path for it to invent or run an arbitrary command. Three: every proposal, every approval, and every executed action is written to an audit log. This is what makes an AI agent acceptable to run against production systems in a regulated environment.
""")
    return s


def slide_flexibility(prs):
    s = D.content_slide(prs, "Flexibility", "No AI vendor lock-in")
    lw = 6.6
    bullets(s, M, BT + 0.15, lw, 3.4, [
        {"lead": "The AI model is a setting, not a commitment.", "text": "Switch between AI providers, or run entirely on your own infrastructure, without changing the system."},
        {"lead": "Works fully offline if required.", "text": "A locally-hosted, no-cost model option exists for environments that can't use an outside AI vendor."},
        {"lead": "Same investigation, any provider.", "text": "We've proven the same investigation completes successfully across multiple AI providers with no code changes."},
    ], size=13.5, gap=13)
    x = M + lw + 0.5
    w = CW - (x - M)
    provs = [("Local model", "no cost, offline", D.TEAL, D.TEAL_LT), ("Cloud providers", "your choice of vendor", D.ORANGE, D.ORANGE_LT),
             ("WSO2 gateway", "governed, audited access", D.VIOLET, D.VIOLET_LT)]
    yy = BT + 0.2
    for nm, sub, ac, lt in provs:
        node(s, x, yy, w, 1.0, nm, sub, fill=lt, line=ac, tsize=13.5, ssize=10)
        yy += 1.18
    notes(s, """
This addresses a real procurement and resilience concern. Which AI provider this system uses is a configuration setting, not an architectural commitment — you can point it at a locally-hosted model with zero cost and zero outside dependency, or at any major cloud AI provider, or route it through our own WSO2 gateway for governed, audited access. We've proven the same investigation runs successfully across multiple providers with no code changes. You are never locked into a single AI vendor.
""")
    return s


def slide_demo(prs):
    s = D.content_slide(prs, "Proof, not promises", "A real 5-minute demonstration")
    beats = [
        ("Inject", "A real fault is introduced into a test service.", D.RED),
        ("Detect & investigate", "The agent notices and automatically investigates across both platforms.", D.TEAL),
        ("Propose & approve", "It proposes a specific fix; an operator approves it.", D.ORANGE),
        ("Recover", "The fix runs and the system returns to healthy — automatically documented.", D.GREEN),
    ]
    n = len(beats); gap = 0.3
    cwid = (CW - gap * (n - 1)) / n
    y = BT + 0.3
    for i, (title, desc, ac) in enumerate(beats):
        x = M + i * (cwid + gap)
        panel(s, x, y, cwid, 2.4, fill=D.WHITE, line=D.LINE)
        rect(s, x, y, cwid, 0.09, fill=ac)
        tb, tf = textbox(s, x + 0.18, y + 0.22, cwid - 0.36, 2.0, anchor=MSO_ANCHOR.TOP)
        para(tf, f"{i+1}", first=True, size=20, color=ac, bold=True, after=4)
        para(tf, title, size=13, color=D.INK, bold=True, after=6, spacing=1.05)
        para(tf, desc, size=10.5, color=D.INK_SOFT, spacing=1.2)
    callout(s, M, y + 2.7, CW, 0.95, "Runs on a laptop, no live accounts required",
            "This can be demonstrated live, end to end, in under five minutes — including for a client, on the spot.",
            accent=D.ORANGE)
    notes(s, """
Everything on this deck can be demonstrated live in under five minutes, on a laptop, without needing any live vendor accounts. We inject a real fault into a test service, the agent detects and investigates automatically, it proposes a specific fix that an operator approves, and the system recovers with an automatic record of what happened. This is repeatable on demand — including in front of a client, live.
""")
    return s


def slide_recommendation(prs):
    s = D.content_slide(prs, "Where things stand", "Our read, and what would decide it")
    panel(s, M, BT + 0.1, CW, 1.0, fill=D.ORANGE_LT, line=D.ORANGE)
    tb, tf = textbox(s, M + 0.3, BT + 0.1, CW - 0.6, 1.0, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, "Both approaches are production-viable on a real AI model. Ballerina measured faster; "
              "LangChain offers a code-enforced approval gate and a larger talent pool.",
         first=True, size=13.5, color=D.ORANGE_DK, bold=True, align=PP_ALIGN.CENTER, spacing=1.15)
    cwid = (CW - 0.4) / 2
    y = BT + 1.35
    h = 2.9
    panel(s, M, y, cwid, h, fill=D.TEAL_LT, line=D.TEAL)
    card_header(s, M + 0.22, y + 0.22, cwid - 0.44, "Favors Ballerina + Proxy", accent=D.TEAL_DK)
    bullets(s, M + 0.3, y + 0.68, cwid - 0.6, 2.0, [
        {"text": "Standardizing on our own WSO2 platform.", "bc": D.TEAL},
        {"text": "Fewest components to run and secure.", "bc": D.TEAL},
        {"text": "Faster measured response time.", "bc": D.TEAL},
    ], size=12, gap=10)
    x2 = M + cwid + 0.4
    panel(s, x2, y, cwid, h, fill=D.VIOLET_LT, line=D.VIOLET)
    card_header(s, x2 + 0.22, y + 0.22, cwid - 0.44, "Favors LangChain + A2A", accent=D.VIOLET_DK)
    bullets(s, x2 + 0.3, y + 0.68, cwid - 0.6, 2.0, [
        {"text": "Teams already build in Python.", "bc": D.VIOLET},
        {"text": "Approval gate enforced in code, by design.", "bc": D.VIOLET},
        {"text": "Broadest hiring and support pool.", "bc": D.VIOLET},
    ], size=12, gap=10)
    notes(s, """
Here's our honest read. Both are ready for production use on a real AI model — this is not a coin flip between something that works and something that doesn't. Ballerina measured faster and has fewer moving parts, and it's the option built natively for our own agent platform. LangChain has its own genuine edge: its approval gate is enforced directly in the code rather than relying on an instruction, and it's built on the technology stack the widest pool of engineering talent already knows. The deciding factor from here isn't more technology testing — it's which of these fits your team and your governance posture, and that's the conversation we'd like to have next.
""")
    return s


def slide_nextsteps(prs):
    s = D.content_slide(prs, "Next steps", "Path to a production pilot")
    steps = [
        "Choose a direction — or run a short pilot of both against a real, low-risk service.",
        "Connect it to your live logging and monitoring platforms (no code changes required).",
        "Finalize the approval workflow and audit requirements with your compliance team.",
        "Run a live, supervised pilot on a non-critical service before wider rollout.",
    ]
    y = BT + 0.3
    for i, st in enumerate(steps):
        panel(s, M, y, CW, 0.9, fill=D.WHITE, line=D.LINE)
        d = 0.5
        rect(s, M + 0.18, y + 0.2, d, d, fill=D.ORANGE, shape=MSO_SHAPE.OVAL)
        tb, tf = textbox(s, M + 0.18, y + 0.2, d, d, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, str(i + 1), first=True, size=17, color=D.WHITE, bold=True, align=PP_ALIGN.CENTER)
        tb, tf = textbox(s, M + 0.85, y, CW - 1.1, 0.9, anchor=MSO_ANCHOR.MIDDLE)
        para(tf, st, first=True, size=13.5, color=D.INK, spacing=1.15)
        y += 1.08
    notes(s, """
The path from here is short and low-risk. First, decide on a direction — or run a brief pilot of both approaches against one real, low-stakes service to build internal confidence. Second, connect it to your actual logging and monitoring platforms; that's a configuration change, not new code. Third, finalize the approval workflow and audit requirements with compliance so it satisfies your specific governance posture. Fourth, run a live, supervised pilot on a non-critical service before any wider rollout. None of this requires re-architecting what we've already built and tested.
""")
    return s


def slide_closing(prs):
    s = D.add_slide(prs, D.NAVY)
    rect(s, 0, 0, SW, 0.16, fill=D.ORANGE)
    wso2_mark(s, M, 0.55, color=D.WHITE, size=22)
    tb, tf = textbox(s, M, 2.9, CW, 1.4)
    para(tf, "Thank you.", first=True, size=44, color=D.WHITE, bold=True, after=8)
    para(tf, "Happy to go deeper on any part of this — architecture, results, or rollout planning.",
         size=16, color=D.NAVY_TXT, spacing=1.2)
    rect(s, M, 5.1, 3.0, 0.05, fill=D.ORANGE)
    tb, tf = textbox(s, M, 5.35, CW, 0.5, anchor=MSO_ANCHOR.MIDDLE)
    para(tf, [("Scott Bechtel", {"bold": True, "color": D.WHITE}),
              ("   ·   WSO2 Forward Deployed Engineering", {"color": D.NAVY_TXT})], first=True, size=13)
    notes(s, """
Close it out and open the floor. Offer to go deeper on any part — the technical architecture, the full measured results, or a concrete rollout plan — and note that a more detailed, engineering-level version of this deck exists if anyone wants to go further.
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

    add(slide_title, content=False)
    add(slide_execsummary)
    add(slide_problem)
    add(slide_whatwebuilt)
    add(slide_workflow)
    add(slide_tworoads, content=False)
    add(slide_sol1)
    add(slide_sol2)
    add(slide_results)
    add(slide_governance)
    add(slide_flexibility)
    add(slide_demo)
    add(slide_recommendation)
    add(slide_nextsteps)
    add(slide_closing, content=False)

    total = pg["n"]
    for s, p in foot:
        footer(s, p, total, tag="DevOps OverSight Agent  ·  Executive Overview")

    out = "/Users/scottbechtel/dev/clients/f/fidelity/demo/DevOpsAgent/presentation/DevOps-OverSight-Agent-Executive-Overview.pptx"
    prs.save(out)
    print(f"saved {out}  ({len(prs.slides._sldIdLst)} slides)")
    issues = D.qa_report(prs)
    real = [i for i in issues if not (i[6].strip().isdigit() and len(i[6].strip()) <= 2)]
    print(f"QA off-slide shapes: {len(issues)} (real: {len(real)})")
    for i in real:
        print("  ", i)
    return out


if __name__ == "__main__":
    main()
