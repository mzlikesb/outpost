#!/usr/bin/env bash
# Checks pr-check.sh on fake PR and review JSON (no network). Plan 010 C, tasks R1·R1c.
set -uo pipefail
cd "$(dirname "$0")"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
HEAD=c9eb9795374a1b2c3d4e5f60718293a4b5c6d7e8
OLD=1111111222222233333334444444555555566666
BODY=$'## 요약\n\n- 등급: small\n- 관련 이슈: Refs #121\n'
NONE_BODY=$'- 관련 이슈: 없음\n'

pr() { # pr <base> <head-ref> <labels-csv> <milestone:yes|no> <auto:yes|no> [body]
  jq -n --arg base "$1" --arg ref "$2" --arg labels "$3" --arg m "$4" --arg a "$5" \
    --arg body "${6:-$BODY}" --arg sha "$HEAD" --arg hr "${HEAD_REPO:-mzlikesb/outpost}" '{
    base:{ref:$base, repo:{full_name:"mzlikesb/outpost"}}, head:{ref:$ref, sha:$sha, repo:{full_name:$hr}}, body:$body,
    labels:($labels | split(",") | map(select(. != "")) | map({name:.})),
    milestone:(if $m == "yes" then {title:"M5 출시"} else null end),
    auto_merge:(if $a == "yes" then {merge_method:"squash"} else null end)}'
}
rev() { jq -n --arg l "$1" --arg s "$2" --arg c "$3" --arg t "$4" '{user:{login:$l},state:$s,commit_id:$c,submitted_at:$t}'; }
APPROVE=$(rev mzlikesb APPROVED "$HEAD" 2026-11-28T10:00:00Z)

check() { # check <name> <want-exit> <flow> <pr> <reviews> [compare-status] [want-substring]
  echo "$4" >"$tmp/pr.json"; echo "$5" >"$tmp/rv.json"
  local out code
  out=$(bash pr-check.sh "$tmp/pr.json" "$tmp/rv.json" "$3" "${6:-}" 2>&1); code=$?
  if [ "$code" = "$2" ] && { [ -z "${7:-}" ] || grep -q -- "$7" <<<"$out"; }; then echo "ok   $1"
  else echo "FAIL $1 (exit $code, want $2; out: $out)"; fail=1; fi
}

# DEV_FLOW off (or unset): today's rules, any base.
check "off: small to main" 0 "" "$(pr main chore/x size:small,stage:dev yes no)" '[]'
check "off: large to main (this PR, 010-1)" 0 "" "$(pr main chore/010-1 size:large,stage:dev yes no)" '[]'
check "off: value other than on is off" 0 "off" "$(pr main chore/x size:small,stage:dev yes yes)" '[]'
check "off: small with auto-merge" 0 "" "$(pr main chore/x size:small,stage:dev yes yes)" '[]'
check "off: large with auto-merge" 1 "" "$(pr main chore/x size:large,stage:dev yes yes)" '[]' "" "auto-merge"
check "off: no 관련 이슈 line" 1 "" "$(pr main chore/x size:small,stage:dev yes no $'no line')" '[]' "" "관련 이슈"
check "off: bad 관련 이슈 value" 1 "" "$(pr main chore/x size:small,stage:dev yes no $'- 관련 이슈: 나중에')" '[]' "" "관련 이슈"
check "off: 관련 이슈 없음" 0 "" "$(pr main chore/x size:small,stage:dev yes no "$NONE_BODY")" '[]'
check "off: two size labels" 1 "" "$(pr main chore/x size:small,size:large,stage:dev yes no)" '[]' "" "size:"
check "off: no stage label" 1 "" "$(pr main chore/x size:small yes no)" '[]' "" "stage:"
check "off: no milestone" 1 "" "$(pr main chore/x size:small,stage:dev no no)" '[]' "" "마일스톤"
check "off: release PR is held to today's rules" 1 "" "$(pr main release/20261201-1 release yes no)" '[]' "behind"

