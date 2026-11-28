#!/usr/bin/env bash
# Checks check-protection.sh on fake protection and repo JSON (no network), then on a fake gh.
set -uo pipefail
cd "$(dirname "$0")"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

prot() { # prot <contexts-json> <strict> <approvals> <dismiss> <lastpush> <admins>
  jq -n --argjson c "$1" --argjson s "$2" --argjson a "$3" --argjson d "$4" --argjson l "$5" --argjson e "$6" '{
    required_status_checks:{contexts:$c,strict:$s},
    required_pull_request_reviews:{required_approving_review_count:$a,dismiss_stale_reviews:$d,require_last_push_approval:$l},
    enforce_admins:{enabled:$e}}'
}
devprot() { # devprot <contexts-json> <approvals> <codeowners> <dismiss> <admins> <force> <delete>
  jq -n --argjson c "$1" --argjson a "$2" --argjson o "$3" --argjson d "$4" --argjson e "$5" --argjson f "$6" --argjson x "$7" '{
    required_status_checks:{contexts:$c,strict:false},
    required_pull_request_reviews:{required_approving_review_count:$a,require_code_owner_reviews:$o,dismiss_stale_reviews:$d},
    enforce_admins:{enabled:$e}, allow_force_pushes:{enabled:$f}, allow_deletions:{enabled:$x}}'
}
repo() { jq -n --argjson s "$1" --argjson m "$2" --argjson r "$3" '{allow_squash_merge:$s,allow_merge_commit:$m,allow_rebase_merge:$r}'; }
check() { # check <name> <want-exit> <want-substring> <main-prot> <repo> [dev-prot] [DEV_FLOW]
  echo "$4" >"$tmp/p.json"; echo "$5" >"$tmp/r.json"; echo "${6:-$OK_D}" >"$tmp/d.json"
  local out code
  out=$(bash check-protection.sh "$tmp/p.json" "$tmp/r.json" "$tmp/d.json" "${7:-}" 2>&1); code=$?
  if [ "$code" = "$2" ] && grep -q -- "$3" <<<"$out"; then echo "ok   $1"
  else echo "FAIL $1 (exit $code, want $2; out: $out)"; fail=1; fi
}

C4='["ci","pr-check","codex-reviewed","actionlint"]'
OK_P=$(prot "$C4" false 1 true true true)
OK_R=$(repo true true false)
D4='["ci","pr-check","codex-reviewed-dev","actionlint"]'
OK_D=$(devprot "$D4" 0 true true true false false)

check "matches" 0 "일치" "$OK_P" "$OK_R"
check "context order does not matter" 0 "일치" "$(prot '["codex-reviewed","actionlint","ci","pr-check"]' false 1 true true true)" "$OK_R"
check "missing codex-reviewed" 1 "main required_checks" "$(prot '["ci","pr-check","actionlint"]' false 1 true true true)" "$OK_R"
check "missing actionlint" 1 "required_checks" "$(prot '["ci","pr-check","codex-reviewed"]' false 1 true true true)" "$OK_R"
check "extra check" 1 "required_checks" "$(prot '["ci","pr-check","codex-reviewed","actionlint","x"]' false 1 true true true)" "$OK_R"
check "strict on" 1 "strict" "$(prot "$C4" true 1 true true true)" "$OK_R"
check "zero approvals" 1 "main approvals" "$(prot "$C4" false 0 true true true)" "$OK_R"
check "stale not dismissed" 1 "dismiss_stale_reviews" "$(prot "$C4" false 1 false true true)" "$OK_R"
check "no last push approval" 1 "require_last_push_approval" "$(prot "$C4" false 1 true false true)" "$OK_R"
check "admins not enforced" 1 "enforce_admins" "$(prot "$C4" false 1 true true false)" "$OK_R"
check "merge commit not allowed" 1 "allow_merge_commit" "$OK_P" "$(repo true false false)"
check "rebase allowed, squash off" 1 "allow_squash_merge" "$OK_P" "$(repo false true true)"
check "no reviews block" 1 "approvals" '{"required_status_checks":{"contexts":["ci","pr-check","codex-reviewed","actionlint"],"strict":false},"enforce_admins":{"enabled":true}}' "$OK_R"
check "main not protected" 1 "main branch_protection" '{"message":"Branch not protected"}' "$OK_R"

