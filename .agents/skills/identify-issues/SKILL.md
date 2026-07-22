---
name: identify-issues
description: Identify high-confidence, actionable repository issues without duplicating existing GitHub issues or pull requests. Use for scheduled repository issue discovery and backlog gap analysis.
license: MIT
compatibility: Requires read access to the repository and its GitHub issues and pull requests.
---

# Identify Issues

Find concrete repository problems or missing tracked work, then produce
implementation-ready issue drafts. Prefer a small number of well-supported
findings over speculative or duplicate backlog.

## Operating Rules

- Read the repository's `AGENTS.md` and follow its project-specific rules.
- Treat source code and current behavior as authoritative when documentation
  disagrees.
- Inspect open issues and pull requests before proposing anything.
- Do not report work already implemented, already tracked, or actively covered
  by a pull request.
- Do not expose credentials, tokens, Keychain values, or local auth files.
- Do not claim runtime verification that the current environment cannot
  perform. Label static-analysis findings as such.
- Zero findings is a valid result. Never create filler issues to satisfy a
  scheduled run.
- Do not modify product code while identifying issues. Implementation belongs
  in a separate task tied to an accepted issue.

## Workflow

### 1. Establish Repository Context

Read:

- `AGENTS.md`
- `README.md`
- `CHANGELOG.md`
- relevant source and tests
- recent commits
- all open GitHub issues
- all open pull requests

Note platform and testing constraints before investigating. If reference
repositories named by `AGENTS.md` are available, use them as behavioral
references, not as code to copy blindly.

### 2. Build a Coverage Map

Compare documented and implemented behavior across:

- provider request, response parsing, and error handling
- credential discovery, refresh, expiry, and fallback paths
- caching, stale-data preservation, history, and alerts
- settings persistence and account-type branching
- loading, empty, incomplete, disabled, and failure UI states
- release, signing, CI, and repository configuration
- tests versus meaningful control-flow and parsing branches

Also inspect TODO/FIXME markers and recent high-churn code, but do not treat a
marker or missing test alone as proof of a product issue.

### 3. Gather Evidence

For each candidate:

1. Trace the complete code path.
2. Identify the exact files, symbols, and conditions involved.
3. Determine the user-visible or maintainer-visible impact.
4. Check whether tests or guards already cover the condition.
5. Search issues and pull requests using multiple relevant terms.
6. Reject the candidate if the evidence is ambiguous or the expected behavior
   requires a product decision not documented in the repository.

Prefer findings that are independently verifiable from the repository. On a
platform-incompatible Cloud VM, provide a precise macOS reproduction or
verification plan instead of pretending to run the app.

### 4. Rank and Select

Rank candidates by:

1. correctness, security, or data-loss risk
2. user impact and likelihood
3. confidence in the evidence
4. implementation readiness

Select at most three findings per run. Every selected finding must include:

- concrete evidence
- a distinct user or developer impact
- a scoped proposal
- testable acceptance criteria
- a duplicate check

### 5. Produce Issue Drafts

Use this structure:

```markdown
## Overview
Describe the observed problem and affected users in 2-3 sentences.

## Evidence
- `path/to/File.swift`: `SymbolName` does or omits the relevant behavior.
- Explain the exact triggering condition and resulting behavior.

## Proposed Change
- Describe the smallest complete fix.
- Call out compatibility or migration constraints.

## Acceptance Criteria
- [ ] State externally observable behavior.
- [ ] Cover the important edge or failure case.
- [ ] Add or update focused automated tests.
- [ ] Verify on macOS when the behavior depends on macOS frameworks.

## Duplicate Check
No matching open issue or pull request found. Searches: `term one`,
`term two`.
```

Suggest an existing repository label only after confirming it exists.

### 6. Publish Only When Authorized

- If the task explicitly authorizes creating GitHub issues and a dedicated,
  writable issue tool is available, create the selected issues and return
  their URLs.
- If GitHub access is read-only, no issue tool is available, or creation was
  not explicitly authorized, return the drafts without attempting a write.
- Never bypass a read-only policy with direct API calls or alternate
  credentials.

## Final Report

Return:

1. issues created, with URLs; or issue drafts when creation is unavailable
2. candidates rejected as duplicates, with the matching issue or PR
3. verification limitations
4. `No high-confidence new issues found` when nothing meets the bar
