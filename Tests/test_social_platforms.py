"""Bundled brand icons stay local; unknown platforms remain valid website links."""
import json
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


class SocialPlatformTests(unittest.TestCase):
    def test_every_identified_platform_has_a_local_vector_icon(self):
        model = (ROOT / 'RepoPocket/CommunityModels.swift').read_text(encoding='utf-8')
        platforms = model.split('enum SocialPlatform: String, CaseIterable {', 1)[1]
        names = platforms.split('case ', 1)[1].split('\n', 1)[0].split(', ')
        self.assertGreater(len(names), 1)
        for name in names:
            folder = ROOT / 'RepoPocket/Assets.xcassets' / f'social-{name}.imageset'
            metadata = json.loads((folder / 'Contents.json').read_text(encoding='utf-8-sig'))
            self.assertEqual(metadata['properties']['template-rendering-intent'], 'template')
            svg = ET.parse(folder / metadata['images'][0]['filename']).getroot()
            self.assertEqual(svg.attrib['viewBox'], '0 0 24 24')
            self.assertTrue(svg.find('{http://www.w3.org/2000/svg}path').attrib['d'])
        icon = (ROOT / 'RepoPocket/SocialAccountIcon.swift').read_text(encoding='utf-8')
        self.assertIn('Image(systemName: "globe")', icon)
        self.assertNotRegex(icon, r'URLSession|AsyncImage|https?://')

    def test_general_link_editor_and_shared_profile_icons(self):
        source = (ROOT / 'RepoPocket/SocialAccountsView.swift').read_text(encoding='utf-8')
        self.assertIn('TextField("社交账号或网站链接"', source)
        self.assertNotIn('https://t.me/用户名', source)
        self.assertIn('SocialAccountIcon(url: account.url, provider: account.provider)', source)
        self.assertIn('.sheet(isPresented: $showingEditor', source)
        profile = (ROOT / 'RepoPocket/DiscoveryViews.swift').read_text(encoding='utf-8')
        self.assertIn('SocialAccountIcon(url: contact.url, provider: contact.provider)', profile)

    def test_safari_done_also_dismisses_the_swiftui_sheet(self):
        source = (ROOT / 'RepoPocket/NativeLinkDestination.swift').read_text(encoding='utf-8')
        self.assertIn('controller.delegate = context.coordinator', source)
        self.assertIn('func safariViewControllerDidFinish(_ controller: SFSafariViewController)', source)
        self.assertIn('context.coordinator.onClose = onClose', source)
        self.assertIn('onClose()', source)
        for name in ['ReadingViews.swift', 'ReadmeHTMLView.swift', 'RepositorySearchView.swift']:
            caller = (ROOT / 'RepoPocket' / name).read_text(encoding='utf-8')
            self.assertEqual(caller.count('ReadingLinkDestination(url:'), caller.count('api: api) { readingLink = nil }'))


if __name__ == '__main__':
    unittest.main()
