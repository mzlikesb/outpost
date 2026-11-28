#!/usr/bin/env bash
# .github/CODEOWNERS and the AGENTS.md "보호 경로" list must name the same paths, all owned
# by the user, and every tracked root entry must be either protected or listed as unprotected
# below (plan 010 B). Also checks the comparison itself on broken fixtures.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Root entries that stay editable without the user's Approve. A new root file must go here
# or into the protected list (CODEOWNERS + AGENTS.md).
UNPROTECTED='.dev.vars.example .gitignore CREDITS.md README.md index.html docs/ public/ shared/ src/ worker/'

owners_paths() { grep -vE '^\s*(#|$)' "$1" | awk '{print $1}' | LC_ALL=C sort; }
owners_bad() { grep -vE '^\s*(#|$)' "$1" | awk 'NF != 2 || $2 != "@mzlikesb"'; }
agents_paths() {
  sed -n '/<!-- protected-paths:start -->/,/<!-- protected-paths:end -->/p' "$1" |
    sed -nE 's/^- `([^`]+)`.*$/\1/p' | LC_ALL=C sort
}
same_lists() { # same_lists <codeowners> <agents.md>
  local a b
  a=$(owners_paths "$1"); b=$(agents_paths "$2")
  [ -n "$a" ] && [ "$a" = "$b" ]
}
covered() { # covered <root entry, dirs end in />: protected pattern or unprotected list
  local e=$1 p g
  for g in $UNPROTECTED; do [ "$e" = "$g" ] && return 0; done
  while IFS= read -r p; do
    g=${p#/}; g=${g#\*\*/}
    # shellcheck disable=SC2053 # glob match on purpose
    [[ $e == $g ]] && return 0
  done < <(owners_paths .github/CODEOWNERS)
  return 1
}
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

if same_lists .github/CODEOWNERS AGENTS.md; then ok "CODEOWNERS = AGENTS.md 보호 경로"
else bad "CODEOWNERS and AGENTS.md differ:"; diff <(owners_paths .github/CODEOWNERS) <(agents_paths AGENTS.md); fi

b=$(owners_bad .github/CODEOWNERS)
if [ -z "$b" ]; then ok "every rule is owned by @mzlikesb only"; else bad "rules with other owners: $b"; fi

missing=""
while IFS= read -r e; do
  covered "$e" || missing="$missing $e"
done < <(git ls-files | awk -F/ '{ if (NF > 1) print $1 "/"; else print $1 }' | LC_ALL=C sort -u)
if [ -z "$missing" ]; then ok "every tracked root entry is protected or listed as unprotected"
else bad "root entries in neither list:$missing"; fi

for must in .github/ scripts/ AGENTS.md package.json tsconfig.json vite.config.ts vitest.config.ts wrangler.jsonc .oxlintrc.json .prettierrc.json .nvmrc; do
  covered "$must" || bad "$must is not protected"
done
ok "harness and build config are protected"
for p in '**/.oxlintrc*' '**/.prettierrc*' '**/.prettierignore'; do
  owners_paths .github/CODEOWNERS | grep -qxF "$p" || bad "$p is not protected at any depth"
done
ok "lint/format config is protected in subfolders too"

# The comparison itself catches drift.
cp .github/CODEOWNERS "$tmp/CO"; cp AGENTS.md "$tmp/A.md"
grep -v '^/GEMINI.md ' .github/CODEOWNERS >"$tmp/CO-missing"
if same_lists "$tmp/CO-missing" "$tmp/A.md"; then bad "self-test: missing CODEOWNERS line not caught"; else ok "self-test: missing CODEOWNERS line"; fi
sed 's#^- `/.nvmrc`#- `/.nvmrc-x`#' AGENTS.md >"$tmp/A-renamed.md"
if same_lists "$tmp/CO" "$tmp/A-renamed.md"; then bad "self-test: renamed AGENTS.md entry not caught"; else ok "self-test: renamed AGENTS.md entry"; fi
printf '/x/ @mzlikesb someone\n/y/ @other\n' >"$tmp/CO-owners"
if [ "$(owners_bad "$tmp/CO-owners" | wc -l | tr -d ' ')" = 2 ]; then ok "self-test: wrong owners"; else bad "self-test: wrong owners not caught"; fi
if same_lists /dev/null /dev/null; then bad "self-test: empty lists pass"; else ok "self-test: empty lists fail"; fi

exit "$fail"
