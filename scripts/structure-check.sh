#!/usr/bin/env bash
# =============================================================================
#  structure-check.sh -- deterministic AEO structure check on an article draft
#
#  Counts what a language model cannot count reliably: logic chunk lengths,
#  Answer Card bullet counts, question-heading ratio, FAQ answer lengths,
#  visual marker spacing, table and list presence.
#
#  Written after two evaluations of the same draft disagreed. One reported
#  Answer Cards of 3,4,4,3,3,5,3 and passed the article. The other reported
#  two H2s with no Answer Card at all and failed it. awk does not disagree
#  with itself.
#
#  Usage:  bash scripts/structure-check.sh work/<slug>/draft-v1.md [standard|pillar]
#  Exit:   0 = every structural minimum met
#          1 = violations found (printed with line numbers)
#          2 = bad usage
# =============================================================================
set -uo pipefail

DRAFT="${1:-}"
MODE="${2:-standard}"

if [ -z "$DRAFT" ] || [ ! -f "$DRAFT" ]; then
  echo "Usage: bash scripts/structure-check.sh <path-to-draft.md> [standard|pillar]" >&2
  exit 2
fi

case "$MODE" in
  standard) MIN_TABLES=1 ;;
  pillar)   MIN_TABLES=2 ;;
  *) echo "ERROR: mode must be 'standard' or 'pillar', got '$MODE'" >&2; exit 2 ;;
esac

