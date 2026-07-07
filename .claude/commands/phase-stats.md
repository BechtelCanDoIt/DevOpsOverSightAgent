Count completed (`- [x]`) vs total (`- [`) checklist items in each phase spec file under `todo/`, then print the results as a copy-paste-ready ASCII table. Phase names are pulled from the H1 heading of each `phase-N-*.md` file, so this works for any project (LangChain, Ballerina, TypeScript, etc.). Do not explain anything — output the table and nothing else.

Steps:
1. Run this shell command and capture the output. It prints one line per phase in the form `DONE|TOTAL|NAME` (NAME is the text after `Phase N — ` in the file's first heading, e.g. `4|8|Three Agents + A2A`):
```
for f in todo/phase-*.md; do
  name=$(head -1 "$f" | sed -E 's/^# *Phase *[0-9]+ *— *//')
  done=$(python3 -c "import re; t=open('$f').read(); print(len(re.findall(r'- \[[xX]\]', t)))")
  total=$(python3 -c "import re; t=open('$f').read(); print(len(re.findall(r'- \[', t)))")
  echo "$done|$total|$name"
done | sort -t'|' -k1,1n
```
(The `sort` keeps phases in numeric order based on the leading done-count is unreliable; instead, sort by the phase number parsed from the filename. If your shell glob returns them out of order, replace the trailing pipe with `| sort -t/ -k2.7,2.7n` to sort by the `phase-N-` token.)

If filenames are not zero-padded (e.g. `phase-10-...`), use this version which sorts by phase number correctly:
```
python3 - <<'PY'
import re, glob, os
rows = []
for f in sorted(glob.glob('todo/phase-*.md'), key=lambda p: int(re.search(r'phase-(\d+)', p).group(1))):
    t = open(f).read()
    done = len(re.findall(r'- \[[xX]\]', t))
    total = len(re.findall(r'- \[', t))
    name = re.sub(r'^# *Phase *\d+ *— *', '', open(f).readline().strip())
    rows.append((done, total, name))
for d, tot, n in rows:
    print(f"{d}|{tot}|{n}")
PY
```

2. Map each `DONE|TOTAL|NAME` line to the corresponding phase row in the table. The phase number itself comes from the line order (first line = Phase 0, second = Phase 1, etc.).

3. Render this table with the live numbers and names filled in (replace the placeholders; names come from step 1, NOT the placeholders below):

```
┌───────┬────────────────────────────────────────────┬───────────┬───────┐
│ Phase │ Name                                       │ Completed │ Total │
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ 0     │ P0_NAME                                    │     P0_DONE │ P0_TOT│
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ 1     │ P1_NAME                                    │     P1_DONE │ P1_TOT│
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ 2     │ P2_NAME                                    │     P2_DONE │ P2_TOT│
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ 3     │ P3_NAME                                    │     P3_DONE │ P3_TOT│
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ 4     │ P4_NAME                                    │     P4_DONE │ P4_TOT│
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ 5     │ P5_NAME                                    │     P5_DONE │ P5_TOT│
├───────┼────────────────────────────────────────────┼───────────┼───────┤
│ Total │                                            │   TOT_DONE │TOT_TOT│
└───────┴────────────────────────────────────────────┴───────────┴───────┘
```

Right-align the Completed and Total numbers within their columns. Compute TOT_DONE and TOT_TOT by summing the six phases. Truncate any name longer than 44 chars with a trailing `…` so it fits the column. Output the table inside a code block so it copies cleanly.
