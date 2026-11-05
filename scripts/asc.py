#!/usr/bin/env python3
"""App Store Connect from the command line, with nothing to install.

    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/asc.py snapshot
    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/asc.py get /v1/apps
    python3 scripts/asc.py check-listing
    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/asc.py push-listing 1.1.0 [mac]
    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/asc.py push-screenshots 1.1.0 <folder> [mac]
    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/asc.py attach-build 1.1.0 <build number> [mac]
    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/asc.py push-notes 1.1.0 [mac]
    ASC_KEY_ID=... ASC_ISSUER=... python3 scripts/asc.py submit 1.1.0 [mac]

The key stays where Xcode's tools look for it, ~/.appstoreconnect/private_keys/AuthKey_<id>.p8, or at
ASC_KEY_FILE. It is never read into this repository. Changes made through this API reach production:
the `push-` commands write, and only to a version still being prepared, which nobody sees until it is
submitted, approved and released by hand. `submit` sends that version to App Review, and only one
whose release is manual, so that approval alone publishes nothing.
"""

from __future__ import annotations

import base64
import hashlib
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
# What differs on the Mac, per language. The name and subtitle belong to the app, so they are shared.
LISTING_MAC = LISTING.with_name("listing-mac.json")
# The notes for App Review are what lies between the two rules of these files.
REVIEW_NOTES = {"IOS": LISTING.with_name("review-notes.md"), "MAC_OS": LISTING.with_name("review-notes-mac.md")}
# Each platform's slot on the store, and the folder of make-slides.sh that fills it.
SCREENSHOT_SLOTS = {"IOS": ("APP_IPHONE_61", "iphone-1206x2622"), "MAC_OS": ("APP_DESKTOP", "mac-2560x1600")}
PHONE_WORDS = r"iPhone|phone|téléphone|teléfono|Handy|telefon|celular|ponsel|телефон|휴대폰|手机"
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


def mac_listing(text: dict[str, dict[str, str]]) -> dict[str, dict[str, str]]:
    """The listing as the Mac store shows it."""
    changes = json.loads(LISTING_MAC.read_text())
    out: dict[str, dict[str, str]] = {}
    for code, fields in text.items():
        mac = dict(fields)
        for name in ("Promotional text", "Description"):
            for old, new in changes[code]:
                mac[name] = mac[name].replace(old, new)
        out[code] = mac
    return out


def mac_problems(text: dict[str, dict[str, str]]) -> list[str]:
    """A phone mentioned where the Mac store would show it."""
    return [
        f"{code}: {name} still says '{match[0]}'"
        for code, fields in text.items()
        for name in ("Promotional text", "Description")
        if (match := re.search(PHONE_WORDS, fields[name], flags=re.I))
    ]


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


def push_listing(version: str, platform: str = "IOS") -> int:
    """Sends listing.md to a draft of `version`, made if there is none. Released by hand, so that approval
    alone never puts it on the store."""
    text = listing()
    if platform == "MAC_OS":
        text = mac_listing(text)
    if problems := listing_problems(text) + (mac_problems(text) if platform == "MAC_OS" else []):
        print("\n".join(problems))
        return 1
    app = get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"][0]["id"]
    versions = get(f"/v1/apps/{app}/appStoreVersions?limit=10")["data"]
    draft = next(
        (
            v
            for v in versions
            if v["attributes"]["versionString"] == version and v["attributes"]["platform"] == platform
        ),
        None,
    )
    if draft is None:
        relation = {"app": {"data": {"type": "apps", "id": app}}}
        attrs = {"platform": platform, "versionString": version, "releaseType": "MANUAL"}
        made = send("POST", "/v1/appStoreVersions", {"data": {"type": "appStoreVersions", "attributes": attrs, "relationships": relation}})
        if "data" not in made:
            print(made)
            return 1
        draft = made["data"]
    info = next(i for i in get(f"/v1/apps/{app}/appInfos")["data"] if i["attributes"]["state"] != "READY_FOR_DISTRIBUTION")
    # A platform's first version has nothing to say is new, and Apple refuses the field.
    released = any(
        v["attributes"]["platform"] == platform and v["id"] != draft["id"] for v in versions
    )

    def existing(path: str) -> dict[str, str]:
        return {i["attributes"]["locale"]: i["id"] for i in get(path).get("data", [])}

    # In this order: naming a language on the app makes Apple add it, empty, to the version too.
    on_info = existing(f"/v1/appInfos/{info['id']}/appInfoLocalizations?limit=50")
    errors: dict[str, list[str]] = {code: [] for code in text}
    for code, fields in text.items():
        about = {"name": fields["Name"], "subtitle": fields["Subtitle"], "privacyPolicyUrl": PRIVACY_URL}
        if platform == "IOS":
            errors[code].append(_upsert("appInfoLocalizations", "appInfo", info["id"], on_info, LOCALES[code], about))
    on_version = existing(f"/v1/appStoreVersions/{draft['id']}/appStoreVersionLocalizations?limit=50")
    for code, fields in text.items():
        store = {
            "description": fields["Description"],
            "keywords": fields["Keywords"],
            "promotionalText": fields["Promotional text"],
            "supportUrl": SUPPORT_URL,
            "marketingUrl": MARKETING_URL,
        } | ({"whatsNew": fields["What's new"]} if released else {})
        errors[code].append(
            _upsert("appStoreVersionLocalizations", "appStoreVersion", draft["id"], on_version, LOCALES[code], store)
        )
    failed = 0
    for code, found in errors.items():
        problem = " | ".join(e for e in found if e)
        failed += bool(problem)
        print(f"{LOCALES[code]:8} {problem or 'ok'}")
    return 1 if failed else 0


