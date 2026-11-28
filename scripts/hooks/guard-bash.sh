#!/usr/bin/env bash
# PreToolUse guard for Bash commands. Exit 2 blocks the command and shows the reason to the agent.
# A mistake guard, not a security boundary: it reads the parsed command segments, not raw text.
set -uo pipefail
# shellcheck source=scripts/hooks/lib.sh
source "$(dirname "$0")/lib.sh"

input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
cwd=${cwd:-$PWD}

block() {
  echo "차단됨: $1" >&2
  exit 2
}

segs=$(split_segments "$cmd")
raw=$(raw_segments "$cmd")

# --- Identity: agents act only as the agent account ------------------------------------
# Overriding or clearing the variables that pick the account, or switching gh accounts.
id_vars='(GH_CONFIG_DIR|GIT_CONFIG_[A-Z0-9_]+|GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN)'
if grep -qE "^[[:space:]]*[({]?[[:space:]]*(env[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|'[^']*'|[^[:space:]]*)[[:space:]]+)*${id_vars}=" <<<"$raw" ||
  grep -qE "^[[:space:]]*(export|declare|typeset|local|readonly)\b.*[[:space:]]${id_vars}=" <<<"$raw" ||
  grep -qE "^[[:space:]]*unset\b.*${id_vars}" <<<"$raw" ||
  grep -qE '^[[:space:]]*env[[:space:]]+(-i|-u|--unset|--ignore-environment)' <<<"$raw"; then
  block "계정을 고르는 변수(GH_CONFIG_DIR, GIT_CONFIG_*, GH_TOKEN)를 바꾸거나 지우지 않는다. 에이전트 계정은 세션 설정이 정한다."
fi
if grep -qE '^[[:space:]]*gh[[:space:]]+auth[[:space:]]+(switch|login|logout|token|refresh|setup-git|git-credential)\b' <<<"$segs" ||
  grep -qE '^[[:space:]]*gh[[:space:]]+auth[[:space:]]+status\b.*(--show-token|-t\b)' <<<"$segs"; then
  block "gh 계정을 바꾸거나 토큰을 꺼내지 않는다(gh auth status만 허용)."
fi
if grep -qE '^[[:space:]]*git[[:space:]].*-c[[:space:]]*credential\.' <<<"$segs"; then
  block "'git -c credential.*'로 push 계정을 바꾸지 않는다."
fi

# Write commands (anything that pushes or changes GitHub state).
gh_api_write='^[[:space:]]*gh[[:space:]]+api\b.*(-X[[:space:]]*(POST|PATCH|PUT|DELETE)|--method([[:space:]]+|=)(POST|PATCH|PUT|DELETE)|[[:space:]](-f|-F)|[[:space:]](--field|--raw-field|--input)([[:space:]=]|$))'
gh_api_get='^[[:space:]]*gh[[:space:]]+api\b.*(-X[[:space:]]*GET|--method([[:space:]]+|=)GET)\b'
gh_write='^[[:space:]]*gh[[:space:]]+(pr[[:space:]]+(create|edit|comment|review|merge|ready|close|reopen)|issue[[:space:]]+(create|edit|comment|close|reopen)|label[[:space:]]+(create|edit|delete)|release[[:space:]]+create)\b'
git_opt=$git_cmd
is_push=false is_gh_write=false
grep -qE "^[[:space:]]*${git_opt}[[:space:]]+push\b" <<<"$segs" && is_push=true
grep -qE "$gh_write" <<<"$segs" && is_gh_write=true
# `-f` with `-X GET` sends query parameters, not a write.
if grep -E "$gh_api_write" <<<"$segs" | grep -qvE "$gh_api_get"; then is_gh_write=true; fi

# An inherited token beats the stored login for every gh call, so with one present no gh
# command or push runs at all (no need to classify which ones write).
if ! agent_no_token_override &&
  { grep -qE '^[[:space:]]*gh([[:space:]]|$)' <<<"$segs" || [ "$is_push" = true ]; }; then
  block "GH_TOKEN·GITHUB_TOKEN이 세션 환경에 있다. 저장된 에이전트 로그인보다 먼저 쓰여 다른 계정으로 나갈 수 있다. 세션 환경에서 지운다."
fi

# Fail closed: without the agent session settings, writes would silently go out as the user.
if [ "$is_gh_write" = true ] || [ "$is_push" = true ]; then
  agent_gh_ok || block "에이전트 gh 설정이 없다(GH_CONFIG_DIR → ${AGENT_LOGIN}). .claude/settings.local.json의 env를 확인하고 'scripts/agent-env.sh'로 점검한다."
fi
if [ "$is_push" = true ]; then
  agent_git_ok || block "git push 자격 증명이 에이전트 계정으로 설정돼 있지 않다(GIT_CONFIG_* → '!gh auth git-credential'). 'scripts/agent-env.sh'로 점검한다."
fi

# neon reviews are posted only through scripts/neon-review.sh, which adds this fixed header.
# Reading them, or mentioning neon in other text, is fine.
if [ "$is_gh_write" = true ] && grep -qF '## neon review' <<<"$cmd" && ! grep -q 'scripts/neon-review.sh' <<<"$cmd"; then
  block "neon 리뷰는 'scripts/neon-review.sh <PR> <플랜>'으로만 올린다."
