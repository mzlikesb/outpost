#!/usr/bin/env bash
# Polls a PR and prints one line per new review comment, review, or conversation comment.
# Meant to run under Claude Code's Monitor tool: each stdout line is an event.
# Also reports once per head SHA when the codex-reviewed commit status turns success
# (Codex edits its summary and reacts instead of commenting when it finds nothing).
# Skips the agent account's own comments; neon reviews (fixed header) are reported.
# Exits when the PR is merged or closed.
# Usage: scripts/watch-pr.sh <pr-number> [interval-seconds]
set -uo pipefail

pr=${1:?usage: scripts/watch-pr.sh <pr-number> [interval]}
interval=${2:-60}
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
seen=$(mktemp)
trap 'rm -f "$seen"' EXIT

role() { # role <login> [body]. Exact logins only; anyone not listed is untrusted (public repo).
  case "$1" in
    'chatgpt-codex-connector[bot]') echo codex ;;
    # The agent account posts both agent work and neon output. neon-review.sh and
    # neon-art-critique.sh (not the model) prefix every post with a fixed header.
    chillingdaisy-worker1) case "${2:-}" in '## neon review'*|'## neon art critique'*) echo neon ;; *) echo agent ;; esac ;;
    mzlikesb) echo user ;;
    'github-actions[bot]') echo ci ;;
    *) echo untrusted ;;
  esac
}

emit() { # emit <id> <kind> <login> <url> <body>
  local id=$1 kind=$2 login=$3 url=$4 body=$5 who
  grep -qx "$id" "$seen" && return
  echo "$id" >>"$seen"
  who=$(role "$login" "$body")
  # Text from untrusted authors never reaches the agent; only the fact that it exists.
  if [ "$who" = untrusted ]; then
    echo "PR#$pr $kind [untrusted] $login: (내용 생략 — 신뢰 목록 밖 작성자) — $url"
    return
  fi
  # The agent's own comments are not news to the agent.
  [ "$who" = agent ] && return
  # Replying to an inline comment creates an empty COMMENTED review; the reply itself is
  # reported separately. Empty APPROVED / CHANGES_REQUESTED reviews still carry a verdict.
  [ "$kind" = review:COMMENTED ] && [ -z "${body// /}" ] && return
  # Codex's status summary edits itself; only its receipts and findings matter.
  grep -q 'codex-pull-request-review-summary' <<<"$body" && return
  local first
  first=$(tr '\n' ' ' <<<"$body" | sed -E 's/<[^>]+>//g; s/[[:space:]]+/ /g' | cut -c1-140)
  echo "PR#$pr $kind [$who] $login: $first — $url"
}

while true; do
  state=$(gh pr view "$pr" --repo "$repo" --json state -q .state 2>/dev/null || echo UNKNOWN)
  if [ "$state" = MERGED ] || [ "$state" = CLOSED ]; then
    echo "PR#$pr $state — 감시 종료"
    exit 0
  fi

  head=$(gh pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid 2>/dev/null || true)
  if [ -n "$head" ]; then
    # PRs into dev are judged on their own context (plan 010 B2).
    ctx=codex-reviewed
    [ "$(gh pr view "$pr" --repo "$repo" --json baseRefName -q .baseRefName 2>/dev/null || true)" = dev ] && ctx=codex-reviewed-dev
    cstate=$(gh api "repos/$repo/commits/$head/status" \
      --jq "[.statuses[] | select(.context == \"$ctx\")][0].state // \"\"" 2>/dev/null || true)
    if [ "$cstate" = success ] && ! grep -qx "k$head" "$seen"; then
      echo "k$head" >>"$seen"
      echo "PR#$pr status [codex] head ${head:0:7} 리뷰 완료($ctx success)"
    fi
  fi

  while IFS=$'\t' read -r id login url body; do
    [ -n "$id" ] && emit "c$id" comment "$login" "$url" "$body"
  done < <(gh api --paginate "repos/$repo/issues/$pr/comments?since=$since&per_page=100" \
    --jq '.[] | [.id, .user.login, .html_url, ((.body // "") | gsub("[\r\n\t]+"; " ") | .[0:600])] | @tsv' 2>/dev/null || true)

  while IFS=$'\t' read -r id login url body; do
    [ -n "$id" ] && emit "r$id" inline "$login" "$url" "$body"
  done < <(gh api --paginate "repos/$repo/pulls/$pr/comments?since=$since&per_page=100" \
    --jq '.[] | [.id, .user.login, .html_url, ((.body // "") | gsub("[\r\n\t]+"; " ") | .[0:600])] | @tsv' 2>/dev/null || true)

  while IFS=$'\t' read -r id login url state body; do
    [ -n "$id" ] && emit "v$id" "review:$state" "$login" "$url" "$body"
  done < <(gh api --paginate "repos/$repo/pulls/$pr/reviews?per_page=100" \
    --jq '.[] | select(.submitted_at >= "'"$since"'") | [.id, .user.login, .html_url, .state, ((.body // "") | gsub("[\r\n\t]+"; " ") | .[0:600])] | @tsv' 2>/dev/null || true)

  sleep "$interval"
done
