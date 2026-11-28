#!/usr/bin/env bash
# Checks codex-gate.sh on fake comments and reviews (no network).
set -uo pipefail
cd "$(dirname "$0")"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
HEAD=c9eb9795374a1b2c3d4e5f60718293a4b5c6d7e8
OLD=1111111222222233333334444444555555566666

user() { jq -n --arg l "$1" --arg b "$2" '{user:{login:$l},body:$b}'; }
receipt() { printf '<!-- codex-review-receipt:v1 -->\n\nCodex Review: ok.\n\n**Reviewed commit:** `%s`\n' "$1"; }
state() { printf '<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 {"code_review":{"commit_sha":"%s","has_any_findings":false,"status":"%s"},"security_review":{"commit_sha":null}} -->\n' "$1" "$2"; }
check() { # check <name> <want-state> <comments-array> <reviews-array>
  echo "$3" >"$tmp/c.json"; echo "$4" >"$tmp/r.json"
  local got
  got=$(bash codex-gate.sh "$HEAD" "$tmp/c.json" "$tmp/r.json" | jq -r .state)
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (got $got, want $2)"; fail=1; fi
}
BOT='chatgpt-codex-connector[bot]'

check "no comments" pending '[]' '[]'
check "receipt for an old commit only" pending "[$(user "$BOT" "$(receipt "${OLD:0:10}")")]" '[]'
check "receipt for head (10 chars)" success "[$(user "$BOT" "$(receipt "${HEAD:0:10}")")]" '[]'
check "old receipt then head receipt" success "[$(user "$BOT" "$(receipt "${OLD:0:10}")"),$(user "$BOT" "$(receipt "${HEAD:0:10}")")]" '[]'
check "receipt in a review body" success '[]' "[$(user "$BOT" "$(receipt "${HEAD:0:7}")")]"
check "same words from another author" pending "[$(user someone-else "$(receipt "${HEAD:0:10}")"),$(user mzlikesb "$(receipt "${HEAD:0:10}")")]" "[$(user chillingdaisy-worker1 "$(receipt "${HEAD:0:10}")")]"
check "lookalike bot name" pending "[$(user 'chatgpt-codex-connector[bot]x' "$(receipt "${HEAD:0:10}")")]" '[]'
check "state summary only (completed, full sha)" success "[$(user "$BOT" "$(state "$HEAD" completed)")]" '[]'
check "state summary in progress" pending "[$(user "$BOT" "$(state "$HEAD" in_progress)")]" '[]'
check "state summary for an old commit" pending "[$(user "$BOT" "$(state "$OLD" completed)")]" '[]'
check "state summary from another author" pending "[$(user someone-else "$(state "$HEAD" completed)")]" '[]'
check "short sha 6 chars" pending "[$(user "$BOT" "$(receipt "${HEAD:0:6}")")]" '[]'
check "marker without commit line" pending "[$(user "$BOT" '<!-- codex-review-receipt:v1 -->')]" '[]'
check "commit line without marker" pending "[$(user "$BOT" "**Reviewed commit:** \`${HEAD:0:10}\`")]" '[]'
check "review with findings still counts" success '[]' "[$(user "$BOT" "$(receipt "${HEAD:0:10}")

P1 something is wrong")]"
check "null bodies" pending '[{"user":{"login":"x"},"body":null}]' '[{"user":{"login":"x"},"body":null}]'

# Description names the head or the reviewed commit.
echo '[]' >"$tmp/c.json"; echo '[]' >"$tmp/r.json"
d=$(cd "$tmp" && bash "$OLDPWD/codex-gate.sh" "$HEAD" c.json r.json | jq -r .description)
case "$d" in *c9eb979*"@codex review"*) echo "ok   pending description";; *) echo "FAIL description: $d"; fail=1;; esac
# --- base dev (plan 010 B2 / tasks R2) -------------------------------------------
# codex-gate.sh <head> <comments> <reviews> <base> <review-comments>
CLEAN_RECEIPT() { printf "<!-- codex-review-receipt:v1 -->\n\nCodex Review: Didn't find any major issues. Nice work!\n\n**Reviewed commit:** \`%s\`\n" "$1"; }
FIND_RECEIPT() { printf '<!-- codex-review-receipt:v1 -->\n\n### 💡 Codex Review\n\nHere are some automated review suggestions for this pull request.\n\n**Reviewed commit:** `%s`\n' "$1"; }
cmt() { jq -n --arg l "$1" --arg b "$2" --arg t "$3" '{user:{login:$l},body:$b,created_at:$t}'; }
rev() { # rev <id> <login> <state> <commit> <time> <body>
  jq -n --argjson id "$1" --arg l "$2" --arg s "$3" --arg c "$4" --arg t "$5" --arg b "$6" \
    '{id:$id,user:{login:$l},state:$s,commit_id:$c,submitted_at:$t,body:$b}'
}
inline() { jq -n --argjson r "$1" --arg c "$2" '{pull_request_review_id:$r,commit_id:$c,user:{login:"chatgpt-codex-connector[bot]"},body:"P1 something"}'; }
dcheck() { # dcheck <name> <want-state> <base> <comments> <reviews> <review-comments>
  echo "$4" >"$tmp/c.json"; echo "$5" >"$tmp/r.json"; echo "$6" >"$tmp/rc.json"
  local got
  got=$(bash codex-gate.sh "$HEAD" "$tmp/c.json" "$tmp/r.json" "$3" "$tmp/rc.json" | jq -r .state)
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (got $got, want $2)"; fail=1; fi
}
T1=2026-11-28T09:00:00Z T2=2026-11-28T09:10:00Z T3=2026-11-28T09:20:00Z
CLEAN_C=$(cmt "$BOT" "$(CLEAN_RECEIPT "${HEAD:0:10}")" "$T2")
FIND_R=$(rev 11 "$BOT" COMMENTED "$HEAD" "$T1" "$(FIND_RECEIPT "${HEAD:0:10}")")
APPROVE=$(rev 21 mzlikesb APPROVED "$HEAD" "$T3" "")

dcheck "dev: clean receipt (no findings) -> success" success dev "[$CLEAN_C]" '[]' '[]'
dcheck "dev: latest review has inline findings -> pending" pending dev '[]' "[$FIND_R]" "[$(inline 11 "$HEAD")]"
dcheck "dev: findings earlier, latest clean -> success" success dev "[$CLEAN_C]" "[$FIND_R]" "[$(inline 11 "$HEAD")]"
dcheck "dev: clean earlier, findings latest -> pending" pending dev "[$(cmt "$BOT" "$(CLEAN_RECEIPT "${HEAD:0:10}")" "$T1")]" "[$(rev 12 "$BOT" COMMENTED "$HEAD" "$T2" "$(FIND_RECEIPT "${HEAD:0:10}")")]" "[$(inline 12 "$HEAD")]"
dcheck "dev: no inline but summary lists findings -> pending" pending dev '[]' "[$FIND_R]" '[]'
dcheck "dev: findings on old head, clean on new head -> success" success dev "[$CLEAN_C]" "[$(rev 13 "$BOT" COMMENTED "$OLD" "$T1" "$(FIND_RECEIPT "${OLD:0:10}")")]" "[$(inline 13 "$OLD")]"
dcheck "dev: clean receipt only for old head -> pending" pending dev "[$(cmt "$BOT" "$(CLEAN_RECEIPT "${OLD:0:10}")" "$T2")]" '[]' '[]'
dcheck "dev: no Codex review -> pending" pending dev '[]' '[]' '[]'
dcheck "dev: findings + user Approve on head -> success" success dev '[]' "[$FIND_R,$APPROVE]" "[$(inline 11 "$HEAD")]"
dcheck "dev: user Approve without Codex review -> pending" pending dev '[]' "[$APPROVE]" '[]'
dcheck "dev: Codex review only in progress + Approve -> pending" pending dev "[$(user "$BOT" "$(state "$HEAD" in_progress)")]" "[$APPROVE]" '[]'
dcheck "dev: Approve on old head + findings on head -> pending" pending dev '[]' "[$FIND_R,$(rev 22 mzlikesb APPROVED "$OLD" "$T3" "")]" "[$(inline 11 "$HEAD")]"
dcheck "dev: Approve from someone else -> pending" pending dev '[]' "[$FIND_R,$(rev 23 someone-else APPROVED "$HEAD" "$T3" "")]" "[$(inline 11 "$HEAD")]"
dcheck "dev: Approve then dismissed -> pending" pending dev '[]' "[$FIND_R,$(rev 24 mzlikesb DISMISSED "$HEAD" "$T3" "")]" "[$(inline 11 "$HEAD")]"
dcheck "dev: Approve then changes requested -> pending" pending dev '[]' "[$FIND_R,$APPROVE,$(rev 25 mzlikesb CHANGES_REQUESTED "$HEAD" 2026-11-28T09:30:00Z "")]" "[$(inline 11 "$HEAD")]"
dcheck "dev: state summary completed, no findings -> success" success dev "[$(user "$BOT" "$(state "$HEAD" completed)")]" '[]' '[]'
dcheck "dev: state summary says findings -> pending" pending dev "[$(user "$BOT" "$(state "$HEAD" completed | sed 's/"has_any_findings":false/"has_any_findings":true/')")]" '[]' '[]'
dcheck "dev: clean words from another author -> pending" pending dev "[$(cmt someone-else "$(CLEAN_RECEIPT "${HEAD:0:10}")" "$T2")]" '[]' '[]'
dcheck "main: findings still count as reviewed" success main '[]' "[$FIND_R]" "[$(inline 11 "$HEAD")]"
dcheck "main: Approve alone is not a review" pending main '[]' "[$APPROVE]" '[]'

# Large inline lists go through files: Linux caps one argv string at 128KB (MAX_ARG_STRLEN),
# so a list passed as an argument would fail there. Fixtures are built into files (never
# through argv) and checked before use, so a broken fixture fails instead of passing quietly.
# A review whose body reads clean: only its inline comments can make it pending.
CLEAN_REVIEW=$(rev 15 "$BOT" COMMENTED "$HEAD" "$T1" "$(CLEAN_RECEIPT "${HEAD:0:10}")")
fixture_ok() { # fixture_ok <file> <min-bytes> <want-length>
  local size len
  size=$(wc -c <"$1" | tr -d ' ')
  len=$(jq 'length' "$1" 2>/dev/null) || len=bad
  if [ "$size" -gt "$2" ] && [ "$len" = "$3" ]; then echo "ok   fixture $(basename "$1"): $size bytes, $len items"; return 0; fi
  echo "FAIL fixture $(basename "$1"): $size bytes, length $len (want > $2 bytes, $3 items)"; fail=1; return 1
}
gate() { # gate <rc-file> -> "state<TAB>description" for base dev, CLEAN_REVIEW only
  echo '[]' >"$tmp/c.json"; echo "[$CLEAN_REVIEW]" >"$tmp/r.json"
  bash codex-gate.sh "$HEAD" "$tmp/c.json" "$tmp/r.json" dev "$1" | jq -r '[.state, .description] | @tsv'
}
# 120 unrelated inline comments of 2000 chars each (other review ids), written by jq to a file.
if jq -n '[range(0; 120) | {pull_request_review_id: (1000 + .), commit_id: "x",
      user: {login: "someone"}, body: ("x" * 2000)}]' >"$tmp/big.json" &&
  fixture_ok "$tmp/big.json" 200000 120; then
  out=$(gate "$tmp/big.json")
  if [ "${out%%$'\t'*}" = success ]; then echo "ok   dev: clean review with a big unrelated inline list -> success"
  else echo "FAIL dev: big clean list ($out)"; fail=1; fi
  # The same big list plus one inline finding on the clean-looking review.
  inline 15 "$HEAD" >"$tmp/one.json"
  if jq -s '.[0] + [.[1]]' "$tmp/big.json" "$tmp/one.json" >"$tmp/big-find.json" &&
    fixture_ok "$tmp/big-find.json" 200000 121; then
    out=$(gate "$tmp/big-find.json")
    case "$out" in
      pending$'\t'*"Codex 지적"*) echo "ok   dev: finding inside a big inline list -> pending (read the finding)" ;;
      *) echo "FAIL dev: finding inside a big inline list ($out)"; fail=1 ;;
    esac
  else
    echo "FAIL could not build the big inline fixture with a finding"; fail=1
  fi
else
  echo "FAIL could not build the big inline fixture"; fail=1
fi
# Control: the reason differs when the list is missing (fail closed), so the case above
# really saw the finding rather than an unreadable list.
out=$(echo '[]' >"$tmp/c.json"; echo "[$CLEAN_REVIEW]" >"$tmp/r.json"; bash codex-gate.sh "$HEAD" "$tmp/c.json" "$tmp/r.json" dev | jq -r .description)
case "$out" in *"읽지 못함"*) echo "ok   missing list has its own reason" ;; *) echo "FAIL missing list reason ($out)"; fail=1 ;; esac

# (b) needs the Approve strictly after the latest Codex result for head.
T0=2026-11-28T08:00:00Z
dcheck "dev: Approve first, Codex findings after -> pending" pending dev '[]' "[$(rev 31 mzlikesb APPROVED "$HEAD" "$T0" ""),$FIND_R]" "[$(inline 11 "$HEAD")]"
dcheck "dev: Codex findings, Approve after -> success" success dev '[]' "[$FIND_R,$APPROVE]" "[$(inline 11 "$HEAD")]"
dcheck "dev: clean Codex review, no Approve -> success via (a)" success dev "[$CLEAN_C]" '[]' '[]'
dcheck "dev: Approve at the same instant as findings -> pending" pending dev '[]' "[$FIND_R,$(rev 32 mzlikesb APPROVED "$HEAD" "$T1" "")]" "[$(inline 11 "$HEAD")]"
dcheck "dev: Approve, then findings, then a newer findings review -> pending" pending dev '[]' "[$FIND_R,$(rev 33 mzlikesb APPROVED "$HEAD" "$T2" ""),$(rev 14 "$BOT" COMMENTED "$HEAD" "$T3" "$(FIND_RECEIPT "${HEAD:0:10}")")]" "[$(inline 11 "$HEAD"),$(inline 14 "$HEAD")]"
dcheck "dev: Approve after findings but before the state summary changed -> pending" pending dev "[$(jq -n --arg b "$(state "$HEAD" completed | sed 's/"has_any_findings":false/"has_any_findings":true/')" '{user:{login:"chatgpt-codex-connector[bot]"},body:$b,created_at:"2026-11-28T07:00:00Z",updated_at:"2026-11-28T09:30:00Z"}')]" "[$FIND_R,$APPROVE]" "[$(inline 11 "$HEAD")]"
dcheck "dev: findings, Approve after, then changes requested -> pending" pending dev '[]' "[$FIND_R,$APPROVE,$(rev 34 mzlikesb CHANGES_REQUESTED "$HEAD" 2026-11-28T09:40:00Z "")]" "[$(inline 11 "$HEAD")]"

# Status context per base (statuses are per SHA): the same head in a dev PR and a main PR.
ctx() { # ctx <base or ""> -> "context state" for the findings-only head
  echo '[]' >"$tmp/c.json"; echo "[$FIND_R]" >"$tmp/r.json"; echo "[$(inline 11 "$HEAD")]" >"$tmp/rc.json"
  if [ -n "$1" ]; then bash codex-gate.sh "$HEAD" "$tmp/c.json" "$tmp/r.json" "$1" "$tmp/rc.json"
  else bash codex-gate.sh "$HEAD" "$tmp/c.json" "$tmp/r.json"; fi | jq -r '"\(.context) \(.state)"'
}
for want in "dev|codex-reviewed-dev pending" "main|codex-reviewed success" "feat/base|codex-reviewed success" "|codex-reviewed success"; do
  b=${want%%|*}; w=${want#*|}; got=$(ctx "$b")
  if [ "$got" = "$w" ]; then echo "ok   context for base '${b:-none}': $got"; else echo "FAIL context for base '${b:-none}': $got (want $w)"; fail=1; fi
done
# Only the dev verdict ever names codex-reviewed-dev, so the looser main verdict on the
# same SHA cannot turn the dev PR's required status green.
n=0; for b in main feat/base release/x ""; do [ "$(ctx "$b" | cut -d' ' -f1)" = codex-reviewed-dev ] && n=$((n + 1)); done
if [ "$n" = 0 ]; then echo "ok   no other base writes codex-reviewed-dev"; else echo "FAIL $n other bases write codex-reviewed-dev"; fail=1; fi
echo '[]' >"$tmp/c.json"; echo '[]' >"$tmp/r.json"
got=$(bash codex-gate.sh "$HEAD" "$tmp/c.json" "$tmp/r.json" dev "$tmp/rc.json" | jq -r .context)
if [ "$got" = codex-reviewed-dev ]; then echo "ok   dev pending without review still uses codex-reviewed-dev"; else echo "FAIL dev no-review context $got"; fail=1; fi
got=$(bash codex-gate.sh "$HEAD" "$tmp/c.json" "$tmp/r.json" dev | jq -r .context)
if [ "$got" = codex-reviewed-dev ]; then echo "ok   dev fail-closed uses codex-reviewed-dev"; else echo "FAIL dev fail-closed context $got"; fail=1; fi

# base dev without the inline list fails closed.
echo "[$CLEAN_C]" >"$tmp/c.json"; echo '[]' >"$tmp/r.json"
got=$(bash codex-gate.sh "$HEAD" "$tmp/c.json" "$tmp/r.json" dev | jq -r .state)
if [ "$got" = pending ]; then echo "ok   dev without review-comments file"; else echo "FAIL dev without review-comments file ($got)"; fail=1; fi
exit $fail
