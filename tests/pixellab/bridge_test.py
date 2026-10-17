"""Drives the AI Studio bridge end to end against the mock PixelLab API (tests/pixellab/mock_api.py).

Usage: bridge_test.py <bridge.json> <requests.jsonl> [no-token]. Request bodies from dry runs are
written to requests.jsonl for validate_requests.py. With no-token, Pixelorama runs without a
PixelLab token and every PixelLab entry point must fail at once. Run it through
scripts/test-pixellab.sh."""
import json, socket, sys, threading, time
from pathlib import Path

INFO = Path(sys.argv[1])
DRY = open(sys.argv[2], "w")
results = []


def call(method, params=None, timeout=120):
    info = json.loads(INFO.read_text())
    with socket.create_connection((info["host"], info["port"]), timeout=timeout) as s:
        s.sendall((json.dumps({"id": 1, "token": info["token"], "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf)


def check(label, cond, detail=""):
    results.append((label, bool(cond)))
    print(("PASS " if cond else "FAIL ") + label + (f"  -> {detail}" if detail and not cond else ""))


def sprite(rows=24, cols=20, ch="1"):
    return [ch * cols for _ in range(rows)]


for _ in range(60):
    if INFO.exists():
        break
    time.sleep(0.5)

if len(sys.argv) > 3 and sys.argv[3] == "no-token":
    DRY.close()
    call("new_project", {"width": 64, "height": 64, "name": "offline"})
    call("paint_grid", {"x": 22, "y": 20, "palette": ["#00000000", "#ff8800"], "rows": sprite(), "frame": 0, "layer": 0})
    attempts = [("balance", "pixellab_balance", {}),
                ("pixflux generate", "generate", {"engine": "pixellab", "prompt": "a potion"})]
    for tool in ("rotations", "rotate", "animate", "interpolate"):
        for dry in (False, True):
            attempts.append((f"{tool} dry_run={dry}", "pixellab_tool",
                             {"tool": tool, "description": "walking", "end_frame": 0, "dry_run": dry}))
    for label, method, params in attempts:
        started = time.monotonic()
        r = call(method, params)
        elapsed = time.monotonic() - started
        check(f"no token: {label} fails at once", "PixelLab is not connected" in r.get("error", "") and elapsed < 1.0,
              (r, round(elapsed, 2)))
    info = call("get_project_info")["result"]
    check("no token: canvas untouched", info["frames"] == 1 and len(info["layers"]) == 1, info)
    print(f"\n{sum(ok for _, ok in results)}/{len(results)} passed")
    sys.exit(0 if all(ok for _, ok in results) else 1)

call("new_project", {"width": 64, "height": 64, "name": "t64"})
call("paint_grid", {"x": 22, "y": 20, "palette": ["#00000000", "#ff8800"], "rows": sprite(), "frame": 0, "layer": 0})

# Dry runs: request bodies for the schema check, and the balance shown before spending.
dry_cases = [
    ("rotations", {"tool": "rotations", "description": "a knight", "seed": 7}),
    ("rotations-noseed", {"tool": "rotations"}),
    ("rotate", {"tool": "rotate", "from_direction": "south", "to_direction": "west", "from_view": "side", "to_view": "low top-down", "use_palette": True, "seed": 3}),
    ("animate", {"tool": "animate", "description": "walking", "frame_count": 8, "seed": 1}),
    ("animate-16", {"tool": "animate", "description": "attack combo", "frame_count": 16, "remove_background": False}),
]
for label, params in dry_cases:
    r = call("pixellab_tool", {**params, "dry_run": True})
    ok = "result" in r and r["result"].get("dry_run")
    check(f"dry run {label}", ok, r.get("error"))
    if ok:
        DRY.write(json.dumps({"label": label, "path": r["result"]["path"], "body": r["result"]["body"]}) + "\n")
        if label == "rotations":
            check("dry run reports balance", r["result"]["balance"].get("usd") == 12.5, r["result"]["balance"])
            check("64px canvas sent whole", r["result"]["region"] == [0, 0, 64, 64], r["result"]["region"])

call("add_frame", {"after": 0})
call("paint_grid", {"x": 26, "y": 14, "palette": ["#00000000", "#22aaff"], "rows": sprite(18, 14), "frame": 1, "layer": 0})
r = call("pixellab_tool", {"tool": "interpolate", "description": "powering up", "frame": 0, "end_frame": 1, "use_palette": True, "dry_run": True})
check("dry run interpolate", "result" in r, r.get("error"))
if "result" in r:
    DRY.write(json.dumps({"label": "interpolate", "path": r["result"]["path"], "body": r["result"]["body"]}) + "\n")
DRY.close()

# Local validation, before any request.
for label, params, needle in [
    ("odd frame_count", {"tool": "animate", "description": "x", "frame_count": 5}, "even"),
    ("frame_count 18", {"tool": "animate", "description": "x", "frame_count": 18}, "even"),
    ("empty action", {"tool": "animate", "description": ""}, "action"),
    ("same keyframe", {"tool": "interpolate", "description": "x", "frame": 0, "end_frame": 0}, "different"),
    ("bad direction", {"tool": "rotate", "to_direction": "up"}, "direction"),
    ("bad view", {"tool": "rotate", "from_view": "iso"}, "view"),
    ("bad placement", {"tool": "rotations", "placement": "grid"}, "placement"),
    ("unknown tool", {"tool": "zoom"}, "unknown tool"),
    ("missing frame", {"tool": "rotations", "frame": 9}, "does not exist"),
]:
    r = call("pixellab_tool", params)
    check(f"rejects {label}", needle in r.get("error", ""), r)

# Big canvas: the sprite's bounds plus a margin are sent, results go back to the same place.
call("new_project", {"width": 300, "height": 300, "name": "t300"})
call("paint_grid", {"x": 140, "y": 150, "palette": ["#00000000", "#55ff55"], "rows": sprite(30, 20), "frame": 0, "layer": 0})
r = call("pixellab_tool", {"tool": "rotate", "dry_run": True})
region = r.get("result", {}).get("region")
check("300px canvas crops to sprite + margin", region and region[2] <= 200 and region[0] <= 140 and region[0] + region[2] >= 160, r)
r = call("pixellab_tool", {"tool": "animate", "description": "idle", "frame_count": 16, "dry_run": True})
region = r.get("result", {}).get("region")
check("animate keeps w*h*frames within budget", region and region[2] * region[3] * 16 <= 524288, r)
r = call("pixellab_tool", {"tool": "rotate", "to_direction": "north"})
check("rotate (sync) on 300px canvas", "result" in r and r["result"]["images"] == 1, r)
info = call("get_project_info")["result"]
check("rotate added a layer", len(info["layers"]) == 2, info["layers"])
rotate_region = r.get("result", {}).get("region", [0, 0, 1, 1])
inside = call("read_pixels", {"x": rotate_region[0] + rotate_region[2] // 2, "y": rotate_region[1] + rotate_region[3] // 2,
                              "width": 1, "height": 1, "frame": 0, "layer": info["current_layer"]})["result"]
outside = call("read_pixels", {"x": 0, "y": 0, "width": 1, "height": 1, "frame": 0, "layer": info["current_layer"]})["result"]
check("rotate result sits in the source region",
      inside["palette"][0].lower() != "#00000000" and outside["palette"][0].lower() == "#00000000", (inside, outside))
check("rotate reports usage", r.get("result", {}).get("usage", {}).get("usd") == 0.007, r.get("result", {}).get("usage"))

# Background jobs and placement on the 64px project.
call("new_project", {"width": 64, "height": 64, "name": "jobs"})
call("paint_grid", {"x": 22, "y": 20, "palette": ["#00000000", "#ff8800"], "rows": sprite(), "frame": 0, "layer": 0})
r = call("pixellab_tool", {"tool": "rotations"}, timeout=120)
info = call("get_project_info")["result"]
check("8 rotations -> 8 new frames", "result" in r and info["frames"] == 9, r if "error" in r else info["frames"])
check("rotations report job usage + balance_before", r.get("result", {}).get("usage", {}).get("generations") == 4 and "balance_before" in r.get("result", {}), r.get("result"))
pix = call("read_pixels", {"x": 0, "y": 0, "width": 64, "height": 64, "frame": 3, "layer": 0})["result"]
check("rotation frame holds pixels", any(c.lower() != "#00000000" for c in pix.get("palette", [])), pix.get("palette"))
u = call("undo")
info = call("get_project_info")["result"]
check("one undo removes all 8 frames", info["frames"] == 1, (u, info["frames"]))
call("redo")
check("redo restores them", call("get_project_info")["result"]["frames"] == 9)
call("undo")

r = call("pixellab_tool", {"tool": "rotations", "description": "dict", "placement": "layers"})
info = call("get_project_info")["result"]
names = [l["name"] for l in info["layers"]]
check("rotations as layers named by direction", "result" in r and len(names) == 9 and "AI: south-west" in names, r if "error" in r else names)
call("undo")
check("one undo removes all 8 layers", len(call("get_project_info")["result"]["layers"]) == 1)

r = call("pixellab_tool", {"tool": "animate", "description": "walking", "frame_count": 6})
info = call("get_project_info")["result"]
check("animate -> 6 consecutive frames", "result" in r and info["frames"] == 7 and r["result"]["frames"] == [1, 2, 3, 4, 5, 6], r if "error" in r else r["result"])

call("paint_grid", {"x": 26, "y": 14, "palette": ["#00000000", "#22aaff"], "rows": sprite(18, 14), "frame": 6, "layer": 0})
r = call("pixellab_tool", {"tool": "interpolate", "description": "morph", "frame": 0, "end_frame": 6})
info = call("get_project_info")["result"]
check("interpolate (202 job, nested images) inserts 4 frames after start", "result" in r and info["frames"] == 11 and r["result"]["frames"] == [1, 2, 3, 4], r if "error" in r else r["result"])

r = call("pixellab_tool", {"tool": "rotations", "description": "fail"})
check("failed job surfaces detail", "mock failure" in r.get("error", ""), r)

box = {}
t = threading.Thread(target=lambda: box.update(r=call("pixellab_tool", {"tool": "rotations", "description": "slow"})))
t.start(); time.sleep(5)
call("cancel"); t.join(30)
check("cancel stops a running job", "cancelled" in box.get("r", {}).get("error", ""), box)
r = call("pixellab_tool", {"tool": "rotations", "description": "slow", "dry_run": True})
check("generator free again after cancel", "result" in r, r)

b = call("pixellab_balance")
check("balance", b.get("result", {}).get("generations") == 900, b)

print(f"\n{sum(ok for _, ok in results)}/{len(results)} passed")
sys.exit(0 if all(ok for _, ok in results) else 1)
