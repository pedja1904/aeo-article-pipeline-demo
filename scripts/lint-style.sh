#!/usr/bin/env bash
# =============================================================================
#  lint-style.sh -- deterministic style check on an article draft
#
#  Greps for every banned term, em-dashes, semicolons and block paragraphs.
#  A model will not reliably hold a 150-item blacklist in its head for 2,000
#  words. grep will, every single time.
#
#  Usage:  bash scripts/lint-style.sh work/<slug>/draft-v1.md
#  Exit:   0 = clean
#          1 = violations found (printed with line numbers)
#          2 = bad usage
# =============================================================================
set -uo pipefail

DRAFT="${1:-}"
if [ -z "$DRAFT" ] || [ ! -f "$DRAFT" ]; then
  echo "Usage: bash scripts/lint-style.sh <path-to-draft.md>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERMS="$ROOT/shared/banned-terms.txt"
[ -f "$TERMS" ] || { echo "ERROR: $TERMS not found" >&2; exit 2; }

HITS=0

echo "=== BANNED TERMS ==="
while IFS= read -r term; do
  case "$term" in \#*|"") continue ;; esac
  # strip trailing whitespace
  term="$(echo "$term" | sed 's/[[:space:]]*$//')"
  [ -z "$term" ] && continue
  # word-boundary, case-insensitive
  MATCHES="$(grep -n -i -E "(^|[^[:alnum:]])$(echo "$term" | sed 's/[][\.*^$/]/\\&/g')([^[:alnum:]]|$)" "$DRAFT" || true)"
  if [ -n "$MATCHES" ]; then
    while IFS= read -r line; do
      echo "  [$term] line ${line%%:*}"
      HITS=$((HITS+1))
    done <<< "$MATCHES"
  fi
done < "$TERMS"
[ "$HITS" -eq 0 ] && echo "  none"

echo ""
echo "=== PUNCTUATION ==="

EM="$(grep -n -- '—' "$DRAFT" 2>/dev/null || true)"
EN="$(grep -n -- '–' "$DRAFT" 2>/dev/null || true)"
SEMI="$(grep -n ';' "$DRAFT" 2>/dev/null | grep -v '&[a-z]*;' || true)"

PUNCT_TOTAL=0
for pair in "em-dash|$EM" "en-dash|$EN" "semicolon|$SEMI"; do
  label="${pair%%|*}"
  body="${pair#*|}"
  [ -z "$body" ] && continue
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    echo "  [$label] line ${l%%:*}"
    PUNCT_TOTAL=$((PUNCT_TOTAL+1))
  done <<< "$body"
done
[ "$PUNCT_TOTAL" -eq 0 ] && echo "  none"

