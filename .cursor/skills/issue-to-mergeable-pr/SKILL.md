---
name: issue-to-mergeable-pr
description: V1.4 - Turns GitHub Issues into clean branches and PRs, with no-argument backlog orchestration across isolated worktrees when parallel agent tooling is available. Discovers active automated PR reviewers from recent PR history instead of assuming a fixed reviewer set.
compatibility: Requires git, GitHub CLI authentication, network access, and a GitHub repository with Issues and Pull Requests enabled.
hooks:
  PostToolUse:
    - matcher: "Read|Write|Edit"
      hooks:
        - type: prompt
          prompt: |
            If a file was read, written, or edited in the issue-to-mergeable-pr directory (path contains 'issue-to-mergeable-pr'), verify that history logging occurred.

            Check if History/{YYYY-MM-DD}.md exists and contains an entry for this interaction with:
            - Format: "## HH:MM - {Action Taken}"
            - One-line summary
            - Accurate timestamp (obtained via `Get-Date -Format "HH:mm"` command, never guessed)

            If history entry is missing or incomplete, provide specific feedback on what needs to be added.
            If history entry exists and is properly formatted, acknowledge completion.
  Stop:
    - matcher: "*"
      hooks:
        - type: prompt
          prompt: |
            Before stopping, if issue-to-mergeable-pr was used (check if any files in issue-to-mergeable-pr directory were modified), verify that the interaction was logged:

            1. Check if History/{YYYY-MM-DD}.md exists in issue-to-mergeable-pr directory
            2. Verify it contains an entry with format "## HH:MM - {Action Taken}" where HH:MM was obtained via `Get-Date -Format "HH:mm"` (never guessed)
            3. Ensure the entry includes a one-line summary of what was done
            4. If retrospectives are enabled, verify retrospective check was performed

            If history entry is missing:
            - Return {"decision": "block", "reason": "History entry missing. Please log this interaction to History/{YYYY-MM-DD}.md with format: ## HH:MM - {Action Taken}\n{One-line summary}"}

            If history entry exists:
            - Return {"decision": "approve"}

            Include a systemMessage with details about the history entry status.
---

# Issue to Mergeable PR

Use this skill when asked to turn a GitHub Issue into a pull request, to continue the oldest open pull request until it is ready to merge, or to work the issue backlog.

## Invocation Modes

- **Explicit issue mode**: when the user supplies an issue number, work only that issue through a focused branch, PR, verification, and review loop.
- **No-parameter backlog mode**: when the user invokes the skill without an issue number, act as a parent backlog orchestrator. Inspect the queue, deduplicate and split overlap first, then assign multiple independent issues to bounded parallel worker sessions when safe.
- **PR readiness mode**: when the user asks to continue PR readiness, work the oldest open PR or the PR they identify.

Never let a spawned worker rediscover the backlog by invoking no-parameter mode. Workers must receive an explicit issue number, branch name, and worktree path.

## Goal Start

Start by creating a Codex goal. If a goal tool is available, create the goal with the objective that matches the invocation mode. If only slash commands are available, ask the user to run the slash command exactly.

For explicit issue mode:

```text
/goal Take the specified GitHub Issue and create a branch for it, work the issue to the best of your ability and create a PR. Request the repo-appropriate automated PR reviewers, wait for feedback, address comments, and keep requesting review until you are confident all issues have been addressed and the repo's required review signals are satisfied. Make sure you have good worktree/branch hygiene. Don't start on dangling branches and clean up before and after yourself.
```

For no-parameter backlog mode:

```text
/goal Orchestrate the GitHub Issue backlog: inspect and clean up duplicate or overlapping issues first, then choose a bounded set of independent issues and assign each one to an isolated branch and worktree. Use parallel worker sessions only when their scopes are disjoint and the available tools support sub-agents. Each worker must produce a PR that is verified and reviewed according to the repo policy. Do not merge PRs. Keep worktree, branch, and issue hygiene clean.
```

Before branching, deduplicate the open issue queue and separate overlapping scope so the PR implements one clear, non-overlapping issue. The goal is achieved when the PR is ready to merge with the repo-specific automated review signal and no unresolved substantive feedback. Do not merge unless the user explicitly asks for merge.

## Preflight

