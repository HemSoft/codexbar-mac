---
name: slack-dm
description: Send approved Slack direct messages from Hermes Agent on macOS using the Slack Web API.
compatibility: Requires macOS, python3, network access, and SLACK_TOKEN with im:write, chat:write, and users:read.email when resolving by email.
---

# Slack DM

Use this skill when the user asks Hermes to send them a Slack direct message.

## Safety Rules

- Never send a Slack message without explicit approval.
- Before any send, show the exact recipient and exact message text.
- Wait for a clear approval such as "yes", "go ahead", or "send it".
- Run the send command once only. Do not retry just because output is blank or surprising.
- If the user says the DM did not arrive, then inspect the error/output and ask before trying again.
- Keep SSH and Slack tokens private. Never print `SLACK_TOKEN`.

## Recipient

Default user recipient:

- Franz Hemmer: `U2XMZDPJ7`

The helper can also resolve a Slack user by email when the bot token has `users:read.email`.

## Environment

Hermes must have a bot token available as `SLACK_TOKEN`.

The token must start with `xoxb-` and include:

- `im:write`
- `chat:write`
- `users:read.email` only if using `--email`

Check token presence without printing it:

```bash
test -n "$SLACK_TOKEN" && echo "SLACK_TOKEN is set" || echo "SLACK_TOKEN is missing"
```

Optionally verify the token identity without exposing it:

```bash
python3 ~/.hermes/skills/slack-dm/scripts/slack_dm.py --auth-test
```

## Dry Run First

Use dry-run mode to preview the recipient and payload. This does not contact Slack.

```bash
python3 ~/.hermes/skills/slack-dm/scripts/slack_dm.py \
  --user-id U2XMZDPJ7 \
  --text "Message preview"
```

## Send After Approval

After the user approves the exact text, send once:

```bash
python3 ~/.hermes/skills/slack-dm/scripts/slack_dm.py \
  --user-id U2XMZDPJ7 \
  --text "Approved message text" \
  --confirm-send
```

The helper posts a compact Block Kit message with fallback text. Keep message text short enough that Slack does not collapse it behind "Show more".

## Troubleshooting

- `SLACK_TOKEN is not set`: add the bot token to Hermes' environment or shell environment.
- `missing_scope`: the Slack app token lacks one of the required scopes.
- `channel_not_found` or `not_allowed_token_type`: use a bot token (`xoxb-`) with DM scopes, not a user token.
- `user_not_found`: verify the Slack user ID or email.
