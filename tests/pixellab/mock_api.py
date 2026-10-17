"""Local stand-in for api.pixellab.ai/v2: validates request bodies against the published OpenAPI
schema (422 on mismatch, like the API) and answers with synthetic images via background jobs.

Usage: mock_api.py <openapi.json> <log.jsonl> <port>. Accepts only "Bearer mock-token".
The description of a rotations request selects a scenario: "dict" (images keyed by direction),
"fail" (failed job) or "slow" (never finishes, for cancellation)."""
import base64, json, struct, sys, zlib, itertools
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from jsonschema import Draft202012Validator

SPEC = json.load(open(sys.argv[1]))
LOG = open(sys.argv[2], "a")
PORT = int(sys.argv[3])
TOKEN = "mock-token"
SCHEMAS = {
    "/v2/generate-8-rotations-v3": "Generate8RotationsV3Request",
    "/v2/rotate": "RotateRequest",
    "/v2/animate-with-text-v3": "AnimateWithTextV3Request",
    "/v2/interpolation-v2": "InterpolationV2Request",
    "/v2/create-image-pixflux": None,
}
DIRS = ["south", "south-east", "east", "north-east", "north", "north-west", "west", "south-west"]
jobs, counter = {}, itertools.count(1)


def validator(name):
    return Draft202012Validator({"$ref": f"#/components/schemas/{name}", "components": SPEC["components"]})


def png(w, h, rgba):
    raw = b"".join(b"\0" + bytes(rgba) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def b64img(w, h, i, data_url=False):
    data = base64.b64encode(png(w, h, (40 * i % 256, 255 - 30 * i % 256, 90, 255))).decode()
    return {"type": "base64", "base64": ("data:image/png;base64," + data) if data_url else data, "format": "png"}


def size_of(b64):
    raw = base64.b64decode(b64.split(",")[-1])
    return struct.unpack(">II", raw[16:24])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self.reply(401, {"detail": "Invalid API token"})
            return False
        return True

    def do_GET(self):
        if not self.authed():
            return
        if self.path == "/v2/balance":
            return self.reply(200, {"credits": {"type": "usd", "usd": 12.5},
                                    "subscription": {"type": "generations", "status": "active", "plan": "mock",
                                                     "generations": 900, "total": 1000}})
        if self.path.startswith("/v2/background-jobs/"):
            job = jobs.get(self.path.rsplit("/", 1)[1])
            if job is None:
                return self.reply(404, {"detail": "not found"})
            job["polls"] += 1
            LOG.write(json.dumps({"poll": job["id"], "n": job["polls"]}) + "\n"); LOG.flush()
            if job["polls"] < 2:
                return self.reply(200, {"id": job["id"], "status": "processing", "created_at": "now",
                                        "last_response": {"queue_position": 3}})
            return self.reply(200, {"id": job["id"], "status": job.get("final", "completed"), "created_at": "now",
                                    "usage": {"type": "generations", "generations": 4},
                                    "last_response": job["result"]})
        self.reply(404, {"detail": "Not Found"})

    def do_DELETE(self):
        if not self.authed():
            return
        LOG.write(json.dumps({"delete": self.path}) + "\n"); LOG.flush()
        self.reply(200, {"id": self.path.rsplit("/", 1)[1], "status": "failed", "message": "cancelled"})

    def do_POST(self):
        if not self.authed():
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        name = SCHEMAS.get(self.path, "missing")
        errors = [] if name is None else ([{"msg": "unknown path"}] if name == "missing" else
                  [{"loc": list(e.absolute_path), "msg": e.message[:200], "type": e.validator}
                   for e in validator(name).iter_errors(body)])
        LOG.write(json.dumps({"path": self.path, "valid": not errors, "errors": errors,
                              "keys": sorted(body)}) + "\n"); LOG.flush()
        if errors:
            return self.reply(422, {"detail": errors})
        job_id = f"job-{next(counter)}"
        if self.path.endswith("/rotate"):
            w, h = body["image_size"]["width"], body["image_size"]["height"]
            return self.reply(200, {"usage": {"type": "usd", "usd": 0.007}, "image": b64img(w, h, 5)})
        if self.path.endswith("/generate-8-rotations-v3"):
            w, h = size_of(body["first_frame"]["base64"])
            if body.get("description") == "dict":
                result = {"images": {d: b64img(w, h, i, data_url=True) for i, d in enumerate(DIRS)}}
            else:
                result = {"images": [b64img(w, h, i) for i in range(8)]}
            jobs[job_id] = {"id": job_id, "polls": 0, "result": result}
            if body.get("description") == "fail":
                jobs[job_id]["final"] = "failed"; jobs[job_id]["result"] = {"detail": "mock failure"}
            if body.get("description") == "slow":
                jobs[job_id]["polls"] = -1000
            return self.reply(200, {"background_job_id": job_id, "status": "processing"})
        if self.path.endswith("/animate-with-text-v3"):
            w, h = size_of(body["first_frame"]["base64"])
            jobs[job_id] = {"id": job_id, "polls": 0,
                            "result": {"images": [b64img(w, h, i) for i in range(body.get("frame_count", 8))]}}
            return self.reply(200, {"background_job_id": job_id, "status": "processing"})
        if self.path.endswith("/interpolation-v2"):
            w, h = body["image_size"]["width"], body["image_size"]["height"]
            jobs[job_id] = {"id": job_id, "polls": 0, "result": {"frames": [{"image": b64img(w, h, i)} for i in range(4)]}}
            return self.reply(202, {"background_job_id": job_id, "status": "processing", "usage": {"type": "usd", "usd": 0.0}})
        w, h = body["image_size"]["width"], body["image_size"]["height"]
        return self.reply(200, {"image": b64img(w, h, 1)})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
