#!/usr/bin/env python3
"""Extract entity type metadata from Bedrock vanilla behavior-pack JSONC files."""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any

DEFAULT_SOURCE = Path(
    "Payload/minecraftpe.app/data/behavior_packs/vanilla/entities"
)
DEFAULT_OUTPUT = Path("ClientLoader/generated/entity_registry.json")


def strip_jsonc_comments(text: str) -> str:
    """Remove // and /* */ comments without modifying comment-looking string data."""
    result: list[str] = []
    index = 0
    state = "normal"
    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""
        if state == "normal":
            if char == '"':
                state = "string"
                result.append(char)
                index += 1
            elif char == "/" and next_char == "/":
                state = "line"
                result.extend("  ")
                index += 2
            elif char == "/" and next_char == "*":
                state = "block"
                result.extend("  ")
                index += 2
            else:
                result.append(char)
                index += 1
        elif state == "string":
            result.append(char)
            if char == "\\" and index + 1 < len(text):
                result.append(text[index + 1])
                index += 2
            else:
                if char == '"':
                    state = "normal"
                index += 1
        elif state == "line":
            if char == "\n":
                result.append(char)
                state = "normal"
            else:
                result.append(" ")
            index += 1
        else:
            if char == "*" and next_char == "/":
                result.extend("  ")
                state = "normal"
                index += 2
            else:
                result.append("\n" if char == "\n" else " ")
                index += 1

    if state == "block":
        raise ValueError("unterminated block comment")
    return "".join(result)


def parse_jsonc(text: str) -> Any:
    without_comments = strip_jsonc_comments(text)
    without_trailing_commas = re.sub(r",(?=\s*[}\]])", " ", without_comments)
    return json.loads(without_trailing_commas)


def _number_or_unknown(value: Any) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def extract_definition(document: Any, source_file: str) -> dict[str, Any] | None:
    if not isinstance(document, dict):
        return None
    entity = document.get("minecraft:entity")
    if not isinstance(entity, dict):
        return None
    description = entity.get("description")
    if not isinstance(description, dict):
        return None
    identifier = description.get("identifier")
    if not isinstance(identifier, str) or not identifier:
        return None

    components = entity.get("components")
    has_components = isinstance(components, dict)
    if not has_components:
        components = {}

    collision = components.get("minecraft:collision_box")
    if not isinstance(collision, dict):
        collision = {}
    family_component = components.get("minecraft:type_family")
    families = family_component.get("family") if isinstance(family_component, dict) else None
    if not isinstance(families, list) or not all(isinstance(item, str) for item in families):
        families = None

    health_component = components.get("minecraft:health")
    health = health_component.get("value") if isinstance(health_component, dict) else None
    attack_component = components.get("minecraft:attack")
    attack = attack_component.get("damage") if isinstance(attack_component, dict) else None
    movement_component = components.get("minecraft:movement")
    movement = (
        movement_component.get("value") if isinstance(movement_component, dict) else None
    )

    width = _number_or_unknown(collision.get("width"))
    height = _number_or_unknown(collision.get("height"))
    metadata = {
        "identifier": identifier,
        "sourceFile": source_file,
        "formatVersion": document.get("format_version"),
        "spawnCategory": description.get("spawn_category"),
        "typeFamilies": families,
        "collisionBox": {
            "width": width,
            "height": height,
            "depth": None,
        },
        "components": (
            sorted(key for key in components if isinstance(key, str))
            if has_components
            else None
        ),
        "health": _number_or_unknown(health),
        "attackDamage": _number_or_unknown(attack),
        "movementSpeed": _number_or_unknown(movement),
    }
    metadata["unknownFields"] = [
        field
        for field, value in (
            ("formatVersion", metadata["formatVersion"]),
            ("spawnCategory", metadata["spawnCategory"]),
            ("typeFamilies", metadata["typeFamilies"]),
            ("collisionBox.width", width),
            ("collisionBox.height", height),
            ("collisionBox.depth", None),
            ("components", metadata["components"]),
            ("health", metadata["health"]),
            ("attackDamage", metadata["attackDamage"]),
            ("movementSpeed", metadata["movementSpeed"]),
        )
        if value is None
    ]
    return metadata


def build_registry(source: Path) -> dict[str, Any]:
    files = sorted(source.rglob("*.json")) if source.is_dir() else []
    definitions: list[dict[str, Any]] = []
    malformed: list[dict[str, str]] = []
    missing_identifier: list[str] = []
    identifier_sources: dict[str, list[str]] = defaultdict(list)

    for file_path in files:
        relative_path = file_path.relative_to(source).as_posix()
        try:
            document = parse_jsonc(file_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
            malformed.append({"sourceFile": relative_path, "error": str(error)})
            continue
        definition = extract_definition(document, relative_path)
        if definition is None:
            missing_identifier.append(relative_path)
            continue
        definitions.append(definition)
        identifier_sources[definition["identifier"]].append(relative_path)

    duplicate_identifiers = [
        {"identifier": identifier, "sourceFiles": paths}
        for identifier, paths in sorted(identifier_sources.items())
        if len(paths) > 1
    ]
    return {
        "schemaVersion": 1,
        "sourceDirectory": source.as_posix(),
        "definitionsFound": len(files),
        "parsedSuccessfully": len(files) - len(malformed),
        "definitionsWithIdentifiers": len(definitions),
        "definitionsMissingIdentifier": len(missing_identifier),
        "malformedFileCount": len(malformed),
        "duplicateIdentifierCount": len(duplicate_identifiers),
        "malformedFiles": malformed,
        "missingIdentifierFiles": missing_identifier,
        "duplicateIdentifiers": duplicate_identifiers,
        "identifierSources": dict(sorted(identifier_sources.items())),
        "definitions": definitions,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    arguments = parser.parse_args()
    if not arguments.source.is_dir():
        parser.error(f"source directory does not exist: {arguments.source}")

    registry = build_registry(arguments.source)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(registry, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(
        f"definitions_found={registry['definitionsFound']} "
        f"parsed={registry['parsedSuccessfully']} "
        f"identified={registry['definitionsWithIdentifiers']} "
        f"missing_identifier={registry['definitionsMissingIdentifier']} "
        f"malformed={registry['malformedFileCount']} "
        f"duplicate_ids={registry['duplicateIdentifierCount']} "
        f"output={arguments.output}"
    )
    return 0 if not registry["malformedFileCount"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
