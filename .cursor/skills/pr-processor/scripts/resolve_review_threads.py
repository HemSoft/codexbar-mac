#!/usr/bin/env python3
"""Resolve explicitly selected GitHub pull-request review threads."""

from __future__ import annotations

import argparse
import json
import sys

from github_pr import find_gh, run_gh_json


MUTATION = r"""
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread { id isResolved }
  }
}
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--thread-id",
        action="append",
        required=True,
        help="GraphQL review thread ID to resolve; repeat as needed",
    )
    parser.add_argument("--dry-run", action="store_true", help="Show selected IDs only")
    parser.add_argument("--gh", help="Path to the GitHub CLI executable")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        thread_ids = list(dict.fromkeys(args.thread_id))
        if args.dry_run:
            print(
                json.dumps(
                    {"resolved": False, "dryRun": True, "threadIds": thread_ids},
                    indent=2,
                )
            )
            return 0

        gh = find_gh(args.gh)
        results = []
        for thread_id in thread_ids:
            response = run_gh_json(
                gh,
                [
                    "api",
                    "graphql",
                    "-f",
                    f"query={MUTATION}",
                    "-F",
                    f"threadId={thread_id}",
                ],
            )
            thread = (
                response.get("data", {})
                .get("resolveReviewThread", {})
                .get("thread")
            )
            if not thread or not thread.get("isResolved"):
                raise RuntimeError(f"GitHub did not confirm resolution for {thread_id}")
            results.append(thread)

        print(json.dumps({"resolved": True, "threads": results}, indent=2))
        return 0
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
