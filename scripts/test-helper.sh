#!/usr/bin/env bash
# Safe self-test: --dry-run never posts a keyboard event and never sleeps, so
# nothing is typed into any application and the suite finishes instantly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/assets/type-keystrokes-helper"

if [[ ! -x "$HELPER" ]]; then
  echo "Helper missing. Run: npm run build:helper" >&2
  exit 1
fi

run() {
  local text="$1"
  shift
  printf '%s' "$text" | "$HELPER" --dry-run "$@"
}
dry_line() { printf '%s\n' "$1" | sed -n '1p'; }
trace_line() { printf '%s\n' "$1" | sed -n '2p'; }
count_marker() { printf '%s\n' "$1" | grep -oF "$2" | wc -l | tr -d ' '; }

expect() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL  $label" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
  echo "PASS  $label"
}
contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL  $label (missing '$needle')" >&2
    echo "  trace: $haystack" >&2
    exit 1
  fi
  echo "PASS  $label"
}
absent() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "FAIL  $label (unexpected '$needle')" >&2
    echo "  trace: $haystack" >&2
    exit 1
  fi
  echo "PASS  $label"
}

echo "--- classic engine (regressions) ---"
CLASSIC1="$(run '测试中文 Abc 😀')"
expect "CJK + ASCII + emoji" 'DRYRUN:测试中文 Abc 😀' "$(dry_line "$CLASSIC1")"
absent "classic has no human markers" '[PAUSE' "$CLASSIC1"
absent "classic has no breath pauses" '[PHRASE_PAUSE' "$CLASSIC1"
expect "CRLF collapses to one Return" 'DRYRUN:第一行\n第二行' "$(dry_line "$(run $'第一行\r\n第二行')")"
expect "tab preserved" $'DRYRUN:a\tb' "$(dry_line "$(run $'a\tb')")"
CLEAR="$(run 'abc' --clear --return)"
expect "clear + return final buffer" 'DRYRUN:abc\n' "$(dry_line "$CLEAR")"
contains "clear + return trace" '[SELECT_ALL+DELETE][RETURN]' "$(trace_line "$CLEAR")"
expect "trailing newline avoids double Return" 'DRYRUN:abc\n' "$(dry_line "$(run $'abc\n' --return)")"
expect "physical key-code mode" 'DRYRUN:ABC abc !@#' "$(dry_line "$(run 'ABC abc !@#' --physical)")"

echo "--- human engine (new defaults: 75-100 WPM, 0.5-3s, breath pauses) ---"
SAMPLE='The internationalization effort was unexpectedly complicated, but overall the documentation remained remarkably comprehensive. Every configuration parameter deserves careful consideration before deployment. Nevertheless the implementation stayed readable and the tests passed consistently.'
HUMAN="$(run "$SAMPLE" --human --seed 7)"
expect "typo corrected: final text equals input" "DRYRUN:$SAMPLE" "$(dry_line "$HUMAN")"
TRACE="$(trace_line "$HUMAN")"
contains "WPM drift enabled" '[WPM ' "$TRACE"
contains "long-word hesitation" '[PAUSE ' "$TRACE"
contains "breath pause every 10-20 words" '[PHRASE_PAUSE 1000ms]' "$TRACE"
contains "QWERTY typo" '[TYPO ' "$TRACE"
contains "whole-word backspace" '[BACKSPACE×' "$TRACE"
contains "word retyped" '[RETYPE ' "$TRACE"

# awk needs an explicit numeric conversion: gsub() produces a string, and a
# string comparison against a number would be lexicographic.
WPM_BAD="$(printf '%s\n' "$TRACE" | grep -oE '\[WPM [0-9]+\]' | awk '{n = $2 + 0; if (n < 75 || n > 100) print $0}' || true)"
expect "default WPM within [75,100]" '' "$WPM_BAD"
PAUSE_BAD="$(printf '%s\n' "$TRACE" | grep -oE '\[PAUSE [0-9]+ms\]' | awk '{n = $2 + 0; if (n < 500 || n > 3000) print $0}' || true)"
expect "default hesitation within 500..3000ms" '' "$PAUSE_BAD"
PHRASE_BAD="$(printf '%s\n' "$TRACE" | grep -oE '\[PHRASE_PAUSE [0-9]+ms\]' | awk '{n = $2 + 0; if (n != 1000) print $0}' || true)"
expect "default breath pause is exactly 1000ms" '' "$PHRASE_BAD"

expect "same seed is reproducible" "$HUMAN" "$(run "$SAMPLE" --human --seed 7)"
absent "pause-chance 0 disables long-word hesitation" '[PAUSE' "$(run "$SAMPLE" --human --seed 7 --pause-chance 0 --typo-chance 0)"
absent "typo-chance 0 disables retyping" '[RETYPE' "$(run "$SAMPLE" --human --seed 7 --pause-chance 0 --typo-chance 0)"
absent "short words never trigger long-word hesitation" '[PAUSE ' "$(run 'short words only here' --human --seed 3)"
expect "Chinese input in human mode stays intact" 'DRYRUN:这是一段中文测试文本😀' "$(dry_line "$(run '这是一段中文测试文本😀' --human --seed 9)")"

echo "--- parameter plumbing ---"
THIRTY="$(printf 'alpha %.0s' {1..30})"
BOUNDARY="$(run "$THIRTY" --human --seed 5 --phrase-min 10 --phrase-max 10 --pause-chance 0 --typo-chance 0)"
expect "30 words / interval 10 => 3 breath pauses" '3' "$(count_marker "$BOUNDARY" '[PHRASE_PAUSE 1000ms]')"
absent "no long-word hesitations in short words" '[PAUSE ' "$BOUNDARY"
FIXED="$(run "$SAMPLE" --human --seed 11 --wpm-min 40 --wpm-max 40)"
contains "WPM override honoured" '[WPM 40]' "$(trace_line "$FIXED")"
absent "WPM override has no other speeds" '[WPM 41]' "$(trace_line "$FIXED")"
contains "breath pause duration override" '[PHRASE_PAUSE 2500ms]' "$(trace_line "$(run "$THIRTY" --human --seed 5 --phrase-min 10 --phrase-max 10 --phrase-pause 2500 --pause-chance 0 --typo-chance 0)")"
contains "hesitation duration override" '[PAUSE 200ms]' "$(trace_line "$(run "$SAMPLE" --human --seed 7 --pause-min 200 --pause-max 200)")"

echo "--- Esc abort ---"
expect "Esc aborts human engine" 'INTERRUPTED' "$(run 'abc def' --human --simulate-escape)"
expect "Esc aborts classic engine" 'INTERRUPTED' "$(run 'abc' --simulate-escape)"
expect "Esc aborts before clearing" 'INTERRUPTED' "$(run 'abc' --human --clear --simulate-escape)"
expect "no Esc => normal output" 'DRYRUN:abc' "$(dry_line "$(run 'abc' --human --seed 2)")"

echo "All helper self-tests passed."
