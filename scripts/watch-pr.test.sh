#!/usr/bin/env bash
# Checks watch-pr.sh's author trust classification (exact logins only).
set -uo pipefail
cd "$(dirname "$0")"
eval "$(sed -n '/^role()/,/^}/p' watch-pr.sh)"
fail=0
expect() { # expect <login> <body> <role>
  local got
  got=$(role "$1" "$2")
  if [ "$got" = "$3" ]; then echo "ok   $1 → $got"; else echo "FAIL $1 → $got (want $3)"; fail=1; fi
}
expect 'chatgpt-codex-connector[bot]' '' codex
expect 'chatgpt-codex-connector-attacker' '' untrusted
expect 'chatgpt-codex-connector' '' untrusted
expect 'github-actions[bot]' '' ci
expect 'github-actions' '' untrusted
expect chillingdaisy-worker1 '## neon review · `abc`' neon
expect chillingdaisy-worker1 '## neon art critique · `abc`' neon
expect chillingdaisy-worker1 '반영. ## neon art critique' agent
expect chillingdaisy-worker1 '@codex review — 대상 커밋' agent
expect chillingdaisy-worker1 '반영했습니다. ## neon review' agent
expect chillingdaisy-worker1x '## neon review' untrusted
expect mzlikesb '' user
expect someone-else '## neon review' untrusted

# codex-reviewed status watch: run the script against a fake gh. Each line of the steps
# file is one poll ("<head sha> <status> [context]"); after the last line the PR reads as MERGED.
# The fake answers a status read only when the script asks for that line's context
# (default codex-reviewed). FAKE_BASE is the PR's base branch (default main).
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
n=$(cat "$FAKE/n" 2>/dev/null || echo 0)
case "$*" in
  "repo view"*) echo o/r ;;
  *"--json state"*)
    n=$((n + 1)); echo "$n" >"$FAKE/n"
    if [ "$n" -gt "$(wc -l <"$FAKE/steps")" ]; then echo MERGED; else echo OPEN; fi ;;
  *headRefOid*) sed -n "${n}p" "$FAKE/steps" | cut -d' ' -f1 ;;
  *baseRefName*) echo "${FAKE_BASE:-main}" ;;
  *"/status"*)
    st=$(sed -n "${n}p" "$FAKE/steps" | cut -d' ' -f2)
    ctx=$(sed -n "${n}p" "$FAKE/steps" | cut -d' ' -f3); ctx=${ctx:-codex-reviewed}
    case "$*" in *"\"$ctx\""*) [ -n "$st" ] && [ "$st" != none ] && echo "$st" ;; esac ;;
esac
GH
chmod +x "$tmp/bin/gh"
watch() { # watch <name> <want-count-of-codex-lines> <steps...>
  local name=$1 want=$2 out got; shift 2
  export FAKE="$tmp/$name"; mkdir -p "$FAKE"; rm -f "$FAKE/n"
  printf '%s\n' "$@" >"$FAKE/steps"
  out=$(PATH="$tmp/bin:$PATH" bash ./watch-pr.sh 7 0 2>&1)
  got=$(grep -cE '\[codex\] head .* 리뷰 완료\(codex-reviewed(-dev)? success\)' <<<"$out")
  if [ "$got" = "$want" ]; then echo "ok   watch $name ($got)"; else echo "FAIL watch $name: $got lines (want $want)"; echo "$out"; fail=1; fi
  WATCH_OUT=$out
}
watch immediate 1 'aaaaaaa1111 success'
grep -q 'head aaaaaaa 리뷰 완료' <<<"$WATCH_OUT" || { echo "FAIL short sha"; fail=1; }
watch pending 1 'aaaaaaa1111 pending' 'aaaaaaa1111 pending' 'aaaaaaa1111 success'
watch dedupe 1 'aaaaaaa1111 success' 'aaaaaaa1111 success' 'aaaaaaa1111 success'
watch newsha 2 'aaaaaaa1111 success' 'bbbbbbb2222 pending' 'bbbbbbb2222 success' 'bbbbbbb2222 success'
watch never 0 'aaaaaaa1111 pending' 'aaaaaaa1111 none'
# base dev: only codex-reviewed-dev counts; base main ignores it.
FAKE_BASE=dev watch dev-context 1 'aaaaaaa1111 success codex-reviewed-dev'
grep -q '리뷰 완료(codex-reviewed-dev success)' <<<"$WATCH_OUT" || { echo "FAIL dev context name"; fail=1; }
FAKE_BASE=dev watch dev-ignores-main-context 0 'aaaaaaa1111 success codex-reviewed'
watch main-ignores-dev-context 0 'aaaaaaa1111 success codex-reviewed-dev'
exit $fail
