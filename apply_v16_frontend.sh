#!/bin/bash
set -e
echo "🍄 Mycel v16 (frontend) — Stage 1 splitter UI: match badge · assumed pill · mentions stepper"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── locate PDFViewer.jsx ────────────────────────────────────────
TARGET=""
for c in frontend/src/PDFViewer.jsx frontend/PDFViewer.jsx src/PDFViewer.jsx PDFViewer.jsx; do
  [ -f "$c" ] && TARGET="$c" && break
done
[ -z "$TARGET" ] && TARGET="$(find . -name PDFViewer.jsx -not -path '*/node_modules/*' 2>/dev/null | head -1)"
[ -z "$TARGET" ] && { echo "  ✗ PDFViewer.jsx not found. Run from repo root."; exit 1; }
echo "  → target: $TARGET"

if grep -q "n.source_score" "$TARGET"; then
  echo "  • already patched (found n.source_score) — nothing to do."; exit 0
fi

cp "$TARGET" "$TARGET.v15bak"; echo "  ✓ backup: $TARGET.v15bak"

TARGET="$TARGET" python3 - << 'PYEOF'
import os, sys
p = os.environ["TARGET"]
src = open(p, encoding="utf-8").read()

# ── Edit 1: mentions-driven occurrences (fall back to text scan) ──
OLD1 = """    if (!node) return [];
    var label = normWS(node.label);"""
NEW1 = """    if (!node) return [];
    if (node.mentions && node.mentions.length) { var outM = []; node.mentions.forEach(function(m) { var pg = m.page, pt = pageText[pg], fy = 0; if (pt) { pageConcat(pt); var pb = normWS(m.quote || '').slice(0, 40); var ix = pb ? pt._concat.indexOf(pb) : -1; if (ix >= 0) { var it0 = pt.items[pt._map[ix]]; if (it0) fy = it0.fy; } } outM.push({ page: pg, fy: fy, score: (typeof m.score === 'number' ? m.score : null), quote: m.quote || '' }); }); if (outM.length) return outM; }
    var label = normWS(node.label);"""

# ── Edit 2: show match % in the ref k/N stepper ──
OLD2 = """            h('span', { style: { fontSize: 11, color: DIM, minWidth: 42, textAlign: 'center' } }, 'ref ' + (occIdx + 1) + '/' + occurrences.length),"""
NEW2 = """            h('span', { style: { fontSize: 11, color: DIM, minWidth: 42, textAlign: 'center' } }, 'ref ' + (occIdx + 1) + '/' + occurrences.length + ((occurrences[occIdx] && typeof occurrences[occIdx].score === 'number') ? ' \u00b7 ' + Math.round(occurrences[occIdx].score * 100) + '%' : '')),"""

# ── Edit 3: match-strength badge + "assumed" pill in the inspector header ──
OLD3 = """                  h('span', { style: { fontSize: 10, color: DIM, marginLeft: 'auto', textTransform: 'uppercase' } }, n.concept_type)"""
NEW3 = """                  (typeof n.source_score === 'number' && n.source_score > 0)
                    ? h('span', { title: 'Source-match strength ' + Math.round(n.source_score * 100) + '%', style: { fontSize: 9, fontWeight: 700, color: (n.source_score >= 0.6 ? '#2FBF71' : (n.source_score >= 0.45 ? '#E0A44A' : '#C46B6B')), border: '1px solid ' + (n.source_score >= 0.6 ? '#2FBF71' : (n.source_score >= 0.45 ? '#E0A44A' : '#C46B6B')) + '66', borderRadius: 6, padding: '1px 5px' } }, Math.round(n.source_score * 100) + '%')
                    : null,
                  (n.in_text === false)
                    ? h('span', { title: 'Not defined in this text - a prerequisite or inferred concept', style: { fontSize: 9, fontWeight: 700, color: DIM, border: '1px dashed ' + BRD, borderRadius: 6, padding: '1px 5px' } }, 'assumed')
                    : null,
                  h('span', { style: { fontSize: 10, color: DIM, marginLeft: 'auto', textTransform: 'uppercase' } }, n.concept_type)"""

for i, (o, n) in enumerate([(OLD1, NEW1), (OLD2, NEW2), (OLD3, NEW3)], 1):
    c = src.count(o)
    if c != 1:
        print(f"  \u2717 edit {i}: anchor matched {c} times (expected 1) — ABORT, no changes written")
        sys.exit(2)
    src = src.replace(o, n)

open(p, "w", encoding="utf-8").write(src)
print("  \u2713 3 edits applied")
PYEOF

# ── validity: brace/paren balance must be unchanged from backup ──
TARGET="$TARGET" python3 - << 'PYEOF'
import os
p = os.environ["TARGET"]
a = open(p, encoding="utf-8").read()
b = open(p + ".v15bak", encoding="utf-8").read()
def bal(s): return (s.count('(')-s.count(')'), s.count('{')-s.count('}'), s.count('[')-s.count(']'))
if bal(a) != bal(b):
    print("  \u2717 bracket balance changed vs backup — restoring")
    os.replace(p + ".v15bak", p); raise SystemExit(1)
print("  \u2713 bracket balance unchanged (added spans are self-closed)")
PYEOF

# optional: node syntax check if available (non-fatal; file is ESM/JSX-ish)
if command -v node >/dev/null 2>&1; then
  node --check "$TARGET" 2>/dev/null && echo "  ✓ node --check passed" || echo "  • node --check inconclusive (ESM/JSX) — relying on balance check"
fi

rm -f "$TARGET.v15bak"

cat <<'NOTE'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
v16 frontend applied to PDFViewer.jsx:

  1. Concept inspector now shows a colour-coded match-strength badge
     (green >=60%, amber >=45%, red <45%) from node.source_score.
  2. Concepts with in_text=false show a dashed "assumed" pill
     (prerequisite / not defined in this text).
  3. The "ref k/N" stepper is driven by node.mentions when present
     (all ranked source sentences) and shows the match % of the current one.
  All three degrade gracefully on older maps that lack these fields.

VERIFY (localhost):
  cd frontend && npm run dev   # Vite hot-reloads
  open a map -> split view -> select a concept:
    • a % badge appears next to the label
    • prerequisite concepts show "assumed"
    • the ref stepper (top-left of the PDF pane) shows e.g. "ref 1/3 · 82%"

ROLLBACK:  git checkout -- <path to PDFViewer.jsx>
DEPLOY:    git add -A && git commit -m "v16: Stage 1 splitter UI (match badge, assumed pill, mentions stepper)" && git push
           (Vercel rebuilds the frontend)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NOTE
echo "✓ done."