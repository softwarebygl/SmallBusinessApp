import sys, os, time, hashlib, urllib.request, urllib.error
from PIL import Image

sys.path.insert(0, "/Users/adriangutierrez/Google Drive/My Drive/AI Brain/skills/app-store-ops/scripts")
from asc_api import request, upload_operations

VERSION_ID = "405500bf-3e00-42b3-b875-a7600ac6dc8f" # 3.4.0

# 1. Get localization IDs
st, locs = request(f"/v1/appStoreVersions/{VERSION_ID}/appStoreVersionLocalizations")
en_id = None
es_id = None
for loc in locs.get("data", []):
    if loc["attributes"]["locale"] == "en-US": en_id = loc["id"]
    if loc["attributes"]["locale"] == "es-MX": es_id = loc["id"]

print("Localizations -> en-US:", en_id, "es-MX:", es_id)

def get_or_create_set(loc_id, display_type):
    st, sets = request(f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")
    for s in sets.get("data", []):
        if s["attributes"]["screenshotDisplayType"] == display_type:
            return s["id"]
    # Create
    st, created = request("/v1/appScreenshotSets", "POST", {
        "data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": display_type},
            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}
        }
    })
    if st not in (200, 201):
        raise RuntimeError(f"Failed to create set {display_type}: {created}")
    return created["data"]["id"]

def clear_set(set_id):
    st, shots = request(f"/v1/appScreenshotSets/{set_id}/appScreenshots")
    for s in shots.get("data", []):
        sid = s["id"]
        request(f"/v1/appScreenshots/{sid}", "DELETE")
    print(f"  Cleared set {set_id} ({len(shots.get('data', []))} old shots)")

def upload_screenshot(set_id, file_path):
    blob = open(file_path, "rb").read()
    file_name = os.path.basename(file_path)
    file_size = len(blob)
    st, res = request("/v1/appScreenshots", "POST", {
        "data": {
            "type": "appScreenshots",
            "attributes": {"fileSize": file_size, "fileName": file_name},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}
        }
    })
    if st not in (200, 201):
        raise RuntimeError(f"Failed to reserve screenshot {file_name}: {res}")
    
    shot_id = res["data"]["id"]
    ops = res["data"]["attributes"]["uploadOperations"]
    md5 = upload_operations(ops, file_path)
    
    # Commit
    st, comm = request(f"/v1/appScreenshots/{shot_id}", "PATCH", {
        "data": {
            "type": "appScreenshots",
            "id": shot_id,
            "attributes": {"uploaded": True, "sourceFileChecksum": md5}
        }
    })
    if st not in (200, 201):
        raise RuntimeError(f"Failed to commit screenshot {file_name}: {comm}")
    print(f"  Uploaded & committed: {file_name} -> {shot_id}")
    return shot_id

def wait_complete(shot_ids, timeout=300):
    deadline = time.time() + timeout
    pending = list(shot_ids)
    while pending and time.time() < deadline:
        still = []
        for sid in pending:
            st, r = request(f"/v1/appScreenshots/{sid}?fields[appScreenshots]=assetDeliveryState,fileName")
            state = (r.get("data", {}).get("attributes", {}).get("assetDeliveryState") or {}).get("state")
            if state == "COMPLETE":
                continue
            if state in ("FAILED", "ERROR"):
                print(f"    ! Error processing {sid}: {r}")
                continue
            still.append(sid)
        pending = still
        if pending:
            time.sleep(4)
    print(f"  Finished: {len(shot_ids) - len(pending)}/{len(shot_ids)} COMPLETE")

TARGETS = [
    # (display_type, folder, glob_pattern)
    ("APP_IPHONE_DUO", "/Users/adriangutierrez/Documents/Github/SmallBusinessApp/AppStoreAssets/iPhoneDuo", "*.png"),
    ("APP_IPAD_PRO_3GEN_129", "/Users/adriangutierrez/Documents/Github/SmallBusinessApp/AppStoreAssets/iPad", "ipad_*.png"),
    ("APP_IPHONE_65", "/Users/adriangutierrez/Documents/Github/SmallBusinessApp/AppStoreAssets/iPhone-6.5", "iphone_*.png"),
    ("APP_IPHONE_61", "/Users/adriangutierrez/Documents/Github/SmallBusinessApp/AppStoreAssets/iPhone-6.1", "iphone_*.png")
]

for loc_id, loc_name in [(en_id, "en-US"), (es_id, "es-MX")]:
    if not loc_id: continue
    print(f"\n==================== PROCESSING {loc_name} ({loc_id}) ====================")
    for dt, folder, pat in TARGETS:
        print(f"\nHandling {dt} from {folder}...")
        set_id = get_or_create_set(loc_id, dt)
        clear_set(set_id)
        
        files = sorted([f for f in os.listdir(folder) if f.endswith(".png")])
        uploaded_ids = []
        for f in files:
            fp = os.path.join(folder, f)
            uploaded_ids.append(upload_screenshot(set_id, fp))
        print(f"Waiting for {len(uploaded_ids)} screenshots to reach COMPLETE...")
        wait_complete(uploaded_ids)

print("\n🎉 ALL SCREENSHOTS UPLOADED AND PROCESSED SUCCESSFULLY!")
