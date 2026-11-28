#!/usr/bin/env bash
# PR metadata rules for the pr-check workflow. Pure function of its inputs (no network).
# Usage: pr-check.sh <pr.json> <reviews.json> <dev-flow> [<release-compare-status>]
#   dev-flow: repo variable DEV_FLOW; only "on" turns on the dev/release rules (plan 010 C).
#   release-compare-status: GitHub compare status of dev...<head sha> ("behind"/"identical"
#   mean the head is in dev's history). Only read for base main under DEV_FLOW=on.
# Prints one error per line and exits 1 when any rule fails.
set -uo pipefail
pr=$(cat "$1") || exit 2
reviews=$(cat "$2") || exit 2
flow=${3:-}
compare=${4:-}
errors=()

base=$(jq -r '.base.ref' <<<"$pr")
ref=$(jq -r '.head.ref' <<<"$pr")
sha=$(jq -r '.head.sha | ascii_downcase' <<<"$pr")
has_label() { jq -e --arg n "$1" '[.labels[].name] | index($n) != null' <<<"$pr" >/dev/null; }
count_prefix() { jq --arg p "$1" '[.labels[].name | select(startswith($p))] | length' <<<"$pr"; }
auto_on=$(jq '.auto_merge != null' <<<"$pr")

check_issue_line() {
  local line value
  line=$(jq -r '.body // ""' <<<"$pr" | tr -d '\r' | grep -m1 -E '^- 관련 이슈:' || true)
  if [ -z "$line" ]; then
    errors+=("PR 본문에 '- 관련 이슈:' 줄이 없습니다.")
    return
  fi
  value="${line#- 관련 이슈:}"
  value="$(echo "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [ "$value" != "없음" ] && ! echo "$value" | grep -qE '(Closes|Refs|Fixes) #[0-9]+'; then
    errors+=("'관련 이슈' 값은 '없음' 이거나 'Closes #N' / 'Refs #N' / 'Fixes #N' 이어야 합니다. (현재: ${value:-빈 값})")
  fi
}
check_milestone() {
  if [ "$(jq '.milestone == null' <<<"$pr")" = "true" ]; then
    errors+=("마일스톤이 설정되어 있지 않습니다.")
  fi
}
check_size_stage() {
  local size_count stage_count
  size_count=$(count_prefix size:)
  stage_count=$(count_prefix stage:)
  [ "$size_count" -eq 1 ] || errors+=("size:* 라벨이 정확히 1개여야 합니다. (현재 ${size_count}개; size:small 또는 size:large)")
  [ "$stage_count" -eq 1 ] || errors+=("stage:* 라벨이 정확히 1개여야 합니다. (현재 ${stage_count}개)")
}
check_release_labels() { # release replaces size:* and stage:*
  has_label release || errors+=("릴리스 PR에는 release 라벨이 있어야 합니다.")
  [ "$(count_prefix size:)" -eq 0 ] || errors+=("release 라벨이 size:* 를 대신합니다. size:* 라벨을 떼세요.")
  [ "$(count_prefix stage:)" -eq 0 ] || errors+=("release 라벨이 stage:* 를 대신합니다. stage:* 라벨을 떼세요.")
}
no_auto() { # no_auto <who merges>
  if [ "$auto_on" = true ]; then
    errors+=("$1 auto-merge가 예약되어 있습니다. 사용자가 직접 머지합니다. 예약을 해제하세요(gh pr merge --disable-auto).")
  fi
}
user_approved_head() { # the user's latest decisive review on the head commit is APPROVED
  jq -e --arg sha "$sha" '
    [ .[] | select(.user.login == "mzlikesb" and ((.commit_id // "") | ascii_downcase) == $sha)
          | select(.state != "COMMENTED" and .state != "PENDING") ]
    | sort_by(.submitted_at // "") | last | .state == "APPROVED"' <<<"$reviews" >/dev/null
}
large() { has_label size:large; }
same_repo() { # head branch lives in this repository (a fork's `main` is not our main)
  jq -e '(.head.repo.full_name // "") != "" and .head.repo.full_name == .base.repo.full_name' <<<"$pr" >/dev/null
}

if [ "$flow" = on ] && [ "$base" = main ]; then
  # Only snapshots cut from dev go to main (plan 010 C).
  case "$ref" in
    release/*)
      case "$compare" in
        behind | identical) ;;
        *) errors+=("릴리스 head가 dev의 기록에 없습니다(dev...head: ${compare:-알 수 없음}). dev에서 release/* 를 다시 자르세요.") ;;
      esac ;;
    *) errors+=("main으로는 release/* 브랜치만 갑니다(현재 head: $ref). 작업 PR은 base를 dev로 여세요.") ;;
  esac
  check_release_labels
  check_milestone
  check_issue_line
  no_auto "릴리스 PR에"
elif [ "$flow" = on ] && [ "$base" = dev ] && [ "$ref" = main ] && has_label release && same_repo; then
  # Recovery after an accidental squash release: main merged back into dev (tasks R1c).
  check_release_labels
  check_milestone
  check_issue_line
  no_auto "main → dev 복구 PR에"
else
  check_issue_line
  check_size_stage
  check_milestone
  if large; then no_auto "size:large PR에"; fi
  if [ "$flow" = on ] && [ "$base" = dev ] && large && ! user_approved_head; then
    errors+=("dev로 가는 size:large PR은 head ${sha:0:7}에 사용자(mzlikesb) Approve가 있어야 합니다.")
  fi
fi

if [ "${#errors[@]}" -gt 0 ]; then
  printf '%s\n' "${errors[@]}"
  exit 1
fi
echo "pr-check passed"
