#!/usr/bin/env bash
# Checks guard-bash.sh against a throwaway repo with explicit branch state and a fake agent
# gh config, so the result does not depend on this checkout, CI, or the real accounts.
set -uo pipefail
guard="$(cd "$(dirname "$0")" && pwd -P)/guard-bash.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

# Fake agent session: gh config for the agent account, git credentials from gh, stub gh.
agent_cfg="$tmp/gh-agent"
mkdir -p "$agent_cfg" "$tmp/bin" "$tmp/gh-user"
printf 'github.com:\n    users:\n        chillingdaisy-worker1:\n    user: chillingdaisy-worker1\n' >"$agent_cfg/hosts.yml"
printf 'github.com:\n    users:\n        mzlikesb:\n    user: mzlikesb\n' >"$tmp/gh-user/hosts.yml"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
# `gh pr view <n> --json labels -q ...`: PR 2 is large, anything else small. Without a
# number, the PR of the current directory: a directory named "large" holds a large PR.
if [ "$1 $2" = "pr view" ]; then
  case "${3:-}" in
    2) echo "size:large,stage:dev" ;;
    --json) case "$(basename "$PWD")" in large) echo "size:large,stage:dev" ;; *) echo "size:small,stage:code-review" ;; esac ;;
    *) echo "size:small,stage:code-review" ;;
  esac
fi
EOF
mkdir -p "$tmp/small" "$tmp/large"
chmod +x "$tmp/bin/gh"
agent_env=(GH_CONFIG_DIR="$agent_cfg" GIT_CONFIG_COUNT=2
  GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0=
  GIT_CONFIG_KEY_1=credential.https://github.com.helper "GIT_CONFIG_VALUE_1=!gh auth git-credential"
  PATH="$tmp/bin:$PATH")

run() { # run <env-mode> <cwd> <command>
  local mode=$1 dir=$2 cmd=$3 input
  input=$(jq -n --arg c "$cmd" --arg d "$dir" '{tool_input:{command:$c},cwd:$d}')
  case "$mode" in
    agent) env -u GH_CONFIG_DIR -u GIT_CONFIG_COUNT "${agent_env[@]}" "$guard" <<<"$input" >/dev/null 2>&1 ;;
    bare) env -u GH_CONFIG_DIR -u GIT_CONFIG_COUNT PATH="$tmp/bin:$PATH" "$guard" <<<"$input" >/dev/null 2>&1 ;;
    user) env -u GIT_CONFIG_COUNT GH_CONFIG_DIR="$tmp/gh-user" PATH="$tmp/bin:$PATH" "$guard" <<<"$input" >/dev/null 2>&1 ;;
    # Agent settings, but a token inherited from the parent environment.
    agent-token) env -u GH_CONFIG_DIR -u GIT_CONFIG_COUNT "${agent_env[@]}" GH_TOKEN=inherited "$guard" <<<"$input" >/dev/null 2>&1 ;;
    agent-ghtoken) env -u GH_CONFIG_DIR -u GIT_CONFIG_COUNT "${agent_env[@]}" GITHUB_TOKEN=inherited "$guard" <<<"$input" >/dev/null 2>&1 ;;
  esac
}
expect() { # expect <exit> <cwd> <command> [env-mode=agent]
  local want=$1 dir=$2 cmd=$3 mode=${4:-agent} got
  run "$mode" "$dir" "$cmd"
  got=$?
  if [ "$got" = "$want" ]; then
    echo "ok   [${got}] (${mode}) ${cmd}"
  else
    echo "FAIL [${got} != ${want}] (${mode}) ${cmd} (${dir})"
    fail=1
  fi
}

# Main checkout on a feature branch, plus a worktree on main.
main_dir="$tmp/main"
git init -q -b main "$main_dir"
git -C "$main_dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$main_dir" switch -q -c feat/x
wt="$tmp/wt"
git -C "$main_dir" worktree add -q "$wt" main
main_dir=$(cd "$main_dir" && pwd -P)
wt=$(cd "$wt" && pwd -P)

