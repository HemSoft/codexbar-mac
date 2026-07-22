#!/usr/bin/env python3
"""Request configurable GitHub PR reviews through comments or reviewer logins."""

from __future__ import annotations

import argparse
import json
import sys

from github_pr import find_gh, pr_view, resolve_pr_identity, run_gh


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", help="GitHub pull request URL")
    parser.add_argument("--repo", help="Repository in OWNER/REPO form")
    parser.add_argument("--number", type=int, help="Pull request number")
    parser.add_argument(
        "--comment",
        action="append",
        default=[],
        help="Exact PR trigger comment to post; repeat as needed",
    )
    parser.add_argument(
        "--github-reviewer",
        action="append",
        default=[],
        help="GitHub reviewer login or team accepted by gh; repeat as needed",
    )
    parser.add_argument("--dry-run", action="store_true", help="Show planned writes only")
    parser.add_argument("--gh", help="Path to the GitHub CLI executable")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if not args.comment and not args.github_reviewer:
            raise ValueError("Pass at least one --comment or --github-reviewer.")

        identity = resolve_pr_identity(url=args.url, repo=args.repo, number=args.number)
        gh = find_gh(args.gh)
        metadata = pr_view(gh, identity, ["url", "headRefOid"])
        plan = {
            "url": metadata["url"],
            "headRefOid": metadata["headRefOid"],
            "triggerComments": args.comment,
            "githubReviewers": args.github_reviewer,
        }
        if args.dry_run:
            print(json.dumps({"requested": False, "dryRun": True, **plan}, indent=2))
            return 0

        posted_comments = []
        for body in args.comment:
            output = run_gh(
                gh,
                [
                    "pr",
                    "comment",
                    str(identity.number),
                    "--repo",
                    identity.full_name,
                    "--body",
                    body,
                ],
            )
            posted_comments.append({"body": body, "result": output})

        reviewer_request = None
        if args.github_reviewer:
            command = [
                "pr",
                "edit",
                str(identity.number),
                "--repo",
                identity.full_name,
            ]
            for reviewer in args.github_reviewer:
                command.extend(["--add-reviewer", reviewer])
            reviewer_request = run_gh(gh, command)

        print(
            json.dumps(
                {
                    "requested": True,
                    **plan,
                    "postedComments": posted_comments,
                    "reviewerRequestResult": reviewer_request,
                },
                indent=2,
            )
        )
        return 0
    except (RuntimeError, ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
