# Security Policy

## Supported versions

OpenCaptions is pre-1.0 and under active development. Only the **latest
released version** receives security fixes, there are no backports to older
tags, and unreleased commits on `main` are not covered.

| Version         | Supported |
| --------------- | --------- |
| Latest release  | ✅        |
| Older releases  | ❌        |

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately through GitHub's private vulnerability reporting:

1. Open the [Report a vulnerability](https://github.com/leogaudin/opencaptions/security/advisories/new) form.
2. Include the affected version or commit, steps to reproduce, and impact.

This is a single-maintainer project, so triage is best-effort. You will get an
acknowledgement when the report is picked up and a follow-up when a fix or
mitigation ships. Coordinated disclosure is appreciated, please give a fix a
chance to land before publishing details.

## Scope

OpenCaptions has per-account authentication (server-side sessions). The web port listens on
every interface and signup is open by default, so a stock install is reachable, and usable, by
anyone on the local network. Hardening a public host is the operator's job (see the
[security section of the self-hosting guide](docs/SELF-HOSTING.md#security)); reports about an
instance's own configuration are configuration issues, not vulnerabilities.

Transcription can leave the machine: with the `openai` or `opencaptions` provider, or when a
phone app is connected to your server, audio is sent to the other end. An instance, as the other
end, deletes a job's audio when it ends and the transcript after `TRANSCRIPTION_RESULT_TTL_H`
hours (24 by default). Its transcription API takes the same API keys as the rest of the API;
revoke a key on the Account page to cut off a phone. `TRANSCRIPTION_REMOTE_URL` goes through the
same guard as a video URL, so a private address is refused unless its host is in
`SSRF_ALLOWED_HOSTS`.

Password recovery depends on SMTP (the `SMTP_*` settings in `apps/api/app/core/config.py`). With
it, the login page offers a reset link by email and a reset revokes the account's sessions.
Without it the flow is not offered and no link or token is ever logged: recovery is the host
operation `scripts/reset_password.py`, run inside the `api` container.