# Reads are always fine.
expect 0 "$main_dir" "git status"
expect 0 "$main_dir" "git status" bare
expect 0 "$main_dir" "gh pr view 1 --comments" bare
expect 0 "$main_dir" "gh api repos/o/r/issues/4/comments -q '.[] | select(.body|startswith(\"## neon review\"))'"
expect 0 "$main_dir" "gh auth status"

# Fail closed: writes need the agent session settings.
expect 0 "$main_dir" "git push -u origin feat/x"
expect 2 "$main_dir" "git push -u origin feat/x" bare
expect 2 "$main_dir" "git push -u origin feat/x" user
expect 0 "$main_dir" "gh pr create --draft --title x"
expect 2 "$main_dir" "gh pr create --draft --title x" bare
expect 2 "$main_dir" "gh pr comment 1 --body hi" user
expect 2 "$main_dir" "gh api repos/o/r/issues/1/comments -f body=hi" bare
expect 2 "$main_dir" "gh api -X PATCH repos/o/r/issues/1 -F state=closed" bare
expect 0 "$main_dir" "gh api repos/o/r/pulls/1" bare
# An inherited token overrides the stored login, so writes are blocked even with agent settings.
expect 2 "$main_dir" "gh pr review 4 --approve" agent-token
expect 2 "$main_dir" "git push -u origin feat/x" agent-token
expect 2 "$main_dir" "gh pr comment 1 --body hi" agent-ghtoken
# With an inherited token no gh command runs at all, reads included.
expect 2 "$main_dir" "gh pr view 4" agent-token
expect 2 "$main_dir" "gh -R mzlikesb/outpost pr review 4 --approve" agent-token
expect 0 "$main_dir" "git status" agent-token
# Inherited flags before the subcommand do not hide a write.
expect 2 "$main_dir" "gh -R mzlikesb/outpost pr review 4 --approve" bare
expect 2 "$main_dir" "gh --repo=mzlikesb/outpost pr comment 4 --body hi" bare
expect 0 "$main_dir" "gh -R mzlikesb/outpost pr review 4 --approve"
expect 0 "$main_dir" "gh -R mzlikesb/outpost pr view 4" bare
# Write shapes the detector must still see (QA 002).
expect 2 "$main_dir" "gh api --method=DELETE repos/o/r/issues/comments/1" bare
expect 2 "$main_dir" "gh api -fbody=hi repos/o/r/issues/1/comments" bare
expect 0 "$main_dir" "gh api -X GET repos/o/r/issues -f state=open" bare
expect 2 "$main_dir" "git -c core.x=y push" bare
expect 2 "$main_dir" "git --no-pager push" bare
expect 2 "$main_dir" "(gh pr create --title x)" bare
expect 2 "$main_dir" "{ gh pr create --title x; }" bare

# Identity: no switching accounts or overriding the variables that pick them.
expect 2 "$main_dir" "GH_CONFIG_DIR=/tmp/x gh pr create --title x"
expect 2 "$main_dir" "export GH_CONFIG_DIR=/tmp/x"
expect 2 "$main_dir" "unset GH_CONFIG_DIR && gh pr comment 1 --body hi"
expect 2 "$main_dir" "GIT_CONFIG_COUNT=0 git push"
expect 2 "$main_dir" "GH_TOKEN=abc gh pr create --title x"
expect 2 "$main_dir" "env -u GH_CONFIG_DIR gh pr comment 1 --body hi"
expect 2 "$main_dir" "gh auth switch --user mzlikesb"
expect 2 "$main_dir" "gh auth token"
expect 2 "$main_dir" "git -c credential.helper= push"
expect 2 "$main_dir" "export A=1 GH_CONFIG_DIR=/tmp/x"
expect 2 "$main_dir" "declare -x GH_CONFIG_DIR=/tmp/x"
expect 2 "$main_dir" "FOO=\"a b\" GH_TOKEN=x gh pr create --title x"
expect 2 "$main_dir" "gh auth status --show-token"
expect 2 "$main_dir" "gh auth git-credential get"
# Other leading assignments are fine and the command behind them is still recognized.
expect 0 "$main_dir" "FOO=bar gh pr create --title x"
expect 2 "$main_dir" "FOO=bar git push --force"

