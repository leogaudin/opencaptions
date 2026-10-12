---
title: "Accounts and API keys"
description: "How accounts work in a self-hosted OpenCaptions, closing registration, password reset by email or from the command line, and API keys."
sidebar:
  order: 6
---

# Accounts and API keys

Accounts are local to your instance. They keep each person's projects separate and give scripts and the
phone app a way in. Nothing about them is sent anywhere.

## Creating accounts

The first visit shows a sign-up form, and **every account is an ordinary user**: there is no administrator
role. Anyone who can reach the page can sign up while registration is open, so once the people you want have
accounts, close it:

```yaml
REGISTRATION_ENABLED: "false"
```

With registration closed, signing up is still possible until the first account exists, so you can set the
setting before the first start and still make your own account. After that the page sends people to sign in
instead. See [Security](./security.md).

## The Account page

Open it from the account menu. It holds the email and password, the interface language and theme, a usage
summary (the projects, the time transcribed, and the frames made, totalled from finished jobs: this
instance does not meter or limit them), your [API keys](#api-keys), and the setting for
[transcribing on another server](./speech-models.md#another-opencaptions-server).

## Password reset

Signed in, you change your password on the Account page, with the current one.

If you forgot it, there are two ways, depending on whether the server can send email:

- **With email.** Set `SMTP_HOST` (and the other `SMTP_*` settings in [Configuration](./configuration.md#email)).
  The sign-in page then offers a reset link by email, and a reset revokes the account's sessions. Set
  `PUBLIC_BASE_URL` too, since the link is built from it.
- **Without email.** The reset flow is not offered, and no link or token is ever written to a log. Recovery
  is a command for the person who runs the server, from a checkout of the repository:

  ```bash
  docker compose cp scripts/reset_password.py api:/tmp/reset_password.py
  docker compose exec api /app/.venv/bin/python /tmp/reset_password.py you@example.com
  ```

  It asks for the new password, and writes the same kind of hash the app does. The script is not in the
  image, so you copy it in first.

## API keys

An API key lets a script, or the [iPhone app](../guides/iphone-app.md#use-your-own-server-instead), use your
account without a browser session.

1. On the Account page, open **API keys**, give the key a name (such as "podcast pipeline") and select **Create key**.
2. **Copy the key now.** It starts with `oc_` and is shown once. Only a hash is stored.
3. Use it as a bearer token: `Authorization: Bearer oc_…`. See the [API](../reference/api.md).

A key reaches every endpoint **except account management** (`/auth`, `/api-keys`), which needs a signed-in
browser, so a leaked key cannot mint more keys or take over the account. The list shows when each key was
created and last used, and **Revoke** cuts one off at once.

A new key also comes with a QR code and a link (`opencaptions://connect?url=…&key=…`) that set the phone
app up in one step.