REPORT="$(awk -v MIN_TABLES="$MIN_TABLES" -v MODE="$MODE" '
# ---------------------------------------------------------------------------
# Section classification
# ---------------------------------------------------------------------------
function is_appendix(h) {
  return (h ~ /^##[[:space:]]*Sources/ ||
          h ~ /^##[[:space:]]*LLMS\.TXT/ ||
          h ~ /^##[[:space:]]*META BLOCK/)
}
function is_signature(h) {
  return (h ~ /^##[[:space:]]*Key Actionable Insights/ ||
          h ~ /^##[[:space:]]*A Single/ ||
          h ~ /^##[[:space:]]*Frequently asked questions/)
}
function words(s,   t, n) {
  t = s
  gsub(/[*_`#>]/, "", t)
  gsub(/\[VISUAL:[^]]*\]/, "", t)
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
  if (t == "") return 0
  n = split(t, arr, /[[:space:]]+/)
  return n
}
function flush_h2() {
  if (cur_h2 == "") return
  h2_count++
  h2_line[h2_count]   = cur_h2_line
  h2_title[h2_count]  = cur_h2
  h2_chunk[h2_count]  = chunk_words
  h2_bullets[h2_count]= bullet_n
  h2_sig[h2_count]    = cur_sig
}

BEGIN { fm=0; appendix=0; infaq=0; cur_h2=""; chunk_open=0 }

{
  orig = $0

  # --- YAML frontmatter: skip entirely -------------------------------------
  if (orig ~ /^---[[:space:]]*$/ && fm < 2) { fm++; next }
  if (fm < 2) next

  # --- Quick Answer ---------------------------------------------------------
  if (orig ~ /^\*\*Quick Answer:\*\*/) {
    qa_line = NR
    qa = orig
    sub(/^\*\*Quick Answer:\*\*[[:space:]]*/, "", qa)
    qa_words = words(qa)
    next
  }

  # --- Heading handling -----------------------------------------------------
  if (orig ~ /^#{1,6}[[:space:]]/) {
    # count heading level by leading hashes
    n = 0
    while (substr(orig, n+1, 1) == "#") n++
    level = n

    if (level == 2) {
      flush_h2()
      cur_h2 = orig; cur_h2_line = NR
      chunk_words = 0; bullet_n = 0; chunk_open = 1
      cur_sig = (is_signature(orig) ? 1 : 0)

      if (is_appendix(orig)) { appendix = 1; cur_h2 = ""; chunk_open = 0 }
      else appendix = 0

      if (orig ~ /^##[[:space:]]*Frequently asked questions/) infaq = 1
      else infaq = 0
    }

    if (appendix == 1) next

    # question-heading ratio counts H2 and H3 in the body
    if (level == 2 || level == 3) {
      head_total++
      if (orig ~ /\?[[:space:]]*$/) head_q++
      # hierarchy: flag a skipped level
      if (last_level > 0 && level > last_level + 1)
        hier[++hier_n] = NR ": jumps H" last_level " -> H" level
      last_level = level
    }

    # FAQ question headings
    if (infaq == 1 && level == 3) {
      faq_n++
      faq_line[faq_n] = NR
      faq_words[faq_n] = 0
      faq_open = 1
    }
    next
  }

  if (appendix == 1) next

  # --- FAQ answer accumulation ---------------------------------------------
  if (infaq == 1 && faq_open == 1 && faq_n > 0) {
    if (orig !~ /^[[:space:]]*$/) faq_words[faq_n] += words(orig)
  }

  # --- Structural element detection ----------------------------------------
  is_bullet  = (orig ~ /^[[:space:]]*[-*][[:space:]]/)
  is_number  = (orig ~ /^[[:space:]]*[0-9]+[.)][[:space:]]/)
  is_table   = (orig ~ /^[[:space:]]*\|/)
  is_visual  = (orig ~ /^\[VISUAL:/)
  is_blank   = (orig ~ /^[[:space:]]*$/)

  if (is_bullet) { bulleted_present = 1; if (cur_h2 != "") bullet_n++ }
  if (is_number) numbered_present = 1
  if (is_table && orig !~ /^[[:space:]]*\|[[:space:]]*-/) {
    if (in_table == 0) { table_n++; in_table = 1 }
  } else if (!is_table) in_table = 0

  if (is_visual) { visual_n++; visual_at[visual_n] = body_words }

  # --- Logic chunk: prose immediately after an H2 ---------------------------
  if (chunk_open == 1) {
    if (is_bullet || is_number || is_table || is_visual) chunk_open = 0
    else if (!is_blank) chunk_words += words(orig)
  }

  if (!is_blank) body_words += words(orig)
}

END {
  flush_h2()

  fails = 0

  # ---- QUICK ANSWER --------------------------------------------------------
  print "=== QUICK ANSWER ==="
  if (qa_line == 0) {
    print "  MISSING. No **Quick Answer:** line found."
    fails++
  } else {
    printf "  line %d: %d words", qa_line, qa_words
    if (qa_words < 50 || qa_words > 80) { printf "   FAIL (band 50-80)\n"; fails++ }
    else printf "   ok\n"
  }

  # ---- HEADINGS ------------------------------------------------------------
  print ""
  print "=== HEADINGS ==="
  if (head_total == 0) { print "  no body headings found"; fails++ }
  else {
    ratio = (head_q * 100) / head_total
    printf "  question headings: %d of %d (%.0f%%)", head_q, head_total, ratio
    if (ratio < 60) { printf "   FAIL (minimum 60%%)\n"; fails++ }
    else printf "   ok\n"
  }
  if (hier_n > 0) {
    for (i = 1; i <= hier_n; i++) { print "  hierarchy: line " hier[i] "   FAIL"; fails++ }
  } else print "  hierarchy: sequential, no skipped levels   ok"

  # ---- LOGIC CHUNKS --------------------------------------------------------
  print ""
  print "=== LOGIC CHUNKS (134-167 words, content H2s only) ==="
  chunks_checked = 0
  for (i = 1; i <= h2_count; i++) {
    if (h2_sig[i] == 1) continue
    chunks_checked++
    t = h2_title[i]; sub(/^##[[:space:]]*/, "", t)
    if (length(t) > 52) t = substr(t, 1, 52) "..."
    printf "  line %-4d %-56s %3d w", h2_line[i], t, h2_chunk[i]
    if (h2_chunk[i] < 134 || h2_chunk[i] > 167) { printf "   FAIL\n"; fails++ }
    else printf "   ok\n"
  }
  if (chunks_checked == 0) print "  no content H2s found"

  # ---- ANSWER CARDS --------------------------------------------------------
  print ""
  print "=== ANSWER CARDS (3-7 unlabelled bullets per content H2) ==="
  print "  NOTE: numbered lists are labelled and do NOT count as Answer Cards."
  for (i = 1; i <= h2_count; i++) {
    if (h2_sig[i] == 1) continue
    t = h2_title[i]; sub(/^##[[:space:]]*/, "", t)
    if (length(t) > 52) t = substr(t, 1, 52) "..."
    printf "  line %-4d %-56s %3d bullets", h2_line[i], t, h2_bullets[i]
    if (h2_bullets[i] < 3 || h2_bullets[i] > 7) { printf "   FAIL\n"; fails++ }
    else printf "   ok\n"
  }

  # ---- LISTS AND TABLES ----------------------------------------------------
  print ""
  print "=== LISTS AND TABLES ==="
  printf "  tables: %d", table_n
  if (table_n < MIN_TABLES) { printf "   FAIL (minimum %d for %s)\n", MIN_TABLES, MODE; fails++ }
  else printf "   ok (minimum %d for %s)\n", MIN_TABLES, MODE
  printf "  numbered list present: %s", (numbered_present ? "yes   ok" : "no    FAIL")
  print ""
  if (!numbered_present) fails++
  printf "  bulleted list present: %s", (bulleted_present ? "yes   ok" : "no    FAIL")
  print ""
  if (!bulleted_present) fails++

  # ---- FAQ -----------------------------------------------------------------
  print ""
  print "=== FAQ (4-6 questions, answers 40-60 words) ==="
  if (faq_n == 0) { print "  MISSING. No H3 question headings under the FAQ H2."; fails++ }
  else {
    printf "  questions: %d", faq_n
    if (faq_n < 4 || faq_n > 6) { printf "   FAIL (band 4-6)\n"; fails++ }
    else printf "   ok\n"
    for (i = 1; i <= faq_n; i++) {
      printf "  line %-4d answer %d: %3d words", faq_line[i], i, faq_words[i]
      if (faq_words[i] < 40 || faq_words[i] > 60) { printf "   FAIL (band 40-60)\n"; fails++ }
      else printf "   ok\n"
    }
  }

  # ---- VISUALS -------------------------------------------------------------
  print ""
  print "=== VISUALS ==="
  if (visual_n == 0) { print "  none found   FAIL"; fails++ }
  else {
    printf "  markers: %d across %d body words", visual_n, body_words
    spacing = body_words / visual_n
    printf "  (1 per %.0f words)", spacing
    if (spacing > 350) { printf "   FAIL (target 1 per 250, ceiling 350)\n"; fails++ }
    else printf "   ok\n"
  }

  # ---- SUMMARY -------------------------------------------------------------
  print ""
  print "=== SUMMARY ==="
  printf "  body words:       %d\n", body_words
  printf "  content H2s:      %d\n", chunks_checked
  printf "  FAILCOUNT:        %d\n", fails
  print "FAILCOUNT_MACHINE=" fails
}
' "$DRAFT")"

if [ -z "$REPORT" ]; then
  echo "ERROR: structure-check.sh produced no output. See any awk error above." >&2
  exit 2
fi

FAILS="$(echo "$REPORT" | grep '^FAILCOUNT_MACHINE=' | cut -d= -f2)"
echo "$REPORT" | grep -v '^FAILCOUNT_MACHINE='

# ---- SOURCES SECTION URLS --------------------------------------------------
# Every bullet in the article's OWN "## Sources" section must carry a URL.
# sources.json is checked by verify_sources.sh and source-depth.sh. Neither
# reads the draft. A run shipped 8 sources into the article with every URL
# stripped and all three source gates passed, because all three were reading
# the working file instead of the delivered artifact.
# A URL on an indented continuation line under a bullet counts.
SRCREPORT="$(awk '
  BEGIN { insrc=0; n=0 }
  {
    if ($0 ~ /^##[[:space:]]*Sources/) { insrc=1; next }
    if (insrc==1 && $0 ~ /^##[[:space:]]/) { insrc=0 }
    if (insrc==1 && $0 ~ /^---[[:space:]]*$/) { insrc=0 }
    if (insrc==1) {
      if ($0 ~ /^[-*][[:space:]]/) {
        n++; line[n]=NR; txt[n]=substr($0,1,60)
        has[n] = ($0 ~ /https?:\/\//) ? 1 : 0
      } else if (n>0 && $0 ~ /https?:\/\//) {
        has[n]=1
      }
    }
  }
  END {
    print ""
    print "=== SOURCES SECTION URLS ==="
    if (n==0) {
      print "  no source bullets found in the draft   FAIL"
      print "SRCFAIL_MACHINE=1"
      exit
    }
    f=0
    for (i=1;i<=n;i++) {
      if (has[i]==0) { printf "  line %-4d no URL: %s\n", line[i], txt[i]; f++ }
    }
    printf "  source bullets:   %d\n", n
    printf "  missing URLs:     %d", f
    if (f>0) printf "   FAIL\n"; else printf "   ok\n"
    print "SRCFAIL_MACHINE=" f
  }
' "$DRAFT")"

SRCFAILS="$(echo "$SRCREPORT" | grep '^SRCFAIL_MACHINE=' | cut -d= -f2)"
echo "$SRCREPORT" | grep -v '^SRCFAIL_MACHINE='
FAILS=$(( ${FAILS:-0} + ${SRCFAILS:-0} ))
echo ""
echo "  TOTAL FAILCOUNT (structure + sources): $FAILS"

if [ "${FAILS:-1}" -gt 0 ]; then
  echo ""
  echo "FAIL. $FAILS structural minimum(s) not met. Fix before the draft goes to the evaluator."
  exit 1
fi

echo ""
echo "PASS. All structural minimums met."
exit 0
