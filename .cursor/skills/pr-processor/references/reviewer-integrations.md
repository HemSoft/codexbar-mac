# Reviewer integration discovery

Reviewer names, GitHub identities, trigger phrases, and check names vary by installation and can change. Treat the table as discovery hints, not universal configuration. Verify behavior from repository instructions, recent successful PRs, installed GitHub Apps, `.github/workflows`, branch rules, or the integration's current documentation before posting a request.

| Reviewer family | Common evidence | Possible request mechanism | Discovery notes |
| --- | --- | --- | --- |
| OpenAI Codex | Reviews or comments from an identity such as `chatgpt-codex-connector` | A PR comment such as `@codex review`, or automatic review | Do not route Codex through a Copilot reviewer-login path unless the live repository explicitly supports it |
| CodeRabbit | Review threads, summary comments, and a CodeRabbit check | A comment such as `@coderabbitai review`, or automatic review | Confirm whether incremental reviews run automatically after pushes |
| Cursor Bugbot | Review comments or a Cursor/Bugbot check | A comment such as `cursor review` or `bugbot run`, or automatic review | GitHub author names and enabled commands can vary by installation |
| GitHub Copilot | Requested reviewer state, review comments, or a Copilot check | Native GitHub reviewer request when enabled | Discover the exact reviewer login from the repository or a prior PR before using `--github-reviewer` |
| Claude | App comments, workflow results, or review threads | Repository-specific mention, command, workflow dispatch, or automatic review | There is no assumption here that every Claude integration supports PR review or the same trigger |
| OpenCode | Custom workflow, bot comment, or check | Repository-specific automation | Treat it as a custom reviewer unless the repository documents a stable integration |
| Human reviewer | GitHub review and review threads | Native GitHub reviewer request | Respect CODEOWNERS, team routing, and repository ownership rules |

## Build reviewer patterns

Prefer exact, case-insensitive author logins when known:

```bash
--reviewer '^chatgpt-codex-connector$' \
--reviewer '^coderabbitai$'
```

Use broader patterns only during discovery:

```bash
--reviewer 'cursor|bugbot|copilot|claude|codex|coderabbit|opencode'
```

Review the helper's `matchedReviewerAuthors` before relying on a broad match. Narrow the pattern if it captures unrelated users.

## Determine freshness

When `gh x pr` is installed, run it before constructing aggregate comment state manually. Use the matching record's `comments`, `aiReview`, and `aiClean` fields to determine overall addressed/resolved status, then use GraphQL thread data to inspect individual reviewer findings and resolve explicit thread IDs. If `gh x pr` is unavailable or cannot find the PR, record that fact and use the GraphQL fallback.

- Review objects can be anchored to a commit SHA; require it to equal the current PR head for a current-head review.
- Review-thread comments may expose the parent review commit. Revalidate old-SHA findings against current code before resolving.
- Top-level PR comments are not inherently commit-anchored. A post-push timestamp is useful but insufficient by itself; read the comment and confirm it refers to the latest review run.
- Check runs must belong to the current head. Re-read `statusCheckRollup` after each push.
- Automatic reviewers may skip draft PRs, forks, untrusted contributors, or paths excluded by configuration. Report those conditions rather than fabricating a clean signal.

## Select request type

Use a trigger comment when the integration documents a PR command. Use a native GitHub reviewer request for humans or integrations exposed as requestable reviewers. Rely on automatic review only after verifying it is enabled and queued for the current head.

Never guess a trigger phrase on a live PR. An incorrect guess creates noise and may mention an unrelated account.
