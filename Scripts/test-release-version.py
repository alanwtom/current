#!/usr/bin/env python3
"""Offline checks for release version ordering and download metadata."""
import importlib.util
import tempfile
import unittest
from pathlib import Path


def module(name):
    path = Path(__file__).with_name(name + '.py')
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


versions = module('check-release-version')
stamping = module('stamp-download-page')


class ReleaseChecks(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.feed = self.root / 'appcast.xml'
        self.feed.write_text('''<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><s:version>104</s:version><s:shortVersionString>1.3.0</s:shortVersionString><enclosure/></item></channel></rss>''')

    def test_new_release_passes(self):
        versions.check('1.3.1', '105', self.feed)

    def test_old_build_is_refused(self):
        with self.assertRaises(ValueError):
            versions.check('1.3.1', '97', self.feed)

    def test_same_build_is_refused(self):
        with self.assertRaises(ValueError):
            versions.check('1.3.1', '104', self.feed)

    def test_same_version_is_refused(self):
        with self.assertRaises(ValueError):
            versions.check('1.3.0', '105', self.feed)

    def test_empty_feed_is_refused(self):
        self.feed.write_text('<rss><channel/></rss>')
        with self.assertRaises(ValueError):
            versions.check('1.3.1', '105', self.feed)

    def test_numeric_version_order(self):
        versions.check('1.10.0', '105', self.feed)
        self.assertEqual(versions.version_parts('1.3.0'), versions.version_parts('1.3'))

    def test_duplicate_download_field_does_not_change_page(self):
        page = self.root / 'index.html'
        original = '<span class="dl-name">Current</span>' * 2
        page.write_text(original)
        archive = self.root / 'Current.dmg'
        archive.write_bytes(b'archive')
        with self.assertRaises(ValueError):
            stamping.stamp(page, archive, '1.3.1')
        self.assertEqual(page.read_text(), original)


if __name__ == '__main__':
    unittest.main()
