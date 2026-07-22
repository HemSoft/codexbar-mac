#!/usr/bin/env python3
"""Shared GitHub CLI helpers for the PR Processor skill."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from dataclasses import dataclass
from typing import Any, Sequence


@dataclass(frozen=True)
class PullRequestIdentity:
    owner: str
    repo: str
    number: int

    @property
    def full_name(self) -> str:
        return f"{self.owner}/{self.repo}"


PR_URL_PATTERN = re.compile(
    r"^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)(?:[/?#].*)?$",
    re.IGNORECASE,
)


def resolve_pr_identity(
    *, url: str | None, repo: str | None, number: int | None
) -> PullRequestIdentity:
    if url:
        match = PR_URL_PATTERN.match(url)
        if not match:
            raise ValueError(f"Unsupported GitHub PR URL: {url}")
        return PullRequestIdentity(match.group(1), match.group(2), int(match.group(3)))

    if not repo or number is None:
        raise ValueError("Provide --url or both --repo OWNER/REPO and --number.")

    parts = repo.split("/", 1)
    if len(parts) != 2 or not all(parts):
        raise ValueError(f"Repository must use OWNER/REPO form: {repo}")
    return PullRequestIdentity(parts[0], parts[1], number)


def find_gh(explicit: str | None = None) -> str:
    if explicit:
        return explicit
    executable = shutil.which("gh") or shutil.which("gh.exe")
    if not executable:
        raise RuntimeError("GitHub CLI was not found. Install `gh` or pass --gh PATH.")
    return executable


def run_gh(gh: str, arguments: Sequence[str]) -> str:
    command = [gh, *arguments]
    completed = subprocess.run(command, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(
            f"GitHub CLI command failed ({completed.returncode}): "
            f"{' '.join(command)}\n{detail}"
        )
    return completed.stdout.strip()


def run_gh_json(gh: str, arguments: Sequence[str]) -> Any:
    output = run_gh(gh, arguments)
    try:
        return json.loads(output)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"GitHub CLI did not return valid JSON: {error}") from error


def pr_view(gh: str, identity: PullRequestIdentity, fields: Sequence[str]) -> Any:
    return run_gh_json(
        gh,
        [
            "pr",
            "view",
            str(identity.number),
            "--repo",
            identity.full_name,
            "--json",
            ",".join(fields),
        ],
    )
