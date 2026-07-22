#!/usr/bin/env python3
"""Return reviewer-neutral GitHub pull-request review state as JSON."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from typing import Any, Iterable

from github_pr import find_gh, pr_view, resolve_pr_identity, run_gh, run_gh_json


GRAPHQL_QUERY = r"""
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviews(last: 100) {
        totalCount
        nodes {
          author { login }
          state
          body
          submittedAt
          url
          commit { oid }
        }
      }
      comments(last: 100) {
        totalCount
        nodes {
          author { login }
          body
          createdAt
          url
        }
      }
      reviewThreads(first: 100) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 100) {
            totalCount
            pageInfo { hasNextPage endCursor }
            nodes {
              author { login }
              body
              createdAt
              url
              pullRequestReview {
                state
                commit { oid }
              }
            }
          }
        }
      }
    }
  }
}
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    identity = parser.add_argument_group("pull request")
    identity.add_argument("--url", help="GitHub pull request URL")
    identity.add_argument("--repo", help="Repository in OWNER/REPO form")
    identity.add_argument("--number", type=int, help="Pull request number")
    parser.add_argument(
        "--reviewer",
        action="append",
        default=[],
        help="Case-insensitive reviewer-author regex; repeat as needed",
    )
    parser.add_argument(
        "--exclude-author",
        action="append",
        default=[],
        help="Case-insensitive author regex to exclude; repeat as needed",
    )
    parser.add_argument("--gh", help="Path to the GitHub CLI executable")
    parser.add_argument("--compact", action="store_true", help="Emit compact JSON")
    return parser.parse_args()


def compile_patterns(values: Iterable[str], label: str) -> list[re.Pattern[str]]:
    patterns = []
    for value in values:
        try:
            patterns.append(re.compile(value, re.IGNORECASE))
        except re.error as error:
            raise ValueError(f"Invalid {label} regex {value!r}: {error}") from error
    return patterns


def author_login(item: dict[str, Any]) -> str | None:
    author = item.get("author")
    return author.get("login") if author else None


def selected_author(
    login: str | None,
    include: list[re.Pattern[str]],
    exclude: list[re.Pattern[str]],
) -> bool:
    if not login:
        return False
    if any(pattern.search(login) for pattern in exclude):
        return False
    return not include or any(pattern.search(login) for pattern in include)


def sorted_desc(items: list[dict[str, Any]], key: str) -> list[dict[str, Any]]:
    return sorted(items, key=lambda item: item.get(key) or "", reverse=True)


def get_gh_x_pr_state(
    gh: str, identity: Any, state: str | None
) -> dict[str, Any]:
    """Return the matching gh-x PR aggregate without blocking GraphQL fallback."""
    try:
        run_gh(gh, ["x", "pr", "--help"])
    except RuntimeError as error:
        return {
            "available": False,
            "found": False,
            "error": str(error),
        }

    normalized_state = (state or "").casefold()
    state_filter = {
        "open": "open",
        "closed": "closed",
        "merged": "merged",
    }.get(normalized_state, "all")

    attempts = [(state_filter, 200)]
    if state_filter != "all":
        attempts.append(("all", 500))

    errors = []
    for candidate_state, limit in attempts:
        try:
            records = run_gh_json(
                gh,
                [
                    "x",
                    "pr",
                    "list",
                    "-R",
                    identity.full_name,
                    "-s",
                    candidate_state,
                    "-L",
                    str(limit),
                    "--json",
                ],
            )
        except RuntimeError as error:
            errors.append(str(error))
            continue

        if not isinstance(records, list):
            errors.append("gh x pr returned JSON that was not a list")
            continue
        record = next(
            (item for item in records if item.get("number") == identity.number),
            None,
        )
        if record:
            return {
                "available": True,
                "found": True,
                "source": "gh x pr list",
                "stateFilter": candidate_state,
                "comments": record.get("comments"),
                "aiReview": record.get("aiReview"),
                "aiClean": record.get("aiClean"),
                "checks": record.get("checks"),
                "review": record.get("review"),
                "approvals": record.get("approvals"),
                "record": record,
            }

    return {
        "available": True,
        "found": False,
        "source": "gh x pr list",
        "error": "; ".join(errors) if errors else "PR was not present in queried gh x pr results",
    }


