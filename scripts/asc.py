#!/usr/bin/env python3
"""App Store Connect from the command line, with nothing to install.

    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/asc.py snapshot
    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/asc.py get /v1/apps

The key stays where Xcode's tools look for it, ~/.appstoreconnect/private_keys/AuthKey_<id>.p8, or at
ASC_KEY_FILE. It is never read into this repository. Changes made through this API reach the live
store, so what is here only reads; a command that writes says so in its name.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "org.leogaudin.opencaptions"


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _raw_signature(der: bytes) -> bytes:
    """OpenSSL signs in DER; a JWT carries r and s side by side, 32 bytes each."""
    length_at = 3
    r_len = der[length_at]
    r = der[length_at + 1 : length_at + 1 + r_len]
    s_at = length_at + 1 + r_len + 1
    s = der[s_at + 1 : s_at + 1 + der[s_at]]
    return r.lstrip(b"\0").rjust(32, b"\0") + s.lstrip(b"\0").rjust(32, b"\0")


def token() -> str:
    key_id, issuer = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER"]
    default = Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{key_id}.p8"
    key_file = os.environ.get("ASC_KEY_FILE", str(default))
    now = int(time.time())
    head = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    body = {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    signing = f"{_b64(json.dumps(head).encode())}.{_b64(json.dumps(body).encode())}"
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_file],
        input=signing.encode(),
        capture_output=True,
        check=True,
    ).stdout
    return f"{signing}.{_b64(_raw_signature(der))}"


def get(path: str) -> dict[str, Any]:
    url = path if path.startswith("http") else API + path
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        return {"status": e.code, "errors": json.load(e).get("errors", [])}


def snapshot() -> dict[str, Any]:
    """What the store holds now: the app, its versions and listings, and what it sells."""
    apps = get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}")
    if "data" not in apps or not apps["data"]:
        return apps
    app = apps["data"][0]
    versions = get(f"/v1/apps/{app['id']}/appStoreVersions?limit=10").get("data", [])
    out: dict[str, Any] = {
        "app": {"id": app["id"], **app["attributes"]},
        "versions": [
            {"id": v["id"], **{k: v["attributes"].get(k) for k in _VERSION_FIELDS}}
            for v in versions
        ],
    }
    if versions:
        listing = get(f"/v1/appStoreVersions/{versions[0]['id']}/appStoreVersionLocalizations?limit=50")
        out["locales"] = [
            {
                "locale": item["attributes"]["locale"],
                "keywords": item["attributes"].get("keywords"),
                "promotionalText": item["attributes"].get("promotionalText"),
            }
            for item in listing.get("data", [])
        ]
    out["purchases"] = get(f"/v1/apps/{app['id']}/inAppPurchasesV2?limit=20")
    return out


_VERSION_FIELDS = ("platform", "versionString", "appStoreState", "appVersionState", "releaseType")


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "snapshot":
        print(json.dumps(snapshot(), indent=2, ensure_ascii=False))
    elif command == "get" and len(sys.argv) == 3:
        print(json.dumps(get(sys.argv[2]), indent=2, ensure_ascii=False))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