# dev (plan 010 A.2)
check "dev not protected" 1 "dev branch_protection" "$OK_P" "$OK_R" '{"message":"Branch not protected"}'
check "dev missing" 1 "Branch not found" "$OK_P" "$OK_R" '{"message":"Branch not found"}'
check "dev requires an Approve" 1 "dev approvals" "$OK_P" "$OK_R" "$(devprot "$D4" 1 true true true false false)"
check "dev without code owner reviews" 1 "dev code_owner_reviews" "$OK_P" "$OK_R" "$(devprot "$D4" 0 false true true false false)"
check "dev keeps stale approvals" 1 "dev dismiss_stale_reviews" "$OK_P" "$OK_R" "$(devprot "$D4" 0 true false true false false)"
check "dev missing codex-reviewed-dev" 1 "dev required_checks" "$OK_P" "$OK_R" "$(devprot '["ci","pr-check","actionlint"]' 0 true true true false false)"
check "dev requires main's codex-reviewed instead" 1 "dev required_checks" "$OK_P" "$OK_R" "$(devprot "$C4" 0 true true true false false)"
check "dev admins not enforced" 1 "dev enforce_admins" "$OK_P" "$OK_R" "$(devprot "$D4" 0 true true false false false)"
check "dev allows force push" 1 "dev allow_force_pushes" "$OK_P" "$OK_R" "$(devprot "$D4" 0 true true true true false)"
check "dev allows deletion" 1 "dev allow_deletions" "$OK_P" "$OK_R" "$(devprot "$D4" 0 true true true false true)"
check "dev without PR requirement" 1 "dev pull_request_required" "$OK_P" "$OK_R" '{"required_status_checks":{"contexts":["ci","pr-check","codex-reviewed-dev","actionlint"]},"enforce_admins":{"enabled":true}}'

# DEV_FLOW is shown, not compared.
check "DEV_FLOW on shown" 0 "DEV_FLOW=on" "$OK_P" "$OK_R" "$OK_D" on
check "DEV_FLOW unset shown" 0 "DEV_FLOW=없음" "$OK_P" "$OK_R" "$OK_D" ""

# Real (non-fixture) mode with a fake gh on PATH. The stub answers by URL.
mkdir "$tmp/bin"
fake_gh() { # fake_gh <main-mode> <dev-mode> [var-mode] : ok | notprot | notfound | 403 | 404
  cat >"$tmp/bin/gh" <<STUB
#!/usr/bin/env bash
mode() { case "\$1" in
  ok) cat "\$2"; exit 0 ;;
  notprot) echo '{"message":"Branch not protected","status":"404"}'; echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1 ;;
  notfound) echo '{"message":"Branch not found","status":"404"}'; echo 'gh: Branch not found (HTTP 404)' >&2; exit 1 ;;
  403) echo '{"message":"Resource not accessible by personal access token","status":"403"}'; echo 'gh: Resource not accessible by personal access token (HTTP 403)' >&2; exit 1 ;;
  404) echo '{"message":"Not Found","status":"404"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
esac; }
case "\$*" in
  *branches/main/protection*) mode $1 "$tmp/p.json" ;;
  *branches/dev/protection*) mode $2 "$tmp/d.json" ;;
  *actions/variables/DEV_FLOW*) case "${3:-on}" in on) echo on ;; 404) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;; *) echo 'gh: Resource not accessible (HTTP 403)' >&2; exit 1 ;; esac ;;
  *) echo '$OK_R' ;;
esac
STUB
  chmod +x "$tmp/bin/gh"
}
gh_case() { # gh_case <name> <want-exit> <want-substring> <main-mode> <dev-mode> [var-mode]
  echo "$OK_P" >"$tmp/p.json"; echo "$OK_D" >"$tmp/d.json"
  fake_gh "$4" "$5" "${6:-on}"
  local out code
  out=$(PATH="$tmp/bin:$PATH" bash check-protection.sh 2>&1); code=$?
  if [ "$code" = "$2" ] && grep -q -- "$3" <<<"$out"; then echo "ok   $1"; else echo "FAIL $1 (exit $code: $out)"; fail=1; fi
}
gh_case "gh: both match" 0 "일치" ok ok
gh_case "gh: DEV_FLOW shown" 0 "DEV_FLOW=on" ok ok
gh_case "DEV_FLOW not set" 0 "DEV_FLOW=없음" ok ok 404
gh_case "DEV_FLOW unreadable" 0 "DEV_FLOW=읽지 못함" ok ok 403
gh_case "403 exits 2" 2 "읽기 권한 없음" 403 ok
gh_case "404 Not Found (no permission) exits 2" 2 "읽기 권한 없음" 404 ok
gh_case "404 Branch not protected exits 1" 1 "main branch_protection" notprot ok
gh_case "dev not protected exits 1" 1 "dev branch_protection" ok notprot
gh_case "dev missing exits 1" 1 "Branch not found" ok notfound
gh_case "dev read forbidden exits 2" 2 "읽기 권한 없음" ok 403

exit "$fail"
