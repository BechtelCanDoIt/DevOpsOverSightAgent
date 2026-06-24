Count completed (`- [x]`) vs total (`- [`) checklist items in each phase spec file under `todo/`, then print the results as a copy-paste-ready ASCII table. Do not explain anything — output the table and nothing else.

Steps:
1. Run this shell command and capture the output:
```
for f in todo/phase-{0,1,2,3,4,5}-*.md; do
  done=$(python3 -c "import re; t=open('$f').read(); print(len(re.findall(r'- \[[xX]\]', t)))")
  total=$(python3 -c "import re; t=open('$f').read(); print(len(re.findall(r'- \[', t)))")
  echo "$done/$total"
done
```

2. Map the six `done/total` lines to phases in order: 0, 1, 2, 3, 4, 5.

3. Render this exact table with the live numbers filled in (replace the placeholders):

```
┌───────┬────────────────────────────────────────────┬───────────┬───────┐
│ Phase │ Name                                       │ Completed │ Total │
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ 0     │ Prerequisites & decisions                  │ P0_DONE   │ P0_TOT│
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ 1     │ Docker Compose observability stack         │ P1_DONE   │ P1_TOT│
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ 2     │ Ballerina service mesh + traffic generator │ P2_DONE   │ P2_TOT│
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ 3     │ Ballerina MCP server                       │ P3_DONE   │ P3_TOT│
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ 4     │ Ballerina agent + mock MCPs                │ P4_DONE   │ P4_TOT│
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ 5     │ Demo rehearsal & verification              │ P5_DONE   │ P5_TOT│
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ Total │                                            │ TOT_DONE  │TOT_TOT│
└───────┴────────────────────────────────────────────┴───────────┴───────┘
```

Right-align the Completed and Total numbers within their columns. Compute TOT_DONE and TOT_TOT by summing the six phases. Output the table inside a code block so it copies cleanly.
