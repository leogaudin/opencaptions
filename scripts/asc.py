#!/usr/bin/env python3
"""App Store Connect from the command line, with nothing to install.

    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/asc.py snapshot
    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/asc.py get /v1/apps
    python3 scripts/asc.py check-listing
    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/asc.py push-listing 1.1.0

The key stays where Xcode's tools look for it, ~/.appstoreconnect/private_keys/AuthKey_<id>.p8, or at
ASC_KEY_FILE. It is never read into this repository. Changes made through this API reach production:
only `push-listing` writes, and only to a version still being prepared, which nobody sees until it is
submitted, approved and released by hand.
"""

from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "org.leogaudin.opencaptions"
LISTING = Path(__file__).resolve().parent.parent / "apps/ios/AppStore/listing.md"
SUPPORT_URL = "https://opencaptions.app/support"
MARKETING_URL = "https://opencaptions.app"
PRIVACY_URL = "https://github.com/leogaudin/opencaptions/blob/main/PRIVACY.md"

# A language in listing.md, and what App Store Connect calls it.
LOCALES = {
    "en": "en-US",
    "fr": "fr-FR",
    "es": "es-ES",
    "de": "de-DE",
    "pl": "pl",
    "pt-BR": "pt-BR",
    "it": "it",
    "ru": "ru",
    "tr": "tr",
    "ja": "ja",
    "ko": "ko",
    "zh-Hans": "zh-Hans",
    "id": "id",
}
LIMITS = {
    "Name": 30,
    "Subtitle": 30,
    "Promotional text": 170,
    "Keywords": 100,
    "What's new": 4000,
    "Description": 4000,
}


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


def send(method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    """One call to the API. Anything but GET changes the live store."""
    url = path if path.startswith("http") else API + path
    headers = {"Authorization": f"Bearer {token()}", "Content-Type": "application/json"}
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            text = response.read()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        return {"status": e.code, "errors": json.load(e).get("errors", [])}


def get(path: str) -> dict[str, Any]:
    return send("GET", path)


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


def listing() -> dict[str, dict[str, str]]:
    """The text of listing.md, by language and field."""
    parts = re.split(r"^## (\S+)\s*$", LISTING.read_text(), flags=re.M)
    out: dict[str, dict[str, str]] = {}
    for code, body in zip(parts[1::2], parts[2::2], strict=True):
        fields = {
            name: match[1].strip()
            for name in LIMITS
            if name != "Description" and (match := re.search(rf"\*\*{name}:\*\*\s*(.*)", body))
        }
        fields["Description"] = body.split("**Description:**", 1)[-1].strip()
        out[code] = fields
    return out


def listing_problems(text: dict[str, dict[str, str]]) -> list[str]:
    """What App Store Connect would refuse, or what would be wasted, before anything is sent."""
    problems = [f"{code} is not in LOCALES" for code in text if code not in LOCALES]
    problems += [f"{code} is missing" for code in LOCALES if code not in text]
    for code, fields in text.items():
        for name, limit in LIMITS.items():
            value = fields.get(name, "")
            if not value:
                problems.append(f"{code}: no {name}")
            elif len(value) > limit:
                problems.append(f"{code}: {name} is {len(value)}, the limit is {limit}")
        title = set(re.findall(r"\w+", f"{fields.get('Name')} {fields.get('Subtitle')}".lower()))
        repeated = [k for k in fields.get("Keywords", "").split(",") if k.lower() in title]
        if repeated:
            problems.append(f"{code}: keywords repeat the name or subtitle: {repeated}")
    return problems


def _upsert(kind: str, parent: str, parent_id: str, have: dict[str, str], locale: str, attrs: dict[str, str]) -> str:
    """Sets a localization, creating it if the language is new to this version. Says what went wrong, if it did."""
    if locale in have:
        data = {"type": kind, "id": have[locale], "attributes": attrs}
        answer = send("PATCH", f"/v1/{kind}/{have[locale]}", {"data": data})
    else:
        relation = {parent: {"data": {"type": f"{parent}s", "id": parent_id}}}
        data = {"type": kind, "attributes": {"locale": locale, **attrs}, "relationships": relation}
        answer = send("POST", f"/v1/{kind}", {"data": data})
    return "; ".join(e.get("detail", e.get("title", "")) for e in answer.get("errors", []))


def push_listing(version: str) -> int:
    """Sends listing.md to a draft of `version`, made if there is none. Released by hand, so that approval
    alone never puts it on the store."""
    text = listing()
    if problems := listing_problems(text):
        print("\n".join(problems))
        return 1
    app = get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"][0]["id"]
    versions = get(f"/v1/apps/{app}/appStoreVersions?limit=10")["data"]
    draft = next((v for v in versions if v["attributes"]["versionString"] == version), None)
    if draft is None:
        relation = {"app": {"data": {"type": "apps", "id": app}}}
        attrs = {"platform": "IOS", "versionString": version, "releaseType": "MANUAL"}
        made = send("POST", "/v1/appStoreVersions", {"data": {"type": "appStoreVersions", "attributes": attrs, "relationships": relation}})
        if "data" not in made:
            print(made)
            return 1
        draft = made["data"]
    info = next(i for i in get(f"/v1/apps/{app}/appInfos")["data"] if i["attributes"]["state"] != "READY_FOR_DISTRIBUTION")

    def existing(path: str) -> dict[str, str]:
        return {i["attributes"]["locale"]: i["id"] for i in get(path).get("data", [])}

    # In this order: naming a language on the app makes Apple add it, empty, to the version too.
    on_info = existing(f"/v1/appInfos/{info['id']}/appInfoLocalizations?limit=50")
    errors: dict[str, list[str]] = {code: [] for code in text}
    for code, fields in text.items():
        about = {"name": fields["Name"], "subtitle": fields["Subtitle"], "privacyPolicyUrl": PRIVACY_URL}
        errors[code].append(_upsert("appInfoLocalizations", "appInfo", info["id"], on_info, LOCALES[code], about))
    on_version = existing(f"/v1/appStoreVersions/{draft['id']}/appStoreVersionLocalizations?limit=50")
    for code, fields in text.items():
        store = {
            "description": fields["Description"],
            "keywords": fields["Keywords"],
            "promotionalText": fields["Promotional text"],
            "whatsNew": fields["What's new"],
            "supportUrl": SUPPORT_URL,
            "marketingUrl": MARKETING_URL,
        }
        errors[code].append(
            _upsert("appStoreVersionLocalizations", "appStoreVersion", draft["id"], on_version, LOCALES[code], store)
        )
    failed = 0
    for code, found in errors.items():
        problem = " | ".join(e for e in found if e)
        failed += bool(problem)
        print(f"{LOCALES[code]:8} {problem or 'ok'}")
    return 1 if failed else 0


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "snapshot":
        print(json.dumps(snapshot(), indent=2, ensure_ascii=False))
    elif command == "get" and len(sys.argv) == 3:
        print(json.dumps(get(sys.argv[2]), indent=2, ensure_ascii=False))
    elif command == "check-listing":
        problems = listing_problems(listing())
        print("\n".join(problems) or "The listing fits, in every language")
        return 1 if problems else 0
    elif command == "push-listing" and len(sys.argv) == 3:
        return push_listing(sys.argv[2])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
