"""Render the Cal.com client from the checked-in spec. This command writes files.

The package's own tooling policy governs this generator, not Kithe's rule
against scripted edits: regeneration is one command, and the source hash in
`source/SOURCE_HASH` must match `source/openapi.json` before anything is
written, so a spec refresh cannot happen without an explicit hash update in
the same commit.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parent
CHUNK_BYTES = 24000  # Largest entity file a reviewer reads in one screenful.
OPERATIONS_PER_FILE = 5
LINE_LENGTH = 98  # `mix format`'s default; generated files must match it.

# Filled by main() so the pure helpers below stay importable and testable.
PREFIX = ""
ROOT_NS = ""
schemas = {}
objects = {}
canonical_objects = {}


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", default="CalCom", help="root module namespace")
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the generated files are current instead of writing them",
    )
    return parser.parse_args(argv)


def source_hash():
    return hashlib.sha256((SOURCE / "openapi.json").read_bytes()).hexdigest()


def check_source_hash():
    recorded = (SOURCE / "SOURCE_HASH").read_text().strip()
    actual = source_hash()
    if recorded != actual:
        print(
            "source hash mismatch\n  recorded: " + recorded + "\n  actual:   " + actual +
            "\nUpdate source/SOURCE_HASH in the same commit as the spec change.",
            file=sys.stderr,
        )
        raise SystemExit(1)


def literal(value):
    return json.dumps(value, ensure_ascii=False).replace("#{", r"\#{")


def atom(value):
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*[!?]?", value):
        return ":" + value
    return ":" + literal(value)


def snake(value):
    value = re.sub(r"([A-Z])([A-Z][a-z])", r"\1_\2", value)
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", value)
    return re.sub(r"[^A-Za-z0-9_]", "_", value).lower()


def module_name(value):
    return "".join(part[:1].upper() + part[1:] for part in re.split(r"[^A-Za-z0-9]", value) if part)


def canonical_shape(value):
    """Remove schema annotations without removing fields whose names match them."""
    annotations = {"description", "example", "examples", "title", "externalDocs"}
    if isinstance(value, list):
        return [canonical_shape(item) for item in value]
    if not isinstance(value, dict):
        return value
    return {key: ({field: canonical_shape(contract) for field, contract in item.items()}
                  if key == "properties" else canonical_shape(item))
            for key, item in value.items() if key not in annotations}


def register(schema, name):
    key = json.dumps(canonical_shape(schema), sort_keys=True, separators=(",", ":"))
    if key in canonical_objects:
        return canonical_objects[key]
    name = PREFIX + module_name(name)
    objects.setdefault(name, schema)
    canonical_objects[key] = name
    return name


def merge_all(schema):
    if "allOf" not in schema:
        return schema
    parts = [schemas[part["$ref"].split("/")[-1]] if "$ref" in part else part for part in schema["allOf"]]
    for index, part in enumerate(parts):
        for union in ("oneOf", "anyOf"):
            if union in part:
                siblings = parts[:index] + parts[index + 1:]
                return {union: [merge_all({"allOf": siblings + [choice]}) for choice in part[union]],
                        **{key: value for key, value in schema.items() if key != "allOf"}}
    merged = {"type": "object", "properties": {}, "required": []}
    for part in parts:
        if "$ref" in part:
            part = schemas[part["$ref"].split("/")[-1]]
        part = merge_all(part)
        for key, value in part.get("properties", {}).items():
            previous = merged["properties"].get(key)
            if previous is not None and previous != value:
                raise ValueError("Conflicting allOf field: " + key)
            merged["properties"][key] = value
        merged["required"] += part.get("required", [])
    merged.update({key: value for key, value in schema.items() if key != "allOf"})
    merged["required"] = sorted(set(merged["required"]))
    return merged


def rule(schema, name):
    if "$ref" in schema:
        ref_name = schema["$ref"].split("/")[-1]
        target = schemas[ref_name]
        if target.get("type") == "object" or "properties" in target:
            mod = register(target, ref_name)
            nullable = str(bool(schema.get("nullable"))).lower()
            return "%" + ROOT_NS + ".Rule{kind: {:object, " + mod + "}, nullable: " + nullable + "}", mod + ".t()"
        return rule(dict(target, **{key: value for key, value in schema.items() if key != "$ref"}), name)
    if len(schema.get("allOf", [])) == 1:
        return rule(dict(schema["allOf"][0], **{key: value for key, value in schema.items() if key != "allOf"}), name)
    schema = merge_all(schema)
    if "enum" in schema:
        pairs = []
        types = []
        for value in schema["enum"]:
            if value is None:
                continue
            encoded = atom(value) if isinstance(value, str) else literal(value)
            pairs.append("{" + literal(value) + ", " + encoded + "}")
            types.append(encoded if isinstance(value, (str, bool)) else "number()")
        kind = "{:enum, [" + ", ".join(pairs) + "]}"
        spec = " | ".join(dict.fromkeys(types)) or "nil"
    elif "oneOf" in schema or "anyOf" in schema:
        mode = "one_of" if "oneOf" in schema else "any_of"
        items = schema.get("oneOf", schema.get("anyOf"))
        choices = [rule(item, name + "Option" + str(index)) for index, item in enumerate(items)]
        kind = "{:" + mode + ", [" + ", ".join(item[0] for item in choices) + "]}"
        spec = " | ".join(item[1] for item in choices) if mode == "one_of" else ROOT_NS + ".Alternatives.t()"
    elif schema.get("type") == "object" or "properties" in schema:
        mod = register(schema, name)
        kind, spec = "{:object, " + mod + "}", mod + ".t()"
    elif schema.get("type") == "array":
        item, item_type = rule(schema.get("items", {}), name + "Item")
        kind, spec = "{:array, " + item + "}", "[" + item_type + "]"
    elif schema.get("type") == "string" and schema.get("format") in ("date", "date-time"):
        kind, spec = (":date", "Date.t()") if schema["format"] == "date" else (":datetime", "DateTime.t()")
    elif schema.get("type") in ("string", "integer", "number", "boolean"):
        kind = ":" + schema["type"]
        spec = {"string": "String.t()", "integer": "integer()", "number": "number()", "boolean": "boolean()"}[schema["type"]]
    else:
        kind, spec = ":json", ROOT_NS + ".Json.t()"
    nullable = bool(schema.get("nullable")) or None in schema.get("enum", []) or kind == ":json"
    parts = ["kind: " + kind, "nullable: " + str(nullable).lower()]
    keys = {"minimum": "minimum", "maximum": "maximum", "minLength": "min_length", "maxLength": "max_length",
            "minItems": "min_items", "maxItems": "max_items", "pattern": "pattern", "uniqueItems": "unique_items"}
    for source, target in keys.items():
        if source in schema:
            parts.append(target + ": " + literal(schema[source]))
    return "%" + ROOT_NS + ".Rule{" + ", ".join(parts) + "}", spec


def references(value):
    if isinstance(value, dict):
        if "$ref" in value:
            yield value["$ref"].split("/")[-1]
        for nested in value.values():
            yield from references(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from references(nested)


def selected_operations(original, operation_ids):
    operations = {}
    for operation_id in operation_ids:
        method, route = operation_id.split(" ", 1)
        operations[operation_id] = original["paths"][route][method.lower()]
    return operations


def reachable_schemas(original, operations):
    reachable = set(references(operations))
    pending = list(reachable)
    while pending:
        for name in references(original["components"]["schemas"][pending.pop()]):
            if name not in reachable:
                reachable.add(name)
                pending.append(name)
    return {name: original["components"]["schemas"][name] for name in sorted(reachable)}


def input_properties(operations, method_path, operation, path):
    properties = {}
    for part in ("path", "query", "header"):
        params = [item for item in operation.get("parameters", []) if item.get("in") == part
                  and not (part == "header" and item["name"].lower() in ("authorization", "cal-api-version"))]
        if part == "path":
            # The team-user OOO DELETE omits userId. Its sibling PATCH supplies
            # the source type for the same literal route placeholder.
            present = {item["name"] for item in params}
            for missing in set(re.findall(r"\{([^}]+)\}", path)) - present:
                candidates = [item for sibling_id, sibling in operations.items()
                              if sibling_id.split(" ", 1)[1] == path
                              for item in sibling.get("parameters", [])
                              if item.get("in") == "path" and item["name"] == missing]
                if not candidates or any(item["schema"] != candidates[0]["schema"] for item in candidates):
                    raise ValueError("Missing source path contract: " + method_path + " " + missing)
                params.append(candidates[0])
        if params:
            properties["headers" if part == "header" else part] = {
                "type": "object", "properties": {item["name"]: item.get("schema", {}) for item in params},
                "required": [item["name"] for item in params if item.get("required")], "additionalProperties": False}
    return properties


def operation_contracts(operations):
    """Build one contract per selected operation and register its typed modules."""
    contracts = []
    for method_path, operation in operations.items():
        method, path = method_path.split(" ", 1)
        name = module_name(operation["operationId"])
        properties = input_properties(operations, method_path, operation, path)
        content = operation.get("requestBody", {}).get("content", {})
        media_type = next((key for key in content if "json" in key), next(iter(content), None))
        if media_type:
            properties["body"] = content[media_type].get("schema", {})
        required = [key for key in ("path", "query", "headers") if properties.get(key, {}).get("required")] + \
            (["body"] if operation.get("requestBody", {}).get("required") else [])
        input_mod = register({"type": "object", "properties": properties, "required": required,
                              "additionalProperties": False}, "Input" + name)
        outputs = []
        for status, response in operation.get("responses", {}).items():
            if status.startswith("2"):
                source = response.get("content", {}).get("application/json", {}).get("schema", {})
                output_rule, output_type = rule(source, "Output" + name + status)
                wrapper = register({"type": "object", "properties": {"value": source}, "required": ["value"],
                                    "additionalProperties": False}, "Result" + name + status)
                outputs.append({"status": int(status), "rule": output_rule, "type": output_type,
                                "module": wrapper, "empty": not source})
        contracts.append({"id": method_path, "key": snake(operation["operationId"]), "name": name,
                          "method": method.lower(), "path": path, "input": input_mod, "outputs": outputs,
                          "media_type": media_type, "parameters": operation.get("parameters", [])})
    return contracts


def pagination_scheme(operation):
    params = operation["parameters"]
    query = {item["name"]: item for item in params if item.get("in") == "query"}
    scheme = "cursor" if "cursor" in query else "offset" if "skip" in query and "take" in query else "none"
    if operation["id"] == "POST /v2/insights/routings/form-responses":
        scheme = "body_offset"
    page_key = "limit" if "limit" in query else "take" if "take" in query else None
    page_size = query.get(page_key, {}).get("schema", {}).get("default")
    version = next((item.get("schema", {}).get("default") or item.get("schema", {}).get("example")
                    for item in params if item["name"] == "cal-api-version"), None)
    return scheme, page_key, page_size, version


def entity_modules():
    """Render every registered object into its module source and field contract."""
    generated = {}
    declarations = {}
    processed = set()
    while len(processed) < len(objects):
        for name, source in list(objects.items()):
            if name in processed:
                continue
            schema = merge_all(source)
            fields = []
            field_contracts = []
            names = set()
            for key, value in schema.get("properties", {}).items():
                field_name = snake(key)
                if field_name in names or field_name in ("raw", "provided", "unknown_fields"):
                    raise ValueError("Field name collision: " + name + "." + key)
                names.add(field_name)
                value_rule, value_type = rule(value, name.removeprefix(PREFIX) + module_name(key[:1].upper() + key[1:]))
                required = str(key in schema.get("required", [])).lower()
                fields.append("{" + atom(field_name) + ", " + literal(key) + ", " + value_rule + ", " +
                              value_type + ", " + required + "}")
                field_contracts.append([field_name, key, value_rule, value_type, required == "true"])
            additional = schema.get("additionalProperties", {})
            if additional is False:
                additional_rule, additional_type = "false", ROOT_NS + ".Json.t()"
            else:
                additional_rule, additional_type = rule(additional if isinstance(additional, dict) else {},
                                                        name.removeprefix(PREFIX) + "Additional")
            generated[name] = ("defmodule " + name + ' do\n  @moduledoc "Complete typed fields for this Cal provider object."\n'
                               "  use " + ROOT_NS + ".Schema,\n    additional: " + additional_rule +
                               ",\n    additional_type: " + additional_type + ",\n    fields: [\n      " +
                               ",\n      ".join(fields) + "\n    ]\nend\n")
            declarations[name] = {"fields": field_contracts, "additional": additional_rule,
                                  "additional_type": additional_type}
            processed.add(name)
    return generated, declarations


def chunk_by_bytes(entries, size):
    """Group (name, source) entries into files no larger than `size` bytes."""
    groups = []
    current = []
    current_bytes = 0
    for entry in entries:
        if current and current_bytes + len(entry[1]) > size:
            groups.append(current)
            current = []
            current_bytes = 0
        current.append(entry)
        current_bytes += len(entry[1])
    if current:
        groups.append(current)
    return groups


def render_entity_file(names, group):
    body = "\n".join(
        "defmodule Entities." + name.removeprefix(PREFIX) + ' do\n'
        '  @moduledoc "Complete typed fields for this Cal provider object."\n'
        "  use " + ROOT_NS + ".Schema, source: {\"schema_contracts_" + str(group).zfill(2) + '.json", __MODULE__}\n'
        "end\n" for name in names)
    return "alias " + ROOT_NS + ".Entities\n\n" + body


def render_operation_file(contracts, group):
    body = "\n".join(
        "defmodule Operations." + contract["name"] + ' do\n'
        '  @moduledoc "A complete typed Cal provider operation."\n'
        "  use " + ROOT_NS + ".OperationModule, source: {\"operation_contracts_" + str(group).zfill(2) +
        '.json", __MODULE__}\n'
        "end\n" for contract in contracts)
    return "alias " + ROOT_NS + ".Operations\n\n" + body


def render_registry(contracts):
    modules = ",\n".join("    Operations." + contract["name"] for contract in contracts)
    return ("defmodule " + ROOT_NS + ".Registry do\n"
            '  @moduledoc "The closed set of generated Cal.com operations."\n'
            "  alias " + ROOT_NS + ".{Operation, Operations}\n"
            "\n"
            "  @modules [\n" + modules + "\n  ]\n"
            "  @operations Enum.map(@modules, & &1.definition())\n"
            "  @lookup Map.merge(Map.new(@operations, &{&1.id, &1}), Map.new(@operations, &{&1.key, &1}))\n"
            '  @doc "Return every generated operation."\n'
            "  @spec all() :: [Operation.t()]\n"
            "  def all, do: @operations\n"
            '  @doc "Find a fixed operation without creating atoms from input."\n'
            "  @spec find(String.t() | atom()) :: Operation.t() | nil\n"
            "  def find(key), do: Map.get(@lookup, key)\n"
            "end\n")


def render_webhook_payloads(webhook_modules):
    """Render the webhook dispatch module exactly as `mix format` would.

    Generated files are checked by `--check` and by `mix format
    --check-formatted`, so the two must agree. Only this module emits lines
    long enough to wrap; the map pairs and the result union follow the
    formatter's 98-column break with its continuation indents.
    """
    parts = ["Entities." + name.removeprefix(PREFIX) + ".t()" for name in webhook_modules.values()]
    union = " | ".join(parts)
    if len("  @type t :: " + union) > LINE_LENGTH:
        union = "\n          " + "\n          | ".join(parts)
    else:
        union = " " + union
    pairs = ",\n".join(map_entry(event, name) for event, name in webhook_modules.items())
    return ('defmodule ' + ROOT_NS + '.WebhookPayloads do\n'
            '  @moduledoc "Concrete payloads for every documented Cal webhook trigger."\n'
            "  alias " + ROOT_NS + ".{Codec, Entities}\n"
            "  alias " + ROOT_NS + ".Error\n"
            "\n"
            "  @modules %{\n" + pairs + "\n  }\n"
            '  @typedoc "The complete source event payload union."\n'
            "  @type t ::" + union + "\n"
            '  @doc "Return the exact source trigger names."\n'
            "  @spec events() :: [String.t()]\n"
            "  def events, do: Map.keys(@modules)\n"
            '  @doc "Parse one provider event without hiding documented fields."\n'
            "  @spec parse(term()) :: {:ok, t()} | {:error, Error.t()}\n"
            '  def parse(%{"triggerEvent" => event} = raw) do\n'
            "    case Map.get(@modules, event) do\n"
            '      nil -> Codec.invalid("webhook triggerEvent")\n'
            "      module -> module.parse(raw)\n"
            "    end\n"
            "  end\n"
            "\n"
            "  def parse(_raw), do: Codec.invalid(\"webhook\")\n"
            "end\n")


def map_entry(event, module):
    target = "Entities." + module.removeprefix(PREFIX)
    line = "    " + literal(event) + " => " + target
    if len(line) + 1 <= LINE_LENGTH:
        return line
    return "    " + literal(event) + " =>\n      " + target


def operation_declarations(contracts):
    declarations = {}
    for contract in contracts:
        scheme, page_key, page_size, version = pagination_scheme(contract)
        outputs = ["%" + ROOT_NS + ".Output{status: " + str(out["status"]) + ", module: " + out["module"] +
                   ", rule: " + out["rule"] + ", empty?: " + str(out["empty"]).lower() + "}"
                   for out in contract["outputs"]]
        result_type = " | ".join(out["module"] + ".t()" for out in contract["outputs"]) or "struct()"
        values = {
            "key": atom(contract["key"]), "id": literal(contract["id"]), "method": ":" + contract["method"],
            "path": literal(contract["path"]), "module": ROOT_NS + ".Operations." + contract["name"],
            "input_module": contract["input"],
            "version": literal(version) if version is not None else "nil",
            "media_type": literal(contract["media_type"]) if contract["media_type"] else "nil",
            "page_size": str(page_size) if page_size is not None else "nil",
            "page_key": literal(page_key) if page_key else "nil", "pagination": ":" + scheme,
            "outputs": "[" + ", ".join(outputs) + "]",
        }
        definition = "%" + ROOT_NS + ".Operation{" + ", ".join(key + ": " + value for key, value in values.items()) + "}"
        declarations[values["module"]] = {"input": contract["input"], "result": result_type,
                                          "contract": definition}
    return declarations


def build(original, inventory, overrides, webhook_shapes):
    """Render every generated file as {relative path: contents}."""
    global schemas
    operations = selected_operations(original, inventory["operations"])
    # Reachability is computed before the response overrides, exactly as the
    # in-tree generator did: an override replaces a schema with one that is
    # already reachable, and the order fixes which canonical name a shared
    # shape gets. Changing it renames generated modules.
    schemas = reachable_schemas(original, operations)
    for operation_id, responses in overrides.get("operation_responses", {}).items():
        for status, schema in responses.items():
            operations[operation_id]["responses"][status]["content"]["application/json"]["schema"] = schema
    for name, fields in overrides.get("schema_properties", {}).items():
        schemas[name]["properties"].update(fields)

    for name, schema in schemas.items():
        if schema.get("type") == "object" or "properties" in schema:
            register(schema, name)
    contracts = operation_contracts(operations)

    webhook_modules = {}
    if webhook_shapes is not None:
        for event, fields in overrides.get("webhook_properties", {}).items():
            webhook_shapes[event]["properties"]["payload"]["properties"].update(fields)
        webhook_modules = {event: register(shape, "Webhook" + module_name(event.lower()))
                           for event, shape in webhook_shapes.items()}

    generated, declarations = entity_modules()

    lib = "lib/" + snake(ROOT_NS) + "/"
    files = {}
    for index, group in enumerate(chunk_by_bytes(list(generated.items()), CHUNK_BYTES)):
        names = [name for name, _source in group]
        files[lib + "entities/source_" + str(index).zfill(2) + ".ex"] = render_entity_file(names, index)
        files["source/schema_contracts_" + str(index).zfill(2) + ".json"] = \
            json.dumps({name: declarations[name] for name in names}, ensure_ascii=False, indent=2) + "\n"

    operation_groups = [contracts[index:index + OPERATIONS_PER_FILE]
                        for index in range(0, len(contracts), OPERATIONS_PER_FILE)]
    for index, group in enumerate(operation_groups):
        files[lib + "operations/source_" + str(index).zfill(2) + ".ex"] = render_operation_file(group, index)
        files["source/operation_contracts_" + str(index).zfill(2) + ".json"] = \
            json.dumps(operation_declarations(group), ensure_ascii=False, indent=2) + "\n"

    index = {}
    for name, schema in schemas.items():
        if schema.get("type") == "object" or "properties" in schema:
            key = json.dumps(canonical_shape(schema), sort_keys=True, separators=(",", ":"))
            index[name] = canonical_objects[key]
    files["source/source_index.json"] = json.dumps(index, indent=2) + "\n"
    files[lib + "registry.ex"] = render_registry(contracts)

    if webhook_shapes is not None:
        files[lib + "webhook_payloads.ex"] = render_webhook_payloads(webhook_modules)
    return files


def generated_on_disk():
    patterns = ["lib/*/entities/source_*.ex", "lib/*/operations/source_*.ex", "source/*_contracts_*.json"]
    return {str(candidate.relative_to(REPO)) for pattern in patterns for candidate in REPO.glob(pattern)}


def write(files):
    removed = sorted(generated_on_disk() - set(files))
    for relative in removed:
        (REPO / relative).unlink()
    for relative, content in sorted(files.items()):
        target = REPO / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    print(json.dumps({"files": len(files), "removed": len(removed)}))


def check(files):
    differences = sorted(relative for relative, content in files.items()
                         if not (REPO / relative).exists() or (REPO / relative).read_text() != content)
    differences += sorted(generated_on_disk() - set(files))
    if differences:
        print("generated files are stale:\n  " + "\n  ".join(differences), file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps({"files": len(files), "current": True}))


def main(argv=None):
    global PREFIX, ROOT_NS
    args = parse_args(argv)
    ROOT_NS = args.prefix
    PREFIX = ROOT_NS + ".Entities."
    check_source_hash()

    inventory = json.loads((SOURCE / "inventory.json").read_text())
    original = json.loads((SOURCE / "openapi.json").read_text())
    overrides = json.loads((SOURCE / "live_overrides.json").read_text()) \
        if (SOURCE / "live_overrides.json").exists() else {}
    webhook_shapes = json.loads((SOURCE / "webhook_shapes.json").read_text()) \
        if (SOURCE / "webhook_shapes.json").exists() else None

    files = build(original, inventory, overrides, webhook_shapes)
    check(files) if args.check else write(files)


if __name__ == "__main__":
    main()
