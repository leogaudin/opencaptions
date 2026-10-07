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

OpenCaptions has per-account authentication (server-side sessions). Its single
published port listens on every interface, so a stock install is reachable from
the local network (see the [security note in the README](README.md#security)).
Putting it on a public host is the operator's responsibility, and reports about
such an instance's own configuration are configuration issues, not
vulnerabilities.

Self-service signup is **on by default**: all accounts are ordinary users (as
Gitea and Jellyfin allow open signup). Because the web port listens on every
interface, anyone who can reach the machine can sign up and spend its CPU/GPU on
transcription and rendering. No other service publishes a port. On anything but a
trusted network, turn registration off by setting `REGISTRATION_ENABLED` to
`false` in the `api` service's `environment:` block, and/or bind the port to
`127.0.0.1` behind a reverse proxy.

Transcription can leave the machine: with the `openai` or `opencaptions` provider, or when
a phone app is connected to your server, audio is sent to the other end. Your instance, as
the other end, deletes the audio of a job when it ends and a transcript after
`TRANSCRIPTION_RESULT_TTL_H` hours (24 by default). Its transcription API takes the same API
keys as the rest of the API: revoke a key on the Account page to cut off a phone. The address
set in `TRANSCRIPTION_REMOTE_URL` goes through the same guard as a video URL, so a private
address is refused unless its host is listed in `SSRF_ALLOWED_HOSTS`.

If a user forgets their password, recovery depends on whether SMTP is configured
(see the `SMTP_*` variables in the env examples). With SMTP set up, self-service
reset is offered from the login page: request a link by email, set a new
password, and every existing session for that account is revoked. Without SMTP
the flow is not offered at all, and no reset link or token is ever written to a
log, so recovery is the host operation `scripts/reset_password.py` (run inside
the `api` container).
