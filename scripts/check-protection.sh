#!/usr/bin/env bash
# Compares the real branch protection of main and dev and the repo merge settings with what
# AGENTS.md "승인과 머지" claims. Prints the differences and exits 1 on any mismatch.
# Also prints the repo variable DEV_FLOW (information, not compared: off is a valid state).
# Exit 2 when a protection read is forbidden (agent-account token).
# Usage: check-protection.sh               (reads GitHub with gh)
#        check-protection.sh <main-protection.json> <repo.json> <dev-protection.json> [DEV_FLOW]
#        (fixtures, no network; a protection file holding {"message": ...} means "not protected")
# Expected values below mirror the AGENTS.md bullets "브랜치 보호(main)"·"브랜치 보호(dev)".
# Change both together.
set -uo pipefail

REPO=mzlikesb/outpost
fail=0

# read_protection <branch>: prints the protection JSON, or {"message": ...} when the branch
# is missing or unprotected. Returns 2 (message on stdout) when the read is forbidden.
read_protection() {
  local out err
  err=$(mktemp)
  if out=$(gh api "repos/$REPO/branches/$1/protection" 2>"$err"); then
    rm -f "$err"; printf '%s' "$out"; return 0
  fi
  # gh prints the error body on stdout and a summary on stderr; look at both.
  local all="$out"$'\n'"$(cat "$err")"
  if grep -qiE 'Branch not protected|Branch not found' <<<"$all"; then
    rm -f "$err"; jq -n --arg m "$(grep -oiE 'Branch not (protected|found)' <<<"$all" | head -1)" '{message:$m}'; return 0
  fi
  if grep -qE '403|404|Resource not accessible|Not Found' "$err"; then
    rm -f "$err"
    echo "읽기 권한 없음 — 사용자 계정으로 실행 (사용자 터미널에서 scripts/check-protection.sh)"
    return 2
  fi
  cat "$err" >&2; rm -f "$err"; return 2
}

if [ $# -ge 3 ]; then
  main_prot=$(cat "$1") || exit 2
  repo=$(cat "$2") || exit 2
  dev_prot=$(cat "$3") || exit 2
  dev_flow=${4:-}
else
  main_prot=$(read_protection main) || { echo "$main_prot"; exit 2; }
  dev_prot=$(read_protection dev) || { echo "$dev_prot"; exit 2; }
  repo=$(gh api "repos/$REPO" --jq '{allow_squash_merge,allow_merge_commit,allow_rebase_merge}') || exit 2
  # 404 means the variable is not set; any other failure is reported as unreadable.
  verr=$(mktemp)
  if ! dev_flow=$(gh api "repos/$REPO/actions/variables/DEV_FLOW" --jq .value 2>"$verr"); then
    if grep -qE '404|Not Found' "$verr"; then dev_flow=""; else dev_flow="읽지 못함"; fi
  fi
  rm -f "$verr"
fi

# compare <label> <expected lines> <actual lines>
compare() {
  local key want got line
  while IFS= read -r line; do
    key=${line%%=*}; want=${line#*=}
    got=$(grep -m1 "^$key=" <<<"$3" | cut -d= -f2-)
    if [ "$got" != "$want" ]; then
      echo "차이 $1 $key: AGENTS.md=$want 실제=${got:-없음}"
      fail=1
    fi
  done <<<"$2"
}
unprotected() { # unprotected <label> <json>: reports and returns 0 when there is no protection
  local m
  m=$(jq -r '.message // empty' <<<"$2" 2>/dev/null)
  [ -n "$m" ] || return 1
  echo "차이 $1 branch_protection: AGENTS.md=보호 켜짐 실제=보호 없음($m)"
  fail=1
}

if ! unprotected main "$main_prot"; then
  actual=$(jq -r --argjson repo "$repo" '
    "required_checks=" + ((.required_status_checks.contexts // []) | sort | join(",")),
    "strict=" + ((.required_status_checks.strict // false) | tostring),
    "approvals=" + ((.required_pull_request_reviews.required_approving_review_count // 0) | tostring),
    "dismiss_stale_reviews=" + ((.required_pull_request_reviews.dismiss_stale_reviews // false) | tostring),
    "require_last_push_approval=" + ((.required_pull_request_reviews.require_last_push_approval // false) | tostring),
    "enforce_admins=" + ((.enforce_admins.enabled // false) | tostring),
    "allow_squash_merge=" + (($repo.allow_squash_merge // false) | tostring),
    "allow_merge_commit=" + (($repo.allow_merge_commit // false) | tostring),
    "allow_rebase_merge=" + (($repo.allow_rebase_merge // false) | tostring)
  ' <<<"$main_prot") || { echo "main protection JSON을 읽지 못했다" >&2; exit 2; }
  compare main 'required_checks=actionlint,ci,codex-reviewed,pr-check
strict=false
approvals=1
dismiss_stale_reviews=true
require_last_push_approval=true
enforce_admins=true
allow_squash_merge=true
allow_merge_commit=true
allow_rebase_merge=false' "$actual"
fi

if ! unprotected dev "$dev_prot"; then
  actual=$(jq -r '
    "pull_request_required=" + ((.required_pull_request_reviews != null) | tostring),
    "required_checks=" + ((.required_status_checks.contexts // []) | sort | join(",")),
    "approvals=" + ((.required_pull_request_reviews.required_approving_review_count // 0) | tostring),
    "code_owner_reviews=" + ((.required_pull_request_reviews.require_code_owner_reviews // false) | tostring),
    "dismiss_stale_reviews=" + ((.required_pull_request_reviews.dismiss_stale_reviews // false) | tostring),
    "enforce_admins=" + ((.enforce_admins.enabled // false) | tostring),
    "allow_force_pushes=" + ((.allow_force_pushes.enabled // false) | tostring),
    "allow_deletions=" + ((.allow_deletions.enabled // false) | tostring)
  ' <<<"$dev_prot") || { echo "dev protection JSON을 읽지 못했다" >&2; exit 2; }
  compare dev 'pull_request_required=true
required_checks=actionlint,ci,codex-reviewed-dev,pr-check
approvals=0
code_owner_reviews=true
dismiss_stale_reviews=true
enforce_admins=true
allow_force_pushes=false
allow_deletions=false' "$actual"
fi

echo "정보 DEV_FLOW=${dev_flow:-없음} (on일 때만 pr-check의 dev·릴리스 규칙이 켜진다)"
if [ "$fail" -eq 0 ]; then echo "브랜치 보호가 AGENTS.md와 일치한다"; fi
exit "$fail"
