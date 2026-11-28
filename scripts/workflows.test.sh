#!/usr/bin/env bash
# Trigger facts plan 010 relies on, read from the workflow files (grep, no YAML parser):
# PR triggers have no branch filter (so PRs into dev and release/* run every check), ci also
# runs on dev pushes, and the preview cleanup only ever deletes pr-<N>.
set -uo pipefail
cd "$(dirname "$0")/../.github/workflows"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
on_block() { awk '/^on:/{f=1; next} f && /^[^[:space:]#]/{exit} f' "$1"; }
# pr_block <file> <event>: the lines under one trigger inside on:
pr_block() { on_block "$1" | awk -v e="  $2:" 'index($0, e) == 1 {f=1; next} f && /^  [^ ]/{exit} f'; }

for wf in ci.yml pr-check.yml codex-gate.yml deploy.yml; do
  on_block "$wf" | grep -qE '^  pull_request:' || { bad "$wf has no pull_request trigger"; continue; }
  if pr_block "$wf" pull_request | grep -qE '^\s+branches(-ignore)?:'; then bad "$wf pull_request is limited to branches"
  else ok "$wf pull_request runs for every base"; fi
done
for wf in pr-check.yml codex-gate.yml; do
  if pr_block "$wf" pull_request_review | grep -q dismissed && pr_block "$wf" pull_request_review | grep -q submitted
  then ok "$wf re-runs on review submitted and dismissed"; else bad "$wf misses pull_request_review submitted/dismissed"; fi
done
if pr_block codex-gate.yml pull_request | grep -qE 'types:.*\bedited\b'; then ok "codex-gate re-judges when the PR is edited (base change)"
else bad "codex-gate pull_request types miss edited"; fi
if pr_block pr-check.yml pull_request | grep -qE '^\s+- edited$'; then ok "pr-check re-runs when the PR is edited"; else bad "pr-check misses edited"; fi
if awk '/^jobs:/{f=1} f' ci.yml | grep -qE '^  actionlint:'; then ok "actionlint is a ci.yml job (same PR triggers)"; else bad "actionlint is not a ci.yml job"; fi
# The judges come from the default branch, not the PR.
for wf in codex-gate.yml pr-check.yml; do
  if awk '/uses: actions\/checkout/{n=NR} n && NR<=n+2' "$wf" | grep -qF 'ref: ${{ github.event.repository.default_branch }}'
  then ok "$wf checks out its judge from the default branch"; else bad "$wf does not check out the default branch"; fi
done
if grep -qF "context=\"\$(jq -r '.context // \"codex-reviewed\"' <<<\"\$verdict\")\"" codex-gate.yml && ! grep -qE 'context=codex-reviewed( |$)' codex-gate.yml
then ok "codex-gate posts the verdict's context (codex-reviewed-dev for base dev)"; else bad "codex-gate does not post the verdict's context"; fi
if pr_block ci.yml push | grep -qE 'branches: \[main, dev\]'; then ok "ci runs on main and dev pushes"; else bad "ci push branches are not [main, dev]"; fi
if pr_block deploy.yml push | grep -qE 'branches: \[main\]'; then ok "production deploys only on main pushes"; else bad "deploy push branches changed"; fi
cleanup=$(awk '/^  cleanup:/{f=1; next} f && /^  [^ ]/{exit} f' deploy.yml)
names=$(grep -E '^\s+PREVIEW_NAME:' <<<"$cleanup" | sed -E 's/^[[:space:]]+//' | sort -u)
if [ "$names" = 'PREVIEW_NAME: pr-${{ github.event.pull_request.number }}' ] && grep -q 'preview delete --name "$PREVIEW_NAME"' <<<"$cleanup"
then ok "preview cleanup only deletes pr-<N> (never dev)"; else bad "cleanup PREVIEW_NAME: $names"; fi
if grep -q 'DEV_FLOW: ${{ vars.DEV_FLOW }}' pr-check.yml; then ok "pr-check reads vars.DEV_FLOW"; else bad "pr-check does not read vars.DEV_FLOW"; fi
exit "$fail"
