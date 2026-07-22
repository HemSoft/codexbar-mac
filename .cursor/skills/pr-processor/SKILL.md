---
name: pr-processor
description: Process an existing GitHub pull request through configurable human or automated review until actionable feedback is addressed, handled threads are explicitly resolved, current-head reviewer signals are clean, and normal PR checks pass. Use for reviewer loops involving Codex, Cursor Bugbot, GitHub Copilot, Claude, CodeRabbit, OpenCode, custom review bots, or human reviewers without assuming any one agent, trigger phrase, or approval mechanism.
---

# PR Processor

Process an existing GitHub PR with any selected set of reviewers. Keep the workflow agent-neutral: discover each reviewer's live GitHub identity and trigger mechanism, evaluate evidence against the current head SHA, and never equate a bot comment with a formal approval unless GitHub reports one.

## Inputs

Accept one of:

- A PR URL such as `https://github.com/OWNER/REPO/pull/123`.
- `OWNER/REPO` plus a PR number.
- A checkout where `gh pr view` resolves the current PR.

Also determine the selected reviewers. Use explicit user instructions first, then repository instructions, existing PR activity, installed GitHub Apps, checks, and workflows. If no reviewer set is specified, process all actionable review feedback already present and ask for new reviews only through mechanisms verified for that repository.

Read [reviewer-integrations.md](references/reviewer-integrations.md) only when reviewer identity or trigger discovery is needed.

## Portability Contract

- Use standard Git, GitHub CLI, the optional `gh x pr` extension when available, and the portable Python helpers bundled with this skill.
- Do not depend on Codex-only tools, model names, hooks, history folders, or approval semantics.
- Use the host agent's normal file-editing and test-running capabilities.
- Follow `AGENTS.md`, `CLAUDE.md`, repository contribution guidance, and narrower scoped instructions when present.
- Preserve unrelated worktree changes and user commits.
- Do not merge unless the user explicitly requests it.

## Preflight

1. Verify authentication and resolve the PR:

   ```bash
   gh auth status
   gh pr view <url-or-number> --json number,url,headRefName,headRefOid,baseRefName,isDraft,state,mergeStateStatus
   ```

2. Inspect local state before editing:

   ```bash
   git status --short --branch
   git branch --show-current
   git worktree list
   ```

3. Check out the PR branch or an isolated worktree when necessary. Stop before overwriting unrelated changes.
4. Record the current head SHA. Treat feedback on another SHA as stale until revalidated against current code.
5. Identify reviewer evidence channels for each selected reviewer: review, review thread, PR comment, check run, workflow, or requested-review state.

## Inspect Review State

Prefer `gh x pr` for aggregate comment-resolution and AI-review state when the command is available:

```bash
gh x pr --help
gh x pr list -R OWNER/REPO -s open --json
```

Use its matching PR record—especially `comments`, `aiReview`, and `aiClean`—as the primary aggregate signal for whether review comments are addressed and resolved. Still use GitHub GraphQL for individual comment bodies, reviewer filtering, current-head review SHAs, and thread IDs. Do not bypass `gh x pr` in favor of a hand-built aggregate when the extension is available and returns the PR.

Use the state helper with repeatable case-insensitive reviewer patterns:

```bash
python3 <skill-dir>/scripts/get_pr_review_state.py \
  --url https://github.com/OWNER/REPO/pull/123 \
  --reviewer 'cursor|bugbot' \
  --reviewer 'copilot'
```

Omit `--reviewer` to return activity from every author. Add `--exclude-author` for known service accounts that are irrelevant. The helper automatically detects and queries `gh x pr` first, then supplements it with GitHub CLI and GraphQL data. The output includes `commentResolutionSource`, the `ghXPr` aggregate when available, the PR head, checks, matched authors, review commit SHAs, top-level comments, and unresolved selected-reviewer threads.

The helper reports evidence; it does not decide whether prose feedback is actionable. Read the underlying comments and code before classifying them. If the output says a collection was truncated, query the remaining GitHub GraphQL pages before declaring completion.

## Classify Feedback

Classify every unresolved selected-reviewer thread and every current review signal:

