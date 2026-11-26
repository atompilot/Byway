import json
import re
import unittest
from pathlib import Path


RESOURCES = Path(__file__).resolve().parents[1] / "Localization"
PLACEHOLDER = re.compile(r"\{[0-9]+(?:[:,][^{}]*)?\}")


def catalog(language):
    def unique_entries(pairs):
        entries = dict(pairs)
        if len(entries) != len(pairs):
            raise ValueError(f"Duplicate keys in {language} catalog")
        return entries

    return json.loads(
        (RESOURCES / f"byway-{language}.json").read_text(encoding="utf-8"),
        object_pairs_hook=unique_entries,
    )


class LocalizationTests(unittest.TestCase):
    def test_native_catalogs_have_matching_keys(self):
        self.assertEqual(catalog("en").keys(), catalog("es").keys())
        self.assertLessEqual(catalog("zh-Hans").keys(), catalog("en").keys())

    def test_translations_preserve_format_arguments(self):
        for language in ("en", "es", "zh-Hans"):
            for source, translation in catalog(language).items():
                with self.subTest(language=language, source=source):
                    self.assertTrue(translation.strip())
                    self.assertCountEqual(
                        PLACEHOLDER.findall(source), PLACEHOLDER.findall(translation)
                    )


if __name__ == "__main__":
    unittest.main()
