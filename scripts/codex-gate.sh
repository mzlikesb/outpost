#!/usr/bin/env bash
# Prints the codex-reviewed verdict JSON:
#   codex-gate.sh <head-sha> <comments.json> <reviews.json> [<base> <review-comments.json>]
# The verdict names its status context: `codex-reviewed-dev` for base `dev`, else `codex-reviewed`.
# base `dev` also requires a clean latest Codex review or a user Approve (plan 010 B2, tasks R2);
# without the inline review comments it fails closed. Any other base (or none) is the main rule.
# Pure function of its inputs (no network); the workflow fetches and posts.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
head=$1 comments=$2 reviews=$3 base=${4:-main} rc=${5:-}
# Inputs go through files, never argv (argument size limit, about 128KB per argument).
if [ -n "$rc" ]; then rcfile=$rc; else rcfile=/dev/null; fi
jq -n -c --arg head "$head" --arg base "$base" --slurpfile rc "$rcfile" \
  --slurpfile c "$comments" --slurpfile r "$reviews" \
  '{head: $head, base: $base, comments: $c[0], reviews: $r[0], review_comments: ($rc[0] // null)}' |
  jq -c -f "$here/codex-gate.jq"
