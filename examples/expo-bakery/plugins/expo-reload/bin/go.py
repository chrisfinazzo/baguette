#!/usr/bin/env python3
"""Send Cmd+KeyR to the focused device — the RN/Expo Reload chord."""
import json, os, sys, urllib.request, urllib.error

base  = os.environ.get("BAGUETTE_URL")
udid  = os.environ.get("BAGUETTE_UDID")
token = os.environ.get("BAGUETTE_TOKEN", "")
if not base or not udid:
    print(json.dumps({"ok": False, "message": "No device focused"})); sys.exit(0)

envelope = {"type": "key", "code": "KeyR", "modifiers": ["command"]}
req = urllib.request.Request(
    f"{base}/simulators/{udid}/input",
    data=json.dumps(envelope).encode(),
    headers={"content-type": "application/json", "X-Baguette-Token": token},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=5) as r:
        ack = json.load(r)
except urllib.error.HTTPError as e:
    print(json.dumps({"ok": False, "message": f"{e.code}: {e.read().decode()[:160]}"})); sys.exit(0)
except Exception as e:
    print(json.dumps({"ok": False, "message": str(e)})); sys.exit(0)

if not ack.get("ok"):
    print(json.dumps({"ok": False, "message": ack.get("error", "input rejected")})); sys.exit(0)
print(json.dumps({"ok": True, "rows": [{"title": "Reload sent (⌘R)", "severity": "info"}]}))