echo ""
echo "=== BLOCK PARAGRAPHS (3+ sentences on one line) ==="
BLOCKS="$(awk '
  BEGIN { fm=0; insources=0; infaq=0 }
  {
    orig=$0
    # skip YAML frontmatter entirely
    if (orig ~ /^---[[:space:]]*$/ && fm<2) { fm++; next }
    if (fm<2) next

    # once we hit Sources, stop checking - it is a reference list
    if (orig ~ /^##[[:space:]]*Sources/) { insources=1 }
    if (insources==1) next

    # FAQ answers are 40-60 word self-contained blocks BY DESIGN.
    # The house style requires multiple declarative sentences there.
    if (orig ~ /^##[[:space:]]*Frequently asked questions/) { infaq=1; next }
    if (infaq==1 && orig ~ /^##[[:space:]]/) { infaq=0 }
    if (infaq==1) next

    # skip structures that are legitimately long single lines
    if (orig ~ /^[[:space:]]*#/)              next   # headings
    if (orig ~ /^[[:space:]]*\|/)             next   # table rows
    if (orig ~ /^[[:space:]]*```/)            next   # code fences
    if (orig ~ /^[[:space:]]*>/)              next   # blockquotes
    if (orig ~ /^[[:space:]]*[-*][[:space:]]/) next  # bullet items
    if (orig ~ /^[[:space:]]*[0-9]+[.)][[:space:]]/) next  # numbered items
    if (orig ~ /^\*\*Quick Answer:\*\*/)      next   # Quick Answer is a block by design
    if (orig ~ /^\[VISUAL:/)                  next   # visual markers
    if (orig ~ /^[[:space:]]*"/)              next   # attributed quotations

    s=$0
    gsub(/[0-9]\.[0-9]/, "00", s)
    gsub(/e\.g\./, "eg", s)
    gsub(/i\.e\./, "ie", s)
    gsub(/vs\./,   "vs", s)
    gsub(/U\.S\./, "US", s)
    t=s
    gsub(/[^.!?]/, "", t)
    if (length(t) >= 3 && length(s) > 120) { print NR": "substr(orig,1,70)"..." }
  }' "$DRAFT" || true)"
if [ -n "$BLOCKS" ]; then
  echo "$BLOCKS" | sed 's/^/  line /'
  BLOCK_N="$(echo "$BLOCKS" | wc -l)"
else
  echo "  none"
  BLOCK_N=0
fi

echo ""
echo "=== UNATTRIBUTED QUOTES ==="
# The writer invented a blockquote to satisfy the VOICE quota. The linter
# skipped it, because the block-paragraph pass skips blockquotes and lines
# starting with a quote mark and calls them "attributed quotations" without
# ever checking for an attribution. A fabricated quote is an Automatic
# Critical and it must be caught before the evaluator sees the draft.
#
# Flags: a blockquote line containing a double quote, or a body line that is
# entirely a quoted sentence.
# Clears when: the [QUOTE -- CONFIRM WITH PJ] marker is on that line or the
# next non-empty line, or an attribution verb appears on that line or the
# next non-empty line.
QUOTES="$(awk '
  BEGIN { fm=0; insources=0 }
  {
    lines[NR]=$0
  }
  END {
    for (i=1; i<=NR; i++) {
      orig=lines[i]
      if (orig ~ /^---[[:space:]]*$/ && fm<2) { fm++; continue }
      if (fm<2) continue
      if (orig ~ /^##[[:space:]]*Sources/) insources=1
      if (insources==1) continue

      isquote=0
      if (orig ~ /^[[:space:]]*>.*"/) isquote=1
      if (isquote==0) continue

      ctx=orig
      j=i+1
      while (j<=NR && lines[j] ~ /^[[:space:]]*$/) j++
      if (j<=NR) ctx = ctx " " lines[j]

      if (ctx ~ /QUOTE[[:space:]]*--[[:space:]]*CONFIRM[[:space:]]*WITH[[:space:]]*PJ/) continue
      if (ctx ~ /(says|said|wrote|told|according to|argues|puts it)/) continue

      printf "  line %-4d unattributed quote: %s\n", i, substr(orig,1,60)
    }
  }' "$DRAFT" || true)"
if [ -n "$QUOTES" ]; then
  echo "$QUOTES"
  QUOTE_N="$(echo "$QUOTES" | wc -l)"
  echo "  A quote with no named source is an invented quote. Either name the"
  echo "  source, mark it [QUOTE -- CONFIRM WITH PJ], or drop the quote marks"
  echo "  and say it in the article's own voice."
else
  echo "  none"
  QUOTE_N=0
fi

echo ""
echo "=== SUMMARY ==="
TOTAL=$((HITS + PUNCT_TOTAL + BLOCK_N + QUOTE_N))
echo "  banned terms:     $HITS"
echo "  punctuation:      $PUNCT_TOTAL"
echo "  block paragraphs: $BLOCK_N"
echo "  unattrib. quotes: $QUOTE_N"
echo "  TOTAL:            $TOTAL"

if [ "$TOTAL" -gt 0 ]; then
  echo ""
  echo "FAIL. Fix every hit above before the draft goes to the evaluator."
  exit 1
fi

echo ""
echo "PASS. No style violations."
exit 0