def _upload_screenshot(set_id: str, path: Path) -> str:
    """Reserves the file, sends its bytes where Apple says, and commits it with its checksum."""
    data = path.read_bytes()
    relation = {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}
    attrs = {"fileName": path.name, "fileSize": len(data)}
    made = send("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots", "attributes": attrs, "relationships": relation}})
    if "data" not in made:
        return str(made.get("errors"))
    shot = made["data"]
    for part in shot["attributes"]["uploadOperations"]:
        chunk = data[part["offset"] : part["offset"] + part["length"]]
        headers = {h["name"]: h["value"] for h in part["requestHeaders"]}
        request = urllib.request.Request(part["url"], data=chunk, headers=headers, method=part["method"])
        with urllib.request.urlopen(request, timeout=120):
            pass
    done = {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}
    answer = send("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"], "attributes": done}})
    return "; ".join(e.get("detail", "") for e in answer.get("errors", []))


def _draft(version: str, platform: str) -> tuple[str, dict[str, Any]]:
    """The app and its version still being prepared."""
    app = get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"][0]["id"]
    versions = get(f"/v1/apps/{app}/appStoreVersions?limit=10")["data"]
    draft = next(
        v
        for v in versions
        if v["attributes"]["versionString"] == version
        and v["attributes"]["platform"] == platform
        and v["attributes"]["appVersionState"] == "PREPARE_FOR_SUBMISSION"
    )
    return app, draft


