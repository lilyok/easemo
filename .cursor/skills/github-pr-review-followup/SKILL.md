---
name: github-pr-review-followup
description: When the user asks to address GitHub PR review comments—implement fixes on the PR branch, reply on each thread with commit links or explanations, use CURSOR_REVIEW_PAT for API comments, and resolve review threads.
---

# GitHub PR review follow-up

Use this workflow when asked to **address PR reviews**, **reply to review comments**, or **resolve conversation threads** on GitHub (for example: “address reviews on PR #N”).

## Branch and scope

1. **Do not open a new feature branch** unless the user explicitly asks. Work on the **PR’s head branch** (the branch the pull request is from), not `main`.
2. Fetch the PR head if needed: `gh pr checkout <N>` or `git fetch origin pull/<N>/head` and check out that ref.
3. Implement only what the reviews require; keep commits focused.

## Decide: fix vs decline

For **each** inline review thread (and any top-level review summary if the user cares):

- **Relevant and you agree:** implement the change, commit, push to the **same PR branch**.
- **Relevant but wrong / out of scope / product decision:** do **not** change code (or change minimally). Reply explaining **why** it will not be fixed or how it is handled elsewhere.
- **Stale / already fixed:** reply with the **commit SHA** (or link) where it was fixed, or a one-line clarification.

## Answers on the review threads (required)

Every thread should get a **direct reply** on GitHub so reviewers see closure next to the diff.

### Use `CURSOR_REVIEW_PAT` for comments

The default `gh` / integration token often returns **403 Resource not accessible by integration** for `POST /repos/{owner}/{repo}/pulls/comments` (creating replies on review comments). **Always prefer the PAT** when it is set:

```bash
export GH_TOKEN="$CURSOR_REVIEW_PAT"
```

Then use `gh api` (or `gh pr comment` for general PR comments). Replies to inline comments use the REST API with `in_reply_to` set to the **parent comment’s numeric `id`** (not the thread id).

Example (replace owner, repo, numbers, SHA, and body):

```bash
export GH_TOKEN="${CURSOR_REVIEW_PAT:?set CURSOR_REVIEW_PAT for review replies}"
gh api repos/OWNER/REPO/pulls/1/comments \
  -f body="Fixed in \`abc1234\`: short description of the change." \
  -F in_reply_to=3180674198
```

**Body conventions**

- **Fixed:** start with `Fixed in \`<full-or-short-sha>\`:` then a concise what changed. Optionally add a GitHub compare link:
  - `https://github.com/OWNER/REPO/commit/<sha>`
  - or `https://github.com/OWNER/REPO/compare/<before>...<after>` when multiple commits matter.
- **Won’t fix / not applicable:** start with **Won’t fix** or **N/A** and give a clear, respectful reason (spec, risk, duplicate, by design).
- Keep each reply short; point to commit or file if useful.

### If `CURSOR_REVIEW_PAT` is unset

Tell the user the PAT is missing, summarize answers in the PR description, and still resolve threads if the available token allows. Do not claim you posted inline replies if the API failed.

## Resolve threads

After posting the reply (or if the reply is impossible without the PAT), **resolve** each review thread so the PR UI shows closed discussions.

1. List threads (GraphQL):

```graphql
query {
  repository(owner: "OWNER", name: "REPO") {
    pullRequest(number: N) {
      reviewThreads(first: 50) {
        nodes { id isResolved }
      }
    }
  }
}
```

2. Resolve each unresolved thread:

```bash
gh api graphql -f query='
  mutation($id: ID!) {
    resolveReviewThread(input: { threadId: $id }) {
      thread { isResolved }
    }
  }
' -F id=PRRT_kwD...
```

Use the `id` values from the query (`PullRequestReviewThread` node ids).

## Order of operations

1. Check out PR branch → implement fixes → **commit** → **push** (`git push -u origin <branch>`).
2. Collect each review comment’s **database id** and thread state from `gh api repos/OWNER/REPO/pulls/<N>/comments` or the GraphQL `reviewThreads` query.
3. `export GH_TOKEN="$CURSOR_REVIEW_PAT"` → post one reply per thread via REST `in_reply_to`.
4. Resolve threads with `resolveReviewThread`.
5. Optionally update the PR body with a short “Review follow-up” section as backup context (especially if a comment could not be posted).

## Verification

- Re-read the PR’s “Files changed” for your edits.
- If the repo has CI/tests the agent can run, run them before the final push; otherwise note what the user should run locally.