1. Verify repository context: `git rev-parse --show-toplevel`, `git remote -v`, and `gh repo view`.
2. Check worktree hygiene before editing: `git status --short --branch`, `git branch --show-current`, `git worktree list`, and `git fetch --prune`.
3. Do not start from a dangling, stale, detached, or unrelated feature branch. Switch to the default branch and pull latest before creating a new branch.
4. If the main worktree has user changes, do not edit it. In explicit issue mode, stop and ask unless the changes are clearly part of the same requested issue. In backlog mode, a dirty main worktree does not block planning or isolated worker worktrees created from the fetched default branch, but the parent must not mutate the dirty main files.
5. Use the `commit-and-cleanup` skill's discipline for stale worktrees: prune registered missing worktrees, never delete ambiguous worktrees without confirmation, and leave active unmerged work alone.

## Reviewer Discovery

Do not assume which reviewers a repo uses. **Learn it from recent PR history**, then request
every automated reviewer that is currently active. Never request human reviewers — this
workflow runs unattended; rely on automated reviewers plus the repo's required status checks.

1. Sample recent review activity from roughly the last 10 closed PRs (widen to ~30 or a
   90-day window if the sample is too thin to see a pattern):

   ```bash
   gh pr list --state merged --limit 10 --json number,url
   # For each sampled PR, gather who reviewed and how:
   gh pr view <n> --json reviews,latestReviews,comments,reviewRequests,statusCheckRollup,headRefOid
   gh api repos/{owner}/{repo}/pulls/<n>/comments        # inline review comments (+ author type)
   gh api repos/{owner}/{repo}/commits/<headSha>/check-runs   # apps posting review-style checks
   ```

2. **Identify automated reviewers.** An automated reviewer is any non-human actor that leaves
   reviews, review comments, or review-style check runs. Detect them generically — do not
   hardcode a fixed product list:
   - Author type is `Bot`, or the login looks like an app (often ends in `[bot]`, or contains
     names such as `codex`, `chatgpt-codex-connector`, `coderabbitai`, `copilot`, `cursor`,
     `bugbot`, `sonar`, …). Treat any recurring `Bot`-type review author as a reviewer.
   - A GitHub App that produced review-style check-runs on recent PRs.
   - Exclude plain CI/build/lint/test status checks — those are enforced by the merge gate's
     "required checks," not as reviewers, unless they post review-style findings.

3. **Learn each reviewer's trigger** from how it behaved on the sampled PRs, and record per
   reviewer: identity/login, evidence channel (review vs check-run vs comment), and trigger:
   - **Auto** — it reviewed shortly after the PR opened or on each push with no preceding
     trigger. Needs no action; it will review on its own.
   - **Comment-triggered** — its review followed a specific PR comment. Reuse the *exact*
     trigger phrase you observe in history; discover it, don't assume it.
   - **Request-based** — it appears in `reviewRequests` / was added via the Reviewers UI.
     Request it the same way (`gh pr edit <pr> --add-reviewer <login>`).

