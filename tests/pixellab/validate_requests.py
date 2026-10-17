"""Validates request bodies saved by the bridge test against the real OpenAPI schemas."""
import json, sys
from jsonschema import Draft202012Validator
spec = json.load(open(sys.argv[1]))
names = {"/generate-8-rotations-v3": "Generate8RotationsV3Request", "/rotate": "RotateRequest",
         "/animate-with-text-v3": "AnimateWithTextV3Request", "/interpolation-v2": "InterpolationV2Request"}
ok = True
for line in open(sys.argv[2]):
    item = json.loads(line)
    v = Draft202012Validator({"$ref": f"#/components/schemas/{names[item['path']]}", "components": spec["components"]})
    errors = [f"{list(e.absolute_path)}: {e.message[:160]}" for e in v.iter_errors(item["body"])]
    ok &= not errors
    print(item["label"], item["path"], "VALID" if not errors else f"INVALID {errors}")
sys.exit(0 if ok else 1)
