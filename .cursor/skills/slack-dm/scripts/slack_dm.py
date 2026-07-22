#!/usr/bin/env python3
"""Send a Slack direct message after explicit confirmation.

Dry-run is the default. Add --confirm-send only after user approval.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import urllib.error
import urllib.request


SLACK_API = "https://slack.com/api"
DEFAULT_USER_ID = "U2XMZDPJ7"


def slack_request(method: str, token: str, payload: dict | None = None) -> dict:
    data = None
    headers = {"Authorization": f"Bearer {token}"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"

    request = urllib.request.Request(
        f"{SLACK_API}/{method}",
        data=data,
        headers=headers,
        method="POST" if payload is not None else "GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Slack HTTP {exc.code}: {body}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Slack network error: {exc.reason}") from exc

    parsed = json.loads(body)
    if not parsed.get("ok"):
        raise RuntimeError(f"Slack API error from {method}: {parsed.get('error', parsed)}")
    return parsed


def require_token() -> str:
    token = os.environ.get("SLACK_TOKEN", "")
    if not token:
        raise RuntimeError("SLACK_TOKEN is not set")
    if not token.startswith("xoxb-"):
        raise RuntimeError("SLACK_TOKEN must be a bot token beginning with xoxb-")
    return token


def lookup_user_by_email(token: str, email: str) -> str:
    encoded = urllib.parse.quote(email)
    result = slack_request(f"users.lookupByEmail?email={encoded}", token)
    return result["user"]["id"]


def open_dm(token: str, user_id: str) -> str:
    result = slack_request("conversations.open", token, {"users": user_id})
    return result["channel"]["id"]


def build_message(channel_id: str, text: str) -> dict:
    return {
        "channel": channel_id,
        "text": text,
        "blocks": [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": text,
                },
            },
            {
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": "Sent by Hermes Agent",
                    }
                ],
            },
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Send an approved Slack DM.")
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--user-id", default=DEFAULT_USER_ID, help="Slack user ID to DM.")
    target.add_argument("--email", help="Slack email address to resolve and DM.")
    parser.add_argument("--text", help="Message text to send.")
    parser.add_argument("--confirm-send", action="store_true", help="Actually send the DM.")
    parser.add_argument("--auth-test", action="store_true", help="Validate token identity.")
    args = parser.parse_args()

    if args.auth_test:
        token = require_token()
        result = slack_request("auth.test", token)
        print(json.dumps({"ok": True, "team": result.get("team"), "user": result.get("user"), "user_id": result.get("user_id")}, indent=2))
        return 0

    if not args.text:
        parser.error("--text is required unless --auth-test is used")

    if args.email:
        if args.confirm_send:
            token = require_token()
            user_id = lookup_user_by_email(token, args.email)
        else:
            user_id = f"<resolved from {args.email} when sending>"
    else:
        user_id = args.user_id

    if not args.confirm_send:
        print("DRY RUN: no Slack API write was performed.")
        print(json.dumps({"recipient": user_id, "text": args.text}, indent=2))
        return 0

    token = require_token()
    channel_id = open_dm(token, user_id)
    payload = build_message(channel_id, args.text)
    result = slack_request("chat.postMessage", token, payload)
    print(json.dumps({"ok": True, "channel": result.get("channel"), "ts": result.get("ts")}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