def main() -> int:
    args = parse_args()
    try:
        identity = resolve_pr_identity(url=args.url, repo=args.repo, number=args.number)
        include = compile_patterns(args.reviewer, "reviewer")
        exclude = compile_patterns(args.exclude_author, "excluded-author")
        gh = find_gh(args.gh)

        metadata = pr_view(
            gh,
            identity,
            [
                "number",
                "url",
                "title",
                "state",
                "isDraft",
                "author",
                "headRefOid",
                "headRefName",
                "baseRefName",
                "reviewDecision",
                "mergeStateStatus",
                "statusCheckRollup",
            ],
        )
        gh_x_pr = get_gh_x_pr_state(gh, identity, metadata.get("state"))

        graph = run_gh_json(
            gh,
            [
                "api",
                "graphql",
                "-f",
                f"query={GRAPHQL_QUERY}",
                "-F",
                f"owner={identity.owner}",
                "-F",
                f"name={identity.repo}",
                "-F",
                f"number={identity.number}",
            ],
        )
        pr = graph.get("data", {}).get("repository", {}).get("pullRequest")
        if not pr:
            raise RuntimeError(f"Pull request not found: {identity.full_name}#{identity.number}")

        head_sha = metadata.get("headRefOid")
        reviews = [
            review
            for review in pr["reviews"]["nodes"]
            if selected_author(author_login(review), include, exclude)
        ]
        for review in reviews:
            review["isCurrentHead"] = review.get("commit", {}).get("oid") == head_sha

        comments = [
            comment
            for comment in pr["comments"]["nodes"]
            if selected_author(author_login(comment), include, exclude)
        ]

        matched_authors: set[str] = set()
        by_author: dict[str, dict[str, int]] = defaultdict(
            lambda: {"reviews": 0, "prComments": 0, "unresolvedThreads": 0}
        )
        for review in reviews:
            login = author_login(review)
            if login:
                matched_authors.add(login)
                by_author[login]["reviews"] += 1
        for comment in comments:
            login = author_login(comment)
            if login:
                matched_authors.add(login)
                by_author[login]["prComments"] += 1

        unresolved_threads = []
        truncated_thread_comments = False
        for thread in pr["reviewThreads"]["nodes"]:
            thread_comments = thread["comments"]["nodes"]
            selected_comments = [
                comment
                for comment in thread_comments
                if selected_author(author_login(comment), include, exclude)
            ]
            if not selected_comments or thread["isResolved"]:
                continue

            latest = sorted_desc(selected_comments, "createdAt")[0]
            review_sha = (
                (latest.get("pullRequestReview") or {}).get("commit") or {}
            ).get("oid")
            summary = {
                "id": thread["id"],
                "path": thread.get("path"),
                "line": thread.get("line"),
                "isOutdated": thread["isOutdated"],
                "selectedCommentCount": len(selected_comments),
                "latestSelectedComment": latest,
                "reviewCommitOid": review_sha,
                "isCurrentHead": review_sha == head_sha if review_sha else None,
            }
            unresolved_threads.append(summary)
            for login in {author_login(item) for item in selected_comments} - {None}:
                matched_authors.add(login)
                by_author[login]["unresolvedThreads"] += 1
            truncated_thread_comments = truncated_thread_comments or thread["comments"][
                "pageInfo"
            ]["hasNextPage"]

        result = {
            "repository": identity.full_name,
            "pullNumber": identity.number,
            "url": metadata.get("url"),
            "title": metadata.get("title"),
            "state": metadata.get("state"),
            "isDraft": metadata.get("isDraft"),
            "author": metadata.get("author"),
            "headRefOid": head_sha,
            "headRefName": metadata.get("headRefName"),
            "baseRefName": metadata.get("baseRefName"),
            "reviewDecision": metadata.get("reviewDecision"),
            "mergeStateStatus": metadata.get("mergeStateStatus"),
            "statusCheckRollup": metadata.get("statusCheckRollup"),
            "commentResolutionSource": (
                "gh x pr" if gh_x_pr.get("found") else "GitHub GraphQL"
            ),
            "ghXPr": gh_x_pr,
            "reviewerPatterns": args.reviewer,
            "excludedAuthorPatterns": args.exclude_author,
            "matchedReviewerAuthors": sorted(matched_authors, key=str.casefold),
            "reviewerSummary": dict(sorted(by_author.items(), key=lambda item: item[0].casefold())),
            "selectedReviews": sorted_desc(reviews, "submittedAt"),
            "selectedPrComments": sorted_desc(comments, "createdAt"),
            "unresolvedSelectedThreadCount": len(unresolved_threads),
            "unresolvedSelectedThreads": unresolved_threads,
            "truncation": {
                "reviews": pr["reviews"]["totalCount"] > 100,
                "prComments": pr["comments"]["totalCount"] > 100,
                "reviewThreads": pr["reviewThreads"]["pageInfo"]["hasNextPage"],
                "threadComments": truncated_thread_comments,
            },
        }
        print(json.dumps(result, indent=None if args.compact else 2, sort_keys=False))
        return 0
    except (RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
