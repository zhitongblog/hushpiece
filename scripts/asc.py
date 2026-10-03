#!/usr/bin/env python3
"""App Store Connect plumbing for 耳语同传 (Hushpiece), via the team API key.

Credentials: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (same variables as the other projects;
scripts/asc-env.sh loads them). Subcommands are idempotent.

  asc.py setup      register the bundle ID and download the Mac App Store provisioning profile
  asc.py app        show the App Store Connect app record
  asc.py listing    fill the store listing from marketing/appstore/metadata.json (text, URLs, category,
                    age rating, free price, all territories, review details, screenshots)
  asc.py upload     upload the newest dist-mas/*.pkg (altool, API key)
  asc.py submit     wait for the build, attach it to the version, submit for review
"""
import base64, glob, hashlib, json, os, subprocess, sys, time, urllib.request
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


ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
META = json.load(open(os.path.join(ROOT, "marketing", "appstore", "metadata.json")))


def the_app(c):
    r = c.get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID})["data"]
    if not r:
        sys.exit("no App Store Connect record for %s yet — create it at appstoreconnect.apple.com (+ → New App)" % BUNDLE_ID)
    return r[0]


def editable_version(c, app_id):
    vs = c.get(f"/v1/apps/{app_id}/appStoreVersions", limit=10, **{"filter[platform]": "MAC_OS"})["data"]
    for v in vs:
        if v["attributes"]["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"):
            return v
    return None


def step(name, fn):
    try:
        fn()
        print(f"  ✓ {name}")
    except Exception as e:  # keep going: one rejected field must not hide the rest
        print(f"  ✗ {name}: {str(e)[:300]}")


