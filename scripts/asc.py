#!/usr/bin/env python3
"""App Store Connect plumbing for 耳语同传 (Hushpiece), via the team API key.

Credentials: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (same variables as the other projects;
scripts/asc-env.sh loads them). Subcommands are idempotent.

  asc.py setup      register the bundle ID and download the Mac App Store provisioning profile
  asc.py app        show the App Store Connect app record
"""
import base64, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from asc_api import Client, make_token  # noqa: E402

BUNDLE_ID = "app.hushpiece.Hushpiece"
PROFILE_NAME = "Hushpiece Mac App Store"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dist", "Hushpiece_MAS.provisionprofile")


def client():
    kid, iss = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
    kp = os.environ.get("ASC_KEY_PATH") or os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{kid}.p8")
    return Client(make_token(kp, kid, iss))


def bundle(c):
    r = c.get("/v1/bundleIds", **{"filter[identifier]": BUNDLE_ID})
    hit = [b for b in r["data"] if b["attributes"]["identifier"] == BUNDLE_ID]
    if hit:
        return hit[0]
    print(f"registering bundle ID {BUNDLE_ID}")
    return c.post("/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": BUNDLE_ID, "name": "Hushpiece", "platform": "MAC_OS"}}})["data"]


def setup():
    c = client()
    b = bundle(c)
    certs = c.get("/v1/certificates", limit=200)["data"]
    dist = [x for x in certs if x["attributes"]["certificateType"] in ("DISTRIBUTION", "MAC_APP_DISTRIBUTION")]
    if not dist:
        sys.exit("no Apple Distribution certificate on the team")
    profs = c.get("/v1/profiles", limit=200, **{"filter[name]": PROFILE_NAME})["data"]
    prof = next((p for p in profs if p["attributes"]["profileState"] == "ACTIVE"), None)
    if not prof:
        print("creating Mac App Store provisioning profile")
        prof = c.post("/v1/profiles", {"data": {"type": "profiles",
            "attributes": {"name": PROFILE_NAME, "profileType": "MAC_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": b["id"]}},
                "certificates": {"data": [{"type": "certificates", "id": d["id"]} for d in dist]}}}})["data"]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(base64.b64decode(prof["attributes"]["profileContent"]))
    print(f"bundle {b['id']}  profile {prof['attributes']['name']} → {os.path.normpath(OUT)}")


def app():
    c = client()
    r = c.get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID})["data"]
    print(r[0]["id"], r[0]["attributes"]["name"]) if r else print("no app record yet")


if __name__ == "__main__":
    {"setup": setup, "app": app}[sys.argv[1] if len(sys.argv) > 1 else "app"]()