fi

# --- Merges: agents only queue small PRs for auto-merge --------------------------------
# Each merge is checked in the directory it runs in: without an argument, gh picks the PR of
# that directory's current branch.
while IFS=$'\t' read -r merge_dir merge_seg; do
  grep -qE '^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge\b' <<<"$merge_seg" || continue
  if grep -qE -- '--admin\b' <<<"$merge_seg"; then
    block "'gh pr merge --admin' 금지. 필수 체크와 승인을 거쳐 머지한다."
  elif grep -qE -- '--disable-auto\b' <<<"$merge_seg"; then
    :
  elif grep -qE -- '--auto\b' <<<"$merge_seg"; then
    target=$(sed -E 's/^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge[[:space:]]*//' <<<"$merge_seg" | tr ' ' '\n' | grep -vE '^-|^$' | head -1 || true)
    labels=$(cd "$merge_dir" 2>/dev/null && gh pr view ${target:+"$target"} --json labels -q '[.labels[].name]|join(",")' 2>/dev/null || echo "?")
    grep -q 'size:small' <<<"$labels" || block "auto-merge 예약은 size:small PR만. large는 사용자가 직접 머지한다(PR ${target:-현재 브랜치} 라벨: ${labels})."
  else
    block "에이전트는 PR을 직접 머지하지 않는다. small은 'gh pr merge --auto --squash'로 예약, large는 사용자가 머지한다."
  fi
done < <(segment_dirs "$cwd" "$cmd")

# --- Branches -------------------------------------------------------------------------
repo_info() { # repo_info <dir>: sets branch and main_checkout; returns 1 outside a repo
  local d=$1
  [ "$(git -C "$d" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 1
  branch=$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null || echo "")
  local gd cd_
  gd=$(cd "$d" && realpath "$(git rev-parse --git-dir)")
  cd_=$(cd "$d" && realpath "$(git rev-parse --git-common-dir)")
  main_checkout=false
  [ "$gd" = "$cd_" ] && main_checkout=true
  return 0
}

push_segments=$(grep -E "^\s*${git_opt}\s+push\b" <<<"$segs" || true)
if [ -n "$push_segments" ]; then
  if grep -qE '(\s-[a-zA-Z]*f[a-zA-Z]*(\s|$)|--force\b|--force-with-lease|\s\+[^ ]+)' <<<"$push_segments"; then
    block "force push 금지."
  fi
  if grep -qE '(\s|:|:refs/heads/)(main|dev)(\s|$)' <<<"$push_segments"; then
    block "main·dev로 직접 push 금지. PR로 머지한다."
  fi
fi

d=$(dir_for "$cwd" "$cmd" "^\s*${git_opt}\s+(commit|push)\b")
if [ -n "$d" ] && repo_info "$d" && { [ "$branch" = main ] || [ "$branch" = dev ]; }; then
  block "main·dev 브랜치에서 commit/push 금지. 작업 브랜치(worktree)에서 한다."
fi

# Switching branches in the main checkout. File restores (`git checkout -- path`) are fine.
d=$(dir_for "$cwd" "$cmd" "^\s*${git_opt}\s+(switch|checkout)\b")
if [ -n "$d" ] && repo_info "$d" && [ "$main_checkout" = true ]; then
  seg=$(grep -E "^\s*${git_opt}\s+(switch|checkout)\b" <<<"$segs" | head -1)
  # Returning the main checkout to `main` is the one allowed switch.
  to_main=false
  grep -qE "${git_opt}\s+(switch|checkout)\s+main\s*$" <<<"$seg" && to_main=true
  if [ "$to_main" = false ] && { grep -qE "${git_opt}\s+switch\b" <<<"$seg" || ! grep -qE "${git_opt}\s+checkout\s+(\S+\s+)?--(\s|$)" <<<"$seg"; }; then
    block "메인 체크아웃에서 브랜치 전환 금지. 'git worktree add ../outpost-<주제> -b <브랜치> origin/main'을 쓴다."
  fi
fi

# --- Secrets --------------------------------------------------------------------------
secret_re='(^|/)(\.dev\.vars|\.env(\..*)?)$|\.pem$|\.key$'
add_seg=$(grep -E "^\s*${git_opt}\s+add\b" <<<"$segs" || true)
if [ -n "$add_seg" ] && grep -qE '(\.dev\.vars|\.env\b|\.pem\b)' <<<"$add_seg" && ! grep -q '\.example' <<<"$add_seg"; then
  block "시크릿 파일은 git에 넣지 않는다."
fi
d=$(dir_for "$cwd" "$cmd" "^\s*${git_opt}\s+commit\b")
if [ -n "$d" ]; then
  staged=$(git -C "$d" diff --cached --name-only 2>/dev/null | grep -E "$secret_re" | grep -v '\.example$' || true)
  [ -z "$staged" ] || block "스테이지에 시크릿 파일이 있다: $staged"
fi

exit 0