def push_screenshots(version: str, folder: str, platform: str = "IOS") -> int:
    """Replaces the slides of each language found in `folder`, on the draft of `version`. They are where
    make-slides.sh puts them: <folder>/<language>/<slot folder>, English in <folder>/<slot folder>."""
    kind, slot = SCREENSHOT_SLOTS[platform]
    _, draft = _draft(version, platform)
    localizations = get(f"/v1/appStoreVersions/{draft['id']}/appStoreVersionLocalizations?limit=50")["data"]
    by_locale = {item["attributes"]["locale"]: item["id"] for item in localizations}
    failed = 0
    for code, locale in LOCALES.items():
        files = sorted((Path(folder) / ("" if code == "en" else code) / slot).glob("*.png"))
        if not files:
            continue
        sets = get(f"/v1/appStoreVersionLocalizations/{by_locale[locale]}/appScreenshotSets?limit=20")["data"]
        chosen = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == kind), None)
        if chosen is None:
            relation = {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": by_locale[locale]}}}
            body = {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": kind}, "relationships": relation}
            chosen = send("POST", "/v1/appScreenshotSets", {"data": body})["data"]
        for old in get(f"/v1/appScreenshotSets/{chosen['id']}/appScreenshots?limit=20")["data"]:
            send("DELETE", f"/v1/appScreenshots/{old['id']}")
        errors = [e for e in (_upload_screenshot(chosen["id"], f) for f in files) if e]
        failed += bool(errors)
        print(f"{locale:8} {len(files) - len(errors)} of {len(files)} {errors[:1] or ''}")
    return 1 if failed else 0


def attach_build(version: str, number: str, platform: str = "IOS") -> int:
    """Puts an uploaded build, once Apple has processed it, on the draft of `version`."""
    app, draft = _draft(version, platform)
    query = f"filter[app]={app}&filter[version]={number}&filter[preReleaseVersion.platform]={platform}"
    build = get(f"/v1/builds?{query}")["data"][0]
    body = {"data": {"type": "builds", "id": build["id"]}}
    sent = send("PATCH", f"/v1/appStoreVersions/{draft['id']}/relationships/build", body)
    if "errors" in sent:
        print(sent["errors"])
        return 1
    print(f"Build {number} ({build['attributes']['processingState']}) is on {platform} {version}")
    return 0


def push_notes(version: str, platform: str = "IOS") -> int:
    """Sends the notes for App Review to the draft of `version`, and reads them back."""
    notes = REVIEW_NOTES[platform].read_text(encoding="utf-8").split("\n---\n")[1].strip()
    _, draft = _draft(version, platform)
    detail = get(f"/v1/appStoreVersions/{draft['id']}/appStoreReviewDetail")["data"]["id"]
    body = {"type": "appStoreReviewDetails", "id": detail, "attributes": {"notes": notes}}
    sent = send("PATCH", f"/v1/appStoreReviewDetails/{detail}", {"data": body})
    if "errors" in sent or sent["data"]["attributes"]["notes"] != notes:
        print(sent.get("errors", "The notes did not come back the same"))
        return 1
    print(f"{len(notes)} characters of notes on {platform} {version}")
    return 0


def submit(version: str, platform: str = "IOS") -> int:
    """Sends the draft of `version` to App Review. A review is a submission holding the version, sent once."""
    app, draft = _draft(version, platform)
    if draft["attributes"]["releaseType"] != "MANUAL":
        print(f"Not sent: {version} would go live on approval ({draft['attributes']['releaseType']})")
        return 1
    relation = {"app": {"data": {"type": "apps", "id": app}}}
    body = {"type": "reviewSubmissions", "attributes": {"platform": platform}, "relationships": relation}
    created = send("POST", "/v1/reviewSubmissions", {"data": body})
    if "errors" in created:
        print(created["errors"])
        return 1
    submission = created["data"]["id"]
    relation = {
        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission}},
        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": draft["id"]}},
    }
    item = send("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": relation}})
    if "errors" in item:
        print(item["errors"])
        return 1
    body = {"type": "reviewSubmissions", "id": submission, "attributes": {"submitted": True}}
    sent = send("PATCH", f"/v1/reviewSubmissions/{submission}", {"data": body})
    if "errors" in sent:
        print(sent["errors"])
        return 1
    print(f"{version} sent to App Review: {sent['data']['attributes']['state']}")
    return 0


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "snapshot":
        print(json.dumps(snapshot(), indent=2, ensure_ascii=False))
    elif command == "get" and len(sys.argv) == 3:
        print(json.dumps(get(sys.argv[2]), indent=2, ensure_ascii=False))
    elif command == "check-listing":
        text = listing()
        mac = mac_listing(text)
        problems = listing_problems(text) + listing_problems(mac) + mac_problems(mac)
        print("\n".join(problems) or "The listing fits, in every language, on the phone and on the Mac")
        return 1 if problems else 0
    elif command == "push-screenshots" and len(sys.argv) in (4, 5):
        return push_screenshots(sys.argv[2], sys.argv[3], "MAC_OS" if sys.argv[4:] == ["mac"] else "IOS")
    elif command == "attach-build" and len(sys.argv) in (4, 5):
        return attach_build(sys.argv[2], sys.argv[3], "MAC_OS" if sys.argv[4:] == ["mac"] else "IOS")
    elif command == "push-notes" and len(sys.argv) in (3, 4):
        return push_notes(sys.argv[2], "MAC_OS" if sys.argv[3:] == ["mac"] else "IOS")
    elif command == "push-listing" and len(sys.argv) in (3, 4):
        return push_listing(sys.argv[2], "MAC_OS" if sys.argv[3:] == ["mac"] else "IOS")
    elif command == "submit" and len(sys.argv) in (3, 4):
        return submit(sys.argv[2], "MAC_OS" if sys.argv[3:] == ["mac"] else "IOS")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
