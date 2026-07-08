#!/bin/bash
# Render a pptx to per-slide PNGs for visual QA.
# Usage: ./render.sh <deck.pptx> <out_dir>
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SOFFICE=/Applications/LibreOffice.app/Contents/MacOS/soffice
PY="$HERE/pptx-venv/bin/python"
DECK="$1"
OUT="${2:-$HERE/render}"
mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT"/*.pdf 2>/dev/null || true
"$SOFFICE" --headless --convert-to pdf --outdir "$OUT" "$DECK" >/dev/null 2>&1
PDF="$OUT/$(basename "${DECK%.pptx}").pdf"
"$PY" - "$PDF" "$OUT" <<'PY'
import sys
import pypdfium2 as pdfium
pdf, out = sys.argv[1], sys.argv[2]
doc = pdfium.PdfDocument(pdf)
n = len(doc)
for i in range(n):
    img = doc[i].render(scale=1.4).to_pil()
    img.save(f"{out}/slide-{i+1:02d}.png")
print(f"rendered {n} pages -> {out}")
PY
echo "---done---"
