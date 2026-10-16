import json
import tempfile
import unittest
from pathlib import Path

from generate_vanilla_entity_registry import build_registry, parse_jsonc


class ParseJSONCTests(unittest.TestCase):
    def test_comments_trailing_commas_and_comment_text_in_strings(self):
        parsed = parse_jsonc(
            '{// line comment\n'
            '"url":"https://example.invalid/a/*b*/",'
            '"nested":{"items":[1,2,],},'
            '"text":"// not a comment",}'
        )
        self.assertEqual(parsed["url"], "https://example.invalid/a/*b*/")
        self.assertEqual(parsed["nested"]["items"], [1, 2])
        self.assertEqual(parsed["text"], "// not a comment")


class RegistryTests(unittest.TestCase):
    def test_extracts_schema_metadata_and_preserves_sources_and_duplicates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "a.json").write_text(
                """
                {
                  "format_version": "1.26.0",
                  "minecraft:entity": {
                    "description": {
                      "identifier": "minecraft:creeper",
                      "spawn_category": "monster"
                    },
                    "components": {
                      "minecraft:collision_box": {"width": 0.6, "height": 1.7},
                      "minecraft:type_family": {"family": ["monster", "mob"]},
                      "minecraft:health": {"value": 20},
                      "minecraft:attack": {"damage": 3}
                    }
                  }
                }
                """,
                encoding="utf-8",
            )
            (root / "nested").mkdir()
            (root / "nested" / "duplicate.json").write_text(
                '{"minecraft:entity":{"description":{"identifier":"minecraft:creeper"}}}',
                encoding="utf-8",
            )
            (root / "no_identifier.json").write_text(
                '{"minecraft:entity":{"description":{},"components":{}}}',
                encoding="utf-8",
            )
            (root / "bad.json").write_text(
                '{"minecraft:entity":',
                encoding="utf-8",
            )

            registry = build_registry(root)
            self.assertEqual(registry["definitionsFound"], 4)
            self.assertEqual(registry["parsedSuccessfully"], 3)
            self.assertEqual(registry["definitionsWithIdentifiers"], 2)
            self.assertEqual(registry["definitionsMissingIdentifier"], 1)
            self.assertEqual(registry["malformedFileCount"], 1)
            self.assertEqual(registry["duplicateIdentifierCount"], 1)

            definition = registry["definitions"][0]
            self.assertEqual(definition["identifier"], "minecraft:creeper")
            self.assertEqual(definition["sourceFile"], "a.json")
            self.assertEqual(definition["spawnCategory"], "monster")
            self.assertEqual(definition["typeFamilies"], ["monster", "mob"])
            self.assertEqual(definition["collisionBox"]["width"], 0.6)
            self.assertEqual(definition["collisionBox"]["height"], 1.7)
            self.assertIsNone(definition["collisionBox"]["depth"])
            self.assertIn("collisionBox.depth", definition["unknownFields"])
            self.assertEqual(definition["health"], 20)
            self.assertEqual(definition["attackDamage"], 3)
            self.assertEqual(
                registry["identifierSources"]["minecraft:creeper"],
                ["a.json", "nested/duplicate.json"],
            )
            duplicate = registry["definitions"][1]
            self.assertIn("collisionBox.width", duplicate["unknownFields"])
            self.assertIn("components", duplicate["unknownFields"])

    def test_actual_bundled_vanilla_entities_have_explicit_identifiers(self):
        source = (
            Path("Payload/minecraftpe.app/data/behavior_packs/vanilla/entities")
        )
        if not source.is_dir():
            self.skipTest("decrypted Minecraft payload is not present")
        registry = build_registry(source)
        identifiers = {item["identifier"] for item in registry["definitions"]}
        self.assertIn("minecraft:creeper", identifiers)
        self.assertIn("minecraft:cow", identifiers)
        cow = next(
            item for item in registry["definitions"]
            if item["identifier"] == "minecraft:cow"
        )
        self.assertEqual(cow["collisionBox"]["width"], 0.9)
        self.assertEqual(cow["collisionBox"]["height"], 1.3)
        self.assertIn("collisionBox.depth", cow["unknownFields"])
        self.assertGreater(registry["definitionsFound"], 0)
        self.assertEqual(registry["malformedFileCount"], 0)
        self.assertEqual(registry["definitionsFound"], registry["parsedSuccessfully"])


if __name__ == "__main__":
    unittest.main()
