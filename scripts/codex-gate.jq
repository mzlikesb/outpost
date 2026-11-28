# Decides the `codex-reviewed` commit status for one PR head.
# Input: {"head": "<sha>", "base": "<branch>", "comments": [...issue comments],
#         "reviews": [...PR reviews], "review_comments": [...inline review comments] | null}
# Output: {"context": "codex-reviewed"|"codex-reviewed-dev", "state": "success"|"pending", "description": "..."}
# Commit statuses are per SHA, so the dev verdict goes to its own context
# (`codex-reviewed-dev`, required on dev): a PR with another base and the same head
# must not overwrite it with the looser verdict.
#
# Every base: Codex itself (exact bot login) left a receipt or a completed state summary
# for a commit that is the current head ("reviewed").
# base `dev` (no Approve brake there) additionally needs one of:
#   (a) the latest Codex receipt for head has no inline comments and says "Didn't find any
#       major issues" (or, with no receipt, the head's state summary has no findings), and
#       the head's state summary does not report findings;
#   (b) the user's latest decisive review on head is APPROVED and was submitted strictly
#       after the latest Codex result for head (receipt or state summary). An Approve given
#       before Codex's findings, or at the same instant, does not count (fails closed).
def codex: . == "chatgpt-codex-connector[bot]";
def short: .[0:7];
def clean_words: contains("Didn't find any major issues");
. as $in
| ($in.head | ascii_downcase) as $head
# ts: when the result was posted; uts: last change (the state summary comment is edited in place).
| [ ($in.comments[]? | {kind: "comment", id: .id, ts: (.created_at // ""), uts: (.updated_at // .created_at // ""), login: .user.login, body: (.body // "")}),
    ($in.reviews[]?  | {kind: "review", id: .id, ts: (.submitted_at // ""), uts: (.submitted_at // ""), login: .user.login, body: (.body // "")}) ]
| map(select(.login | codex)) as $mine
# Receipts: marker plus "**Reviewed commit:** `<sha>`" where sha is 7+ hex chars and a head prefix.
| [ $mine[]
    | select(.body | contains("<!-- codex-review-receipt:v1 -->"))
    | . as $m
    | (.body | capture("\\*\\*Reviewed commit:\\*\\* `(?<sha>[0-9a-fA-F]{7,40})`")? | .sha | ascii_downcase) as $s
    | select($s != null and ($head | startswith($s)))
    | $m + {sha: $s} ] as $receipts
# State summary: codex-review-state:v1 JSON with code_review.commit_sha == head and status completed.
| ([ $mine[]
    | .body | capture("codex-review-state:v1 (?<j>\\{.*?\\}\\s*\\})"; "s")?
    | .j | (try fromjson catch null)
    | select(. != null and .code_review.commit_sha != null)
    | select((.code_review.commit_sha | ascii_downcase) == $head and .code_review.status == "completed")
    | .code_review ] | first) as $state
# Latest Codex activity time for head: receipts and any state summary naming head.
| ([ ($receipts[] | .ts),
     ($mine[] | . as $m
      | (.body | capture("codex-review-state:v1 (?<j>\\{.*?\\}\\s*\\})"; "s")? | .j | (try fromjson catch null))
      | select(. != null and .code_review.commit_sha != null and (.code_review.commit_sha | ascii_downcase) == $head)
      | $m.uts) ] | max // "") as $codex_ts
| (($receipts | first | .sha) // ($state | .commit_sha)) as $hit
| (if ($in.base // "main") == "dev" then "codex-reviewed-dev" else "codex-reviewed" end) as $context
| {context: $context} + if $hit == null then
    {state: "pending", description: "head \($head | short)에 Codex 리뷰 없음 — @codex review 요청"}
  elif ($in.base // "main") != "dev" then
    {state: "success", description: "Codex가 \($hit | short)를 리뷰함"}
  elif $in.review_comments == null then
    {state: "pending", description: "인라인 지적 목록을 읽지 못함 — 다시 실행"}
  else
    ($receipts | sort_by(.ts) | last) as $latest
    | (if $latest == null then false
       else ($latest.body | clean_words)
         and ($latest.kind != "review"
              or ([ $in.review_comments[]? | select(.pull_request_review_id == $latest.id) ] | length) == 0)
       end) as $receipt_clean
    | (($state != null) and ($state.has_any_findings == true)) as $state_findings
    | ((if $latest == null then ($state.has_any_findings == false) else $receipt_clean end)
       and ($state_findings | not)) as $clean
    | ([ $in.reviews[]?
         | select(.user.login == "mzlikesb" and ((.commit_id // "") | ascii_downcase) == $head)
         | select(.state != "COMMENTED" and .state != "PENDING") ]
       | sort_by(.submitted_at // "") | last) as $user_review
    | (if $user_review.state == "APPROVED" and $codex_ts != ""
            and (($user_review.submitted_at // "") > $codex_ts)
       then "APPROVED" else null end) as $user
    | if $clean then
        {state: "success", description: "Codex가 \($hit | short)를 리뷰함 — 지적 없음"}
      elif $user == "APPROVED" then
        {state: "success", description: "Codex 지적이 있으나 사용자가 \($head | short)를 Approve함"}
      else
        {state: "pending", description: "dev: \($hit | short)에 Codex 지적 — 반영 뒤 @codex review, 또는 사용자 Approve"}
      end
  end