# neon: posting only through the script, reading is fine.
expect 2 "$main_dir" "gh pr comment 1 --body '## neon review · abc'"
expect 2 "$main_dir" "gh api repos/o/r/issues/1/comments -f body='## neon review'"
expect 0 "$main_dir" "scripts/neon-review.sh 1 docs/plans/002-identity.md"
expect 0 "$main_dir" "git commit -m 'apply neon review' && git push -q"
expect 0 "$main_dir" "gh pr comment 1 --body 'neon review 지적을 반영했습니다'"

# Merges: agents only queue small PRs.
expect 0 "$main_dir" "gh pr merge 1 --auto --squash"
expect 2 "$main_dir" "gh pr merge 2 --auto --squash"
expect 0 "$main_dir" "gh pr merge 2 --disable-auto"
expect 2 "$main_dir" "gh pr merge 1 --squash"
expect 2 "$main_dir" "gh pr merge 1 --admin --squash"
expect 2 "$main_dir" "gh pr merge 1 --auto && gh pr merge 2 --auto"
# Each merge is checked in its own directory.
expect 0 "$tmp/small" "gh pr merge --auto --squash"
expect 2 "$tmp/large" "gh pr merge --auto --squash"
expect 2 "$tmp/small" "gh pr merge --auto --squash && cd $tmp/large && gh pr merge --auto --squash"
expect 0 "$tmp/large" "cd $tmp/small && gh pr merge --auto --squash"
expect 2 "$main_dir" "git -c core.x=y push --force"

# Push shape.
expect 2 "$main_dir" "git push --force"
expect 2 "$main_dir" "git push origin main"
expect 2 "$main_dir" "git push -uf origin feat/x"
expect 2 "$main_dir" "git push origin HEAD:main"
expect 2 "$main_dir" "git push origin HEAD:refs/heads/main"
expect 0 "$main_dir" "git push origin main-xyz"
# dev (integration branch) is guarded like main.
expect 2 "$main_dir" "git push origin dev"
expect 2 "$main_dir" "git push origin HEAD:dev"
expect 2 "$main_dir" "git push origin HEAD:refs/heads/dev"
expect 2 "$main_dir" "git push -u origin main:dev"
expect 0 "$main_dir" "git push origin dev-xyz"
expect 0 "$main_dir" "git push origin chore/010-dev-branch"
expect 0 "$main_dir" "git push --follow-tags origin feat/x"
expect 0 "$main_dir" "git commit -m 'catch -uf pushes to main' && git push -q"
expect 2 "$main_dir" "git add . && git push -f"

# Branches in the main checkout.
expect 0 "$main_dir" "git switch main"
expect 0 "$main_dir" "git checkout main"
expect 2 "$main_dir" "git switch feat/y"
expect 2 "$main_dir" "git checkout feat/y"
expect 2 "$main_dir" "git checkout -b feat/y"
expect 0 "$main_dir" "git checkout -- src/App.tsx"
expect 0 "$main_dir" "git worktree add ../outpost-x -b feat/x origin/main"

# Worktree on main: switching is allowed there, committing/pushing on main is not.
expect 2 "$wt" "git commit -m x"
expect 2 "$wt" "git push"
expect 0 "$wt" "git switch -c feat/y"
expect 0 "$wt" "git checkout feat/y"

# Worktree on dev: same as main.
git -C "$main_dir" branch -q dev main
devwt="$tmp/devwt"
git -C "$main_dir" worktree add -q "$devwt" dev
devwt=$(cd "$devwt" && pwd -P)
expect 2 "$devwt" "git commit -m x"
expect 2 "$devwt" "git push"

# The real directory is followed through `cd X &&` and `git -C X`.
expect 0 "$main_dir" "cd $wt && git switch -c feat/z"
expect 2 "$main_dir" "cd $wt && git commit -m x"
expect 2 "$main_dir" "git -C $wt commit -m x"
expect 2 "$wt" "cd $main_dir && git switch feat/y"

# Secrets.
expect 2 "$main_dir" "git add -f .dev.vars"
expect 0 "$main_dir" "git add .dev.vars.example"
touch "$main_dir/.dev.vars"
git -C "$main_dir" add -f .dev.vars
expect 2 "$main_dir" "git commit -m x"
expect 2 "$wt" "cd $main_dir && git commit -m x"

exit $fail