def listing():
    c = client()
    a = the_app(c)
    app_id = a["id"]
    loc = META["primaryLocale"]
    L = META["localizations"][loc]
    print(f"app {app_id} {a['attributes']['name']}")

    step("content rights", lambda: c.patch(f"/v1/apps/{app_id}", {"data": {"type": "apps", "id": app_id,
        "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}}))

    infos = c.get(f"/v1/apps/{app_id}/appInfos")["data"]
    info = next((i for i in infos if i["attributes"].get("state") not in ("READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_INFO")), infos[0])
    step("category", lambda: c.patch(f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": META["primaryCategory"]}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": META["secondaryCategory"]}}}}}))

    def info_loc():
        locs = c.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"]
        il = next((x for x in locs if x["attributes"]["locale"] == loc), None)
        attrs = {"subtitle": L["subtitle"], "privacyPolicyUrl": META["urls"]["privacy"]}
        if il:
            c.patch(f"/v1/appInfoLocalizations/{il['id']}", {"data": {"type": "appInfoLocalizations", "id": il["id"], "attributes": attrs}})
        else:
            c.post("/v1/appInfoLocalizations", {"data": {"type": "appInfoLocalizations", "attributes": dict(attrs, locale=loc, name=a["attributes"]["name"]),
                "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info["id"]}}}}})
    step("subtitle + privacy URL", info_loc)

    def age():
        d = c.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]
        cur = d["attributes"]
        enums = ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons", "horrorOrFearThemes",
                 "matureOrSuggestiveThemes", "medicalOrTreatmentInformation", "profanityOrCrudeHumor", "sexualContentGraphicAndNudity",
                 "sexualContentOrNudity", "violenceCartoonOrFantasy", "violenceRealistic", "violenceRealisticProlongedGraphicOrSadistic"]
        bools = ["gambling", "unrestrictedWebAccess", "lootBox", "messagingAndChat", "userGeneratedContent", "advertising",
                 "healthOrWellnessTopics", "parentalControls", "ageAssurance"]
        attrs = {k: "NONE" for k in enums if k in cur}
        attrs.update({k: False for k in bools if k in cur})
        c.patch(f"/v1/ageRatingDeclarations/{d['id']}", {"data": {"type": "ageRatingDeclarations", "id": d["id"], "attributes": attrs}})
    step("age rating (4+)", age)

    def price():
        pts = c.get(f"/v1/apps/{app_id}/appPricePoints", limit=200, **{"filter[territory]": "USA"})["data"]
        free = next(p for p in pts if float(p["attributes"]["customerPrice"]) == 0)
        c.post("/v1/appPriceSchedules", {"data": {"type": "appPriceSchedules", "relationships": {
            "app": {"data": {"type": "apps", "id": app_id}},
            "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
            "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]}}},
            "included": [{"type": "appPrices", "id": "${free}", "attributes": {"startDate": None},
                          "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]})
    step("price: free", price)

    def territories():
        ts = c.get("/v1/territories", limit=200)["data"]
        refs = [{"type": "territoryAvailabilities", "id": f"${{t{i}}}"} for i in range(len(ts))]
        inc = [{"type": "territoryAvailabilities", "id": f"${{t{i}}}", "attributes": {"available": True},
                "relationships": {"territory": {"data": {"type": "territories", "id": t["id"]}}}} for i, t in enumerate(ts)]
        c.post("/v2/appAvailabilities", {"data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}, "territoryAvailabilities": {"data": refs}}}, "included": inc})
        print(f"    {len(ts)} territories")
    step("availability: all territories", territories)

    v = editable_version(c, app_id)
    if not v:
        sys.exit("no editable macOS version on the record")
    vid = v["id"]
    version = subprocess.check_output(["grep", "-m1", "let version", os.path.join(ROOT, "Sources/Hushpiece/Main.swift")], text=True).split('"')[1]
    step(f"version {version} + copyright", lambda: c.patch(f"/v1/appStoreVersions/{vid}", {"data": {"type": "appStoreVersions", "id": vid,
        "attributes": {"versionString": version, "copyright": META["copyright"]}}}))

    def vloc():
        locs = c.get(f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]
        vl = next((x for x in locs if x["attributes"]["locale"] == loc), None)
        attrs = {"description": L["description"], "keywords": L["keywords"], "promotionalText": L["promotionalText"],
                 "supportUrl": META["urls"]["support"], "marketingUrl": META["urls"]["marketing"]}
        if vl:
            c.patch(f"/v1/appStoreVersionLocalizations/{vl['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": vl["id"], "attributes": attrs}})
        else:
            vl = c.post("/v1/appStoreVersionLocalizations", {"data": {"type": "appStoreVersionLocalizations", "attributes": dict(attrs, locale=loc),
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})["data"]
        return vl
    holder = {}
    step("description / keywords / promo / URLs", lambda: holder.setdefault("vl", vloc()))

    def review():
        R = META["review"]
        # Contact email and phone are copied from another app's review details on the same team,
        # so they never have to live in this (public) repository.
        email = phone = None
        src = c.get("/v1/apps", **{"filter[bundleId]": R["contactFrom"]})["data"]
        if src:
            sv = c.get(f"/v1/apps/{src[0]['id']}/appStoreVersions", limit=1, **{"filter[platform]": "MAC_OS"})["data"]
            if sv:
                rd = c.get(f"/v1/appStoreVersions/{sv[0]['id']}/appStoreReviewDetail")["data"]["attributes"]
                email, phone = rd.get("contactEmail"), rd.get("contactPhone")
        attrs = {"contactFirstName": R["contactFirstName"], "contactLastName": R["contactLastName"], "contactEmail": email,
                 "contactPhone": phone, "notes": R["notes"], "demoAccountRequired": False}
        try:
            d = c.get(f"/v1/appStoreVersions/{vid}/appStoreReviewDetail")["data"]
        except Exception:
            d = None
        if d:
            c.patch(f"/v1/appStoreReviewDetails/{d['id']}", {"data": {"type": "appStoreReviewDetails", "id": d["id"], "attributes": attrs}})
        else:
            c.post("/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
    step("review contact + notes", review)

    def shots():
        vl = holder.get("vl") or vloc()
        sets = c.get(f"/v1/appStoreVersionLocalizations/{vl['id']}/appScreenshotSets")["data"]
        ss = next((x for x in sets if x["attributes"]["screenshotDisplayType"] == "APP_DESKTOP"), None)
        if not ss:
            ss = c.post("/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_DESKTOP"},
                "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": vl["id"]}}}}})["data"]
        for old in c.get(f"/v1/appScreenshotSets/{ss['id']}/appScreenshots")["data"]:
            c._call("DELETE", f"/v1/appScreenshots/{old['id']}")
        for path in L["screenshots"]:
            data = open(os.path.join(ROOT, path), "rb").read()
            shot = c.post("/v1/appScreenshots", {"data": {"type": "appScreenshots",
                "attributes": {"fileName": os.path.basename(os.path.dirname(path)) + "-" + os.path.basename(path), "fileSize": len(data)},
                "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": ss["id"]}}}}})["data"]
            for op in shot["attributes"]["uploadOperations"]:
                req = urllib.request.Request(op["url"], data=data[op["offset"]:op["offset"] + op["length"]], method=op["method"])
                for h in op.get("requestHeaders", []):
                    req.add_header(h["name"], h["value"])
                urllib.request.urlopen(req, timeout=120).read()
            c.patch(f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
                "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
            print(f"    uploaded {path}")
    step("screenshots", shots)
    print("App privacy (\"Data Not Collected\") is not exposed by the API — set it once in App Store Connect → App Privacy.")


def upload():
    pkgs = sorted(glob.glob(os.path.join(ROOT, "dist-mas", "*.pkg")), key=os.path.getmtime)
    if not pkgs:
        sys.exit("no dist-mas/*.pkg — run scripts/build-mas.sh")
    kid, iss = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
    auth = ["--apiKey", kid, "--apiIssuer", iss]
    for action in ("--validate-app", "--upload-app"):
        print(f"==> altool {action} {os.path.basename(pkgs[-1])}")
        subprocess.check_call(["xcrun", "altool", action, "-f", pkgs[-1], "-t", "osx"] + auth)


def submit():
    c = client()
    app_id = the_app(c)["id"]
    v = editable_version(c, app_id)
    # The build number is whatever the newest uploaded package was built with (Hushpiece-<ver>-<build>.pkg).
    pkgs = sorted(glob.glob(os.path.join(ROOT, "dist-mas", "*.pkg")), key=os.path.getmtime)
    build_no = os.environ.get("MAS_BUILD_NUMBER") or os.path.basename(pkgs[-1]).rsplit("-", 1)[1][:-4]
    deadline = time.time() + 3600
    while True:
        b = c.find_build(app_id, "MAC_OS", build_no)
        state = b["attributes"].get("processingState") if b else "NOT_YET_VISIBLE"
        print(f"  build {build_no}: {state}")
        if state == "VALID":
            break
        if state in ("FAILED", "INVALID") or time.time() > deadline:
            sys.exit(f"build {build_no} is {state}")
        time.sleep(30)
    c.attach_build(v["id"], b["id"])
    c.submit_for_review(app_id, "MAC_OS", v["id"])
    print("submitted for review")


if __name__ == "__main__":
    {"setup": setup, "app": app, "listing": listing, "upload": upload, "submit": submit}[sys.argv[1] if len(sys.argv) > 1 else "app"]()
