#!/usr/bin/env python3
"""Turn live findings into `source/live_overrides.json` patches, mechanically.

    mix run scripts/explain.exs --json     # writes tmp/findings.json
    python3 scripts/overrides.py           # print the patches it would write
    python3 scripts/overrides.py --write   # write them

A finding already names its own fix:

* the provider sends an explicit `null`            -> the field is nullable
* the provider sends an object where the document  -> the field is a union of the
  declares an array                                    array and the marker
* the provider sends `{"disabled": true}` where    -> the field is a union of its
  the document declares an object                      schema and `Disabled`
* the value is outside a documented enum           -> the enum is stale, widen it
* the provider omits a required field and the      -> that field stops being
  parent is the document's own object                  required

Each patch carries the observation that justified it, so the override file stays
something a reader can argue with. Findings the rules cannot classify are
printed as `manual` with the reason — usually a `oneOf` with no matching variant,
which the fields inside it resolve rather than the union itself.
"""

import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SPEC = json.loads((REPO / "source" / "openapi.json").read_text())
OVERRIDES = REPO / "source" / "live_overrides.json"
FINDINGS = REPO / "tmp" / "findings.json"

DISABLED = {"$ref": "#/components/schemas/Disabled_2024_06_14"}
NULLABLE = re.compile(r"^refused nil; contract is (?P<kind>.+)$")
ARRAY_OBJECT = re.compile(r"^contract wants an array, response has an object$")
OBJECT_ARRAY = re.compile(r"^contract wants an object, response has an array$")
ABSENT = re.compile(r"^required by the contract, absent from the response$")
ENUM = re.compile(r"^refused .*; contract is \{:enum,")


def deref(node):
    """Follow `$ref`s to the schema they name."""
    seen = 0
    while isinstance(node, dict) and "$ref" in node and seen < 10:
        node = SPEC["components"]["schemas"][node["$ref"].split("/")[-1]]
        seen += 1
    return node


def variant_holding(node, segment):
    """The `oneOf` variant that declares `segment`, if any."""
    for option in node.get("oneOf", node.get("anyOf", [])):
        target = deref(option)
        if segment in target.get("properties", {}):
            return option, target
    return None, None


def locate(operation_id, status, path):
    """Resolve a finding's JSON path to the property that refused it, and its parent.

    Returns `{"leaf": {...}, "parent": {...}}`; either may be absent when the
    path leaves the named document.
    """
    method, route = operation_id.split(" ", 1)
    operation = SPEC["paths"][route][method.lower()]
    response = operation["responses"][str(status)]["content"]["application/json"]["schema"]
    owner = response.get("$ref", "").split("/")[-1] or None
    node = deref(response)
    parent = None

    segments = [re.sub(r"\[\d+\]$", "", part) for part in path.split(".") if part]
    segments = [part for part in segments if part != "value"]

    for index, segment in enumerate(segments):
        last = index == len(segments) - 1
        properties = node.get("properties", {})

        if segment in properties:
            if last:
                return {
                    "leaf": {"owner": owner, "name": segment, "schema": properties[segment]},
                    "parent": parent,
                }

            parent = {"owner": owner, "name": segment, "schema": properties[segment]}
            schema = properties[segment]
            node = deref(schema)

            if schema.get("$ref"):
                owner = schema["$ref"].split("/")[-1]

            if "oneOf" in node or "anyOf" in node:
                option, target = variant_holding(node, segments[index + 1])
                if target is None:
                    return {"leaf": None, "parent": parent}
                schema, node = option, target
                owner = option.get("$ref", "").split("/")[-1] or owner

            continue

        if node.get("type") == "array":
            node = deref(node.get("items", {}))
            if node.get("$ref"):
                owner = node["$ref"].split("/")[-1]
            continue

        return {"leaf": None, "parent": parent}

    return {"leaf": None, "parent": parent}


def decide(finding, located):
    """The patch a finding maps to, and the property it belongs on."""
    why = finding["why"]
    leaf = located.get("leaf")
    parent = located.get("parent")
    evidence = f"Live evidence: {finding['operation']} answered {finding['status']} and {why}."

    if NULLABLE.match(why) and leaf:
        return leaf, {"nullable": True, "description": f"The provider sends an explicit null here. {evidence}"}

    if ARRAY_OBJECT.match(why) and leaf:
        return leaf, {
            "oneOf": [leaf["schema"], DISABLED],
            "description": f"The provider answers the disabled marker here. {evidence}",
        }

    if OBJECT_ARRAY.match(why) and leaf:
        items = leaf["schema"].get("items")
        if items:
            return leaf, {"oneOf": [leaf["schema"], items], "description": evidence}
        return None, "an array answer with no item schema to union with"

    if ENUM.match(why) and leaf:
        return leaf, {"type": "string", "description": f"The documented enum is stale. {evidence}"}

    if ABSENT.match(why):
        observed_parent = finding.get("parent")

        if isinstance(observed_parent, dict) and "disabled" in observed_parent and parent:
            # The union belongs on the parent property, and its first arm is the
            # schema that property already names — not the schema that holds it.
            arm = parent["schema"].get("$ref") or f"#/components/schemas/{leaf['owner']}"
            return parent, {
                "oneOf": [{"$ref": arm}, DISABLED],
                "description": f"The provider answers the disabled marker, not a {arm.split('/')[-1]}. {evidence}",
            }

        if leaf:
            return leaf, "required"

        return None, "a required field the document's own object omitted"

    if "no variant accepted it" in why:
        return None, "a union with no matching variant: the fields inside it decide this"

    return None, "unclassified"


def main(argv):
    if not FINDINGS.exists():
        print(f"no findings at {FINDINGS}: run `mix run scripts/explain.exs --json` first")
        return 1

    findings = json.loads(FINDINGS.read_text())
    overrides = json.loads(OVERRIDES.read_text())
    properties = overrides.setdefault("schema_properties", {})
    required = overrides.setdefault("schema_required", {})

    applied, manual = [], []

    for finding in findings:
        target, patch = decide(finding, locate(finding["operation"], finding["status"], finding["path"]))

        if target is None:
            manual.append((finding, patch))
            continue

        if patch == "required":
            owner, name = target["owner"], target["name"]

            if owner not in required:
                document = SPEC["components"]["schemas"][owner].get("required", [])
                required[owner] = [field for field in document if field != name]

            applied.append((finding, f"{owner}: `required` drops {name}"))
            continue

        properties.setdefault(target["owner"], {})[target["name"]] = patch
        applied.append((finding, f"{target['owner']}.{target['name']} <- {json.dumps(patch)[:70]}"))

    for finding, what in applied:
        print(f"PATCH  {finding['operation']} {finding['path']}\n       {what}")
    for finding, why in manual:
        print(f"MANUAL {finding['operation']} {finding['path']}\n       {finding['why']}  ({why})")

    print(f"\n{len(applied)} patches, {len(manual)} for a human")

    if "--write" in argv and applied:
        OVERRIDES.write_text(json.dumps(overrides, indent=2) + "\n")
        print(f"wrote {OVERRIDES.relative_to(REPO)}")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