# DEV_FLOW on, base dev.
check "on/dev: small" 0 on "$(pr dev chore/x size:small,stage:code-review yes no)" '[]'
check "on/dev: small with auto-merge" 0 on "$(pr dev chore/x size:small,stage:code-review yes yes)" '[]'
check "on/dev: small needs no Approve" 0 on "$(pr dev chore/x size:small,stage:code-review yes no)" "[$(rev mzlikesb CHANGES_REQUESTED "$HEAD" 2026-11-28T10:00:00Z)]"
check "on/dev: no milestone" 1 on "$(pr dev chore/x size:small,stage:code-review no no)" '[]' "" "마일스톤"
check "on/dev: no size label" 1 on "$(pr dev chore/x stage:code-review yes no)" '[]' "" "size:"
check "on/dev: large without Approve" 1 on "$(pr dev feat/x size:large,stage:code-review yes no)" '[]' "" "Approve"
check "on/dev: large with head Approve" 0 on "$(pr dev feat/x size:large,stage:code-review yes no)" "[$APPROVE]"
check "on/dev: large, Approve on an older commit" 1 on "$(pr dev feat/x size:large,stage:code-review yes no)" "[$(rev mzlikesb APPROVED "$OLD" 2026-11-28T10:00:00Z)]" "" "Approve"
check "on/dev: large, Approve by someone else" 1 on "$(pr dev feat/x size:large,stage:code-review yes no)" "[$(rev chillingdaisy-worker1 APPROVED "$HEAD" 2026-11-28T10:00:00Z)]" "" "Approve"
check "on/dev: large, Approve then dismissed" 1 on "$(pr dev feat/x size:large,stage:code-review yes no)" "[$(rev mzlikesb DISMISSED "$HEAD" 2026-11-28T10:00:00Z)]" "" "Approve"
check "on/dev: large, Approve then changes requested" 1 on "$(pr dev feat/x size:large,stage:code-review yes no)" "[$APPROVE,$(rev mzlikesb CHANGES_REQUESTED "$HEAD" 2026-11-28T11:00:00Z)]" "" "Approve"
check "on/dev: large, Approve then a plain comment" 0 on "$(pr dev feat/x size:large,stage:code-review yes no)" "[$APPROVE,$(rev mzlikesb COMMENTED "$HEAD" 2026-11-28T11:00:00Z)]"
check "on/dev: large with auto-merge (even approved)" 1 on "$(pr dev feat/x size:large,stage:code-review yes yes)" "[$APPROVE]" "" "auto-merge"

# DEV_FLOW on, base dev, head main: squash-recovery PR (tasks R1c).
check "on/dev: main -> dev recovery with release label" 0 on "$(pr dev main release yes no "$NONE_BODY")" '[]'
check "on/dev: main -> dev recovery with size/stage too" 1 on "$(pr dev main release,size:small,stage:dev yes no "$NONE_BODY")" '[]' "" "release"
check "on/dev: main -> dev recovery with auto-merge" 1 on "$(pr dev main release yes yes "$NONE_BODY")" '[]' "" "auto-merge"
check "on/dev: main -> dev recovery from a fork's main is not the exception" 1 on "$(HEAD_REPO=someone/outpost pr dev main release yes no "$NONE_BODY")" '[]' "" "size:"
check "on/dev: main -> dev recovery with no head repo is not the exception" 1 on "$(pr dev main release yes no "$NONE_BODY" | jq '.head.repo = null')" '[]' "" "size:"
check "on/dev: main -> dev recovery without milestone" 1 on "$(pr dev main release no no "$NONE_BODY")" '[]' "" "마일스톤"

# DEV_FLOW on, base main: only release snapshots.
check "on/main: release snapshot" 0 on "$(pr main release/20261201-1 release yes no "$NONE_BODY")" '[]' behind
check "on/main: release snapshot equal to dev" 0 on "$(pr main release/20261201-1 release yes no "$NONE_BODY")" '[]' identical
check "on/main: release with Refs line" 0 on "$(pr main release/20261201-1 release yes no)" '[]' behind
check "on/main: release not an ancestor of dev (ahead)" 1 on "$(pr main release/20261201-1 release yes no "$NONE_BODY")" '[]' ahead "dev"
check "on/main: release diverged from dev" 1 on "$(pr main release/20261201-1 release yes no "$NONE_BODY")" '[]' diverged "dev"
check "on/main: release, ancestry unknown" 1 on "$(pr main release/20261201-1 release yes no "$NONE_BODY")" '[]' "" "dev"
check "on/main: ordinary branch" 1 on "$(pr main chore/x size:small,stage:dev yes no)" '[]' "" "release/"
check "on/main: release without release label" 1 on "$(pr main release/20261201-1 size:large,stage:dev yes no)" '[]' behind "release"
check "on/main: release with size label too" 1 on "$(pr main release/20261201-1 release,size:large yes no "$NONE_BODY")" '[]' behind "size:"
check "on/main: release with stage label too" 1 on "$(pr main release/20261201-1 release,stage:dev yes no "$NONE_BODY")" '[]' behind "stage:"
check "on/main: release without milestone" 1 on "$(pr main release/20261201-1 release no no "$NONE_BODY")" '[]' behind "마일스톤"
check "on/main: release without 관련 이슈 line" 1 on "$(pr main release/20261201-1 release yes no 'x')" '[]' behind "관련 이슈"
check "on/main: release with auto-merge" 1 on "$(pr main release/20261201-1 release yes yes "$NONE_BODY")" '[]' behind "auto-merge"

# Other bases (stacked PRs) keep today's rules.
check "on/other base: small" 0 on "$(pr feat/base chore/x size:small,stage:dev yes no)" '[]'

exit "$fail"