| Feedback | Required response |
| --- | --- |
| Correct bug, security, test, or maintainability issue | Fix the smallest defensible scope and add or update tests when practical |
| Valid but outside the PR's scope | Reply with a specific reason, ownership boundary, and residual risk |
| Incorrect because of repository context | Reply with concrete code, test, or documentation evidence |
| Stale after later code changes | Re-check against the current diff before resolving |
| Duplicate | Address once and reference the shared fix in each thread |
| Ambiguous | Investigate first; ask the user only if the answer changes product behavior or scope materially |

Do not mass-resolve feedback and do not dismiss a reviewer solely because it is automated.

## Implement and Verify

1. Make the smallest coherent change that addresses the accepted feedback.
2. Run repository-prescribed tests, lint, type checking, builds, and PR-specific diagnostics.
3. Inspect the final diff for accidental files, generated noise, secrets, or unrelated changes.
4. Commit and push only intended changes when the requested workflow includes updating the PR.
5. Re-read the PR head SHA after every push.

## Resolve Addressed Threads

Resolve a thread only after its feedback is fixed, documented as out of scope, disproven with evidence, or superseded. An outdated thread with `isResolved: false` is still unresolved.

Preview explicit resolutions:

```bash
python3 <skill-dir>/scripts/resolve_review_threads.py \
  --thread-id PRRT_example1 \
  --thread-id PRRT_example2 \
  --dry-run
```

Run again without `--dry-run` only for the reviewed IDs, then re-query state and require `isResolved: true`.

## Request Fresh Reviews

Reviewer requests are external writes. Use them when the user's PR-processing request includes iterating to a clean review state, or after obtaining any separately required authorization.

The request helper has no vendor defaults. Pass only trigger comments or GitHub reviewer logins verified for the repository:

```bash
python3 <skill-dir>/scripts/request_pr_reviews.py \
  --url https://github.com/OWNER/REPO/pull/123 \
  --comment '@codex review' \
  --comment 'cursor review' \
  --github-reviewer some-reviewer-login \
  --dry-run
```

Inspect the dry-run plan, then omit `--dry-run` to post. Do not send duplicate requests when an automatic review is already queued for the current head.

## Iterate

Repeat this loop until the target state is reached:

1. Fetch current PR head, checks, reviews, comments, and unresolved threads.
2. Triage all selected-reviewer feedback.
3. Implement accepted changes and run proportional verification.
4. Push the intended update.
5. Resolve only addressed threads and verify their resolved state.
6. Request or await fresh current-head reviews through verified mechanisms.
7. Poll checks more frequently than review bots; allow asynchronous reviewers several minutes before concluding they did not respond.
8. Repeat when new actionable feedback appears.

Avoid an infinite reviewer disagreement loop. When two reviewers conflict, prefer repository requirements, executable tests, authoritative docs, and explicit user product decisions. Document the conflict and chosen evidence.

## Ready State

Declare the PR ready only when all applicable conditions hold:

- The reported PR head SHA is the current remote head.
- Every selected reviewer has a clean signal for the current head, or a documented repository-specific reason why no current-head signal is available.
- No actionable selected-reviewer feedback remains.
- Every handled review thread is explicitly resolved in GitHub.
- When `gh x pr` is available, its matching PR record reports clean aggregate AI review and fully addressed/resolved comments; explain any unavailable or non-applicable field.
- Required status checks pass for the current head.
- Merge state is acceptable and no known conflict remains.

Interpret reviewer signals according to their actual GitHub representation:

| Signal | Interpretation |
| --- | --- |
| GitHub `APPROVED` review on current head | Formal approval from that reviewer |
| Successful dedicated reviewer check on current head | Clean automated check, not necessarily branch-protection approval |
| Current-head review/comment with no actionable findings | Clean feedback signal, not necessarily approval |
| Old-SHA review or pre-push comment | Historical evidence only |
| Outdated but unresolved thread | Incomplete until explicitly handled and resolved |
| `gh x pr` reports `aiClean: true` and all comments addressed | Preferred aggregate clean signal; retain GraphQL evidence for individual selected-reviewer threads |

## Closeout

Report:

1. PR URL and final head SHA.
2. Selected reviewers and the exact current-head signal observed for each.
3. Remaining unresolved actionable and thread counts.
4. Commands run and exact check results.
5. Any unavailable integration, permission failure, rate limit, timeout, or reviewer disagreement.

Never claim approval, reviewer coverage, or merge readiness beyond the evidence GitHub exposes.
