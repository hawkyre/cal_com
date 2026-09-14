"""Check schema normalization and the recorded source hash against the spec."""
import ast
import hashlib
import json
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "source"
TREE = ast.parse((SOURCE / "generate.py").read_text())
FUNCTIONS = [node for node in TREE.body if isinstance(node, ast.FunctionDef) and node.name in {"canonical_shape", "merge_all"}]
ORIGINAL = json.loads((SOURCE / "openapi.json").read_text())
NAMESPACE = {"schemas": ORIGINAL["components"]["schemas"]}
exec(compile(ast.Module(body=FUNCTIONS, type_ignores=[]), "generate.py", "exec"), NAMESPACE)
NORMALIZE = NAMESPACE["canonical_shape"]


class NormalizationTest(unittest.TestCase):
    def assert_properties(self, source, normalized):
        if isinstance(source, list):
            for before, after in zip(source, normalized, strict=True):
                self.assert_properties(before, after)
        elif isinstance(source, dict):
            for key, value in source.items():
                if key == "properties":
                    self.assertEqual(set(value), set(normalized[key]))
                    for name, contract in value.items():
                        self.assert_properties(contract, normalized[key][name])
                elif key not in {"description", "example", "examples", "title", "externalDocs"}:
                    self.assert_properties(value, normalized[key])

    def test_every_original_schema_preserves_property_names(self):
        original = json.loads((SOURCE / "openapi.json").read_text())
        for name, schema in original["components"]["schemas"].items():
            with self.subTest(schema=name):
                self.assert_properties(schema, NORMALIZE(schema))

    def test_nested_annotation_names_are_fields(self):
        names = {"description", "example", "examples", "title", "externalDocs"}
        child = {"type": "object", "properties": {name: {"type": "string", "description": "annotation"} for name in names}}
        source = {"type": "object", "title": "annotation", "properties": {name: child for name in names}}
        normalized = NORMALIZE(source)
        self.assertNotIn("title", normalized)
        self.assertEqual(names, set(normalized["properties"]))
        self.assert_properties(source, normalized)

    def test_required_slug_survives_the_original_patch_field_union(self):
        source = ORIGINAL["components"]["schemas"]["PatchBookingFieldsInput_2026_06_12"]["properties"]["bookingFields"]["items"]
        merged = NAMESPACE["merge_all"](source)
        choices = source["allOf"][1]["anyOf"]
        self.assertEqual(len(choices), len(merged["anyOf"]))
        for before, after in zip(choices, merged["anyOf"], strict=True):
            original = ORIGINAL["components"]["schemas"][before["$ref"].split("/")[-1]]
            self.assertEqual(original["properties"], after["properties"])
            self.assertIn("slug", after["required"])

    def test_recorded_hash_matches_the_spec(self):
        recorded = (SOURCE / "SOURCE_HASH").read_text().strip()
        self.assertEqual(recorded, hashlib.sha256((SOURCE / "openapi.json").read_bytes()).hexdigest())

    def test_cancellation_variants_retain_documented_fields_and_required_flags(self):
        operation = ORIGINAL["paths"]["/v2/bookings/{bookingUid}/cancel"]["post"]
        declared = operation["requestBody"]["content"]["application/json"]["schema"]["oneOf"]
        overrides = json.loads((SOURCE / "live_overrides.json").read_text())
        variants = overrides["operation_bodies"]["POST /v2/bookings/{bookingUid}/cancel"]["oneOf"]
        for reference, variant in zip(declared, variants, strict=True):
            source = ORIGINAL["components"]["schemas"][reference["$ref"].split("/")[-1]]
            self.assertEqual(NORMALIZE(source["properties"]), NORMALIZE(variant["properties"]))
            self.assertEqual(source.get("required", []), variant.get("required", []))
            self.assertIs(variant["additionalProperties"], False)


if __name__ == "__main__":
    unittest.main()