4. **Availability = still active.** A reviewer is available if it appears in the recent sample
   and still looks installed (its app still posts checks; it wasn't removed). Request **all
   available** automated reviewers — run as many as the repo actually uses.

5. **No usable history (new repo).** Fall back to reviewers implied by installed GitHub Apps
   and branch protection:

   ```bash
   gh api repos/{owner}/{repo}/branches/{default}/protection   # required checks / reviews
   ```

   If a code-review app is installed, use it via its auto/observed trigger. If none review,
   proceed on **required status checks only** (CI-gated). Never request human reviewers.

6. Never treat an automated reviewer's plain `Comment` review as a formal approval — it is
   feedback to address. Honor whatever branch protection enforces; if the repo *requires* a
   human approval that isn't present, the PR simply isn't auto-mergeable — leave it open, never
   bypass protection.

## Issue Queue Hygiene

Before selecting or implementing the oldest issue, inspect the open issue queue for duplicates and overlapping scope. Do not create a branch until this pass is complete.

1. Fetch enough issue context to compare intent, scope, and acceptance criteria:

   ```powershell
   gh issue list --state open --limit 1000 --json number,title,createdAt,labels,body,url
   ```

2. Treat issues as duplicates when they ask for the same outcome with no meaningful difference in scope, affected area, or acceptance criteria.
3. For duplicate issues:
   - Keep the issue with the clearest actionable body. Prefer the oldest issue when clarity is equal.
   - Move any unique evidence, links, or acceptance criteria from duplicate issues into the keeper before closing them.
   - Comment on each duplicate with the keeper issue link and close it so it is removed from the active queue. Do not physically delete GitHub issues unless the user explicitly asks for deletion.
4. Treat issues as overlapping when they share one or more requirements but also contain distinct, independently useful work.
5. For overlapping issues:
   - Choose exactly one owner issue for each shared requirement. Prefer the issue where that requirement is central to the title and acceptance criteria.
   - Edit the other issue body or title to remove the shared requirement and leave only its unique scope.
   - Add a short cross-reference comment explaining where the removed common scope now lives.
6. After closing duplicates or editing overlap, re-fetch the affected issues and verify the remaining open issues are distinct before selecting the oldest issue.

## No-Parameter Backlog Orchestrator Mode

No-parameter mode is a parent orchestration workflow. Its job is to choose safe parallel work, launch or instruct workers, and integrate their results. It should not implement all issues itself unless sub-agent tooling is unavailable or parallelism is unsafe.

1. Build a live backlog inventory:

   ```powershell
   gh issue list --state open --limit 1000 --json number,title,createdAt,labels,body,url
   gh pr list --state open --limit 1000 --json number,title,createdAt,headRefName,body,url,labels
   gh repo view --json owner,name,defaultBranchRef,visibility,url
   ```

2. Run [Issue Queue Hygiene](#issue-queue-hygiene) serially before spawning workers. Do not let parallel workers close duplicate issues, rewrite overlapping scope, or independently choose owners for shared requirements.
3. Remove from the candidate pool any issue that is already covered by an open PR, blocked on external input, labeled as blocked/on-hold/wontfix, or likely to require secrets, production credentials, destructive data changes, payments, auth, crypto, schema migrations, concurrency primitives, or broad public API changes unless the user explicitly authorized that class of work.
4. Group remaining issues by likely conflict area using labels, title/body keywords, referenced paths, linked issues, and acceptance criteria. Treat unknown or broad scope as conflicting.
5. Choose the oldest actionable issue from each independent group. Prefer issues with clear acceptance criteria, low coupling, and tests that can run locally.
6. Pick a concurrency limit dynamically:
   - Default maximum is 3 workers.
   - Use 1 worker for red-risk domains, heavy overlap, unclear scope, or repositories where tests/builds cannot run independently.
   - Use 2 workers for medium overlap, expensive test suites, or broad shared modules.
   - Use up to 3 workers only when issues are clearly independent and the machine, API rate limits, and review products can handle it.
   - Never spawn more workers than independent issue groups.
7. For each chosen issue, assign a lease before spawning:
   - Issue number and URL.
   - Branch name, preferably `fix/issue-{number}-{short-slug}` for bugs and `feature/issue-{number}-{short-slug}` for features.
   - Worktree path under a sibling directory such as `{repo}.worktrees/issue-{number}-{short-slug}`.
   - Expected ownership boundaries and files or modules to avoid if known.
8. Spawn workers only if a multi-agent tool is available. With the current Codex multi-agent tools, use `multi_agent_v1.spawn_agent` with `agent_type: "worker"` and a self-contained prompt. Omit model overrides unless the user explicitly requested a different model.
9. If no sub-agent tool is available, report the planned issue batches and proceed serially with the highest-priority issue unless the user asked to wait.
10. Monitor worker results. Collect PR URLs, issue numbers, branches, worktrees, verification commands, review status, blockers, and any cleanup needed. Do not merge PRs.

Worker prompt template:

```text
You are working one assigned GitHub issue from a parent issue-to-mergeable-pr backlog orchestration run.

Repository: {owner}/{repo}
Base path: {repo-root}
Issue: #{issue-number} - {issue-title}
Assigned branch: {branch-name}
Assigned worktree: {absolute-worktree-path}
Default branch: {default-branch}
Reviewer policy: {repo-specific-reviewer-policy}

Rules:
- Work only issue #{issue-number}; do not inspect or claim the backlog.
- Create or reuse only the assigned worktree and branch.
- Start from the fetched default branch, not from a dirty main worktree.
- Do not edit files outside the issue scope except tests/docs needed for the issue.
- Do not close, rewrite, or deduplicate other issues.
- Run the repo's relevant verification and capture exact commands and outcomes.
- Commit intended changes, push the branch, create a PR that closes #{issue-number}, and request the repo-appropriate automated review.
- Address substantive automated-review feedback when available.
- Leave the PR open and do not merge.
- Final response must include issue number, PR URL, branch, worktree path, changed files, verification evidence, review state, blockers, and cleanup notes.
```

## Assigned or Oldest Issue to PR

1. If the user supplied an issue number, or a parent orchestrator assigned one, use that issue exactly. Otherwise find the oldest remaining open issue after issue queue hygiene:

   ```powershell
   gh issue list --state open --limit 1000 --json number,title,createdAt,labels,url --jq "sort_by(.createdAt)[0]"
   ```

2. Read the issue, linked discussions, nearby issues, and relevant code before branching. Re-check that the selected issue is not a duplicate and does not still overlap with another open issue.
3. Create a focused branch from the default branch, or use the branch/worktree assigned by the parent orchestrator. Prefer `fix/issue-{number}-{short-slug}` for bugs and `feature/issue-{number}-{short-slug}` for features.
4. Implement the smallest defensible change that satisfies the issue.
5. Run the repo's relevant diagnostics, tests, lint, typecheck, and build. If a check is unavailable or pre-existing failures block verification, capture exact evidence.
6. Commit only the intended changes and push the branch.
7. Create the PR with a body that links and closes the issue, summarizes verification, and calls out any residual risk:

   ```powershell
   gh pr create --fill --body "Closes #{issue-number}`n`n## Verification`n- ..."
   ```

## Review Loop

1. After the PR exists, trigger review using the reviewers found in [Reviewer Discovery](#reviewer-discovery). Request **all available** automated reviewers, each by its discovered trigger; skip any that already reviewed the current head:

   ```bash
   gh pr comment <pr-number> --body "<observed-trigger-phrase>"   # comment-triggered reviewers only
   gh pr edit <pr-number> --add-reviewer <login>                  # request-based reviewers only
   # auto reviewers need no action
   ```

2. Give asynchronous reviewers a few minutes to respond (they run out-of-band); poll status checks more frequently than reviewers:

   ```bash
   sleep 180
   ```

3. Fetch reviews, comments, checks, and merge state for the current head:

   ```bash
   gh pr view <pr-number> --json reviews,comments,reviewDecision,statusCheckRollup,mergeStateStatus,latestReviews,headRefOid
   gh api repos/{owner}/{repo}/pulls/<pr-number>/comments
   ```

4. Address each substantive review comment by changing code, adding tests, or replying with a specific reason no change is needed.
5. Follow the `pr-reviewer` skill rule: never mass-resolve review threads programmatically. Let code changes make comments outdated, or reply substantively in the thread.
6. After fixes, rerun relevant verification, commit, push, and re-request review only when there is new signal to review.
7. Use judgment with rate limits and duplicate-review refusals. Do not spam a discovered reviewer that explicitly declines, hits rate limits, or already reviewed the latest commit — record it as unavailable and move on.

## PR Merge Readiness

Once the issue work has a PR, or when asked to continue PR readiness, evaluate that PR (or take the oldest open PR):

```bash
gh pr list --state open --limit 1000 --json number,title,createdAt,url,headRefName,reviewDecision --jq "sort_by(.createdAt)[0]"
```

Verify the signal from the reviewers found in [Reviewer Discovery](#reviewer-discovery) against the current head SHA — treat bot identity by current GitHub review/comment author login, not a fixed product name. Do not treat an automated reviewer's plain `Comment` review as a branch-protection approval; use it as feedback that must be addressed alongside normal repository checks.

If a discovered reviewer has no current-head signal:

1. Re-trigger it with its discovered method.
2. Wait a few minutes (`sleep 180`).
3. Re-fetch reviews and comments.
4. Address new feedback and repeat only when useful.

The PR is ready when checks are acceptable, merge state is not blocked by unresolved known issues, substantive review feedback has been addressed, and every discovered available reviewer has a clean current-head signal — or cannot reasonably re-review because of documented availability, rate-limit, or duplicate-review limits. A reviewer that is rate-limited or unavailable after a fair attempt does not block readiness.

## Closeout

1. Leave the PR branch pushed and the PR open.
2. Do not delete the active PR branch.
3. Remove only temporary worktrees, stashes, or branches created by this run that are safe to remove. Ask before ambiguous deletion.
4. Return the main worktree to the default branch when clean and practical.
5. Save the PR URL, branch name, issue number, duplicate/overlap cleanup performed, verification commands, review state, and any blocked reviewer/rate-limit evidence.
6. Mark the Codex goal complete only when the PR is ready to merge by the criteria above. Mark blocked only after repeated inability to progress without external input.

## Avoid

- Starting from a dirty or dangling branch.
- Reusing an unrelated branch for the oldest issue.
- Implementing an issue before duplicate and overlap cleanup is complete.
- Leaving duplicate issues open after selecting a keeper.
- Letting two open issues retain the same acceptance criteria or shared scope.
- Force-pushing shared branches without explicit reason.
- Treating "PR created" as done before review feedback is checked.
- Assuming a fixed reviewer set instead of discovering it from recent PRs, or posting a trigger phrase a reviewer does not actually use.
- Requesting human reviewers in this unattended workflow, or waiting on a human signal to declare readiness.
- Treating an automated reviewer's `Comment` review as a branch-protection approval.
- Programmatically resolving review threads instead of addressing them.
- Merging the PR without explicit user instruction.
