#!/usr/bin/env python3
"""Audit extracted IPA or TrollStore TIPA entitlements without signing."""
import importlib.util
from pathlib import Path
import plistlib
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('deb_audit', ROOT / 'Scripts/verify-deb.py')
deb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deb)


def verify(app, *, trollstore=False):
    entries = deb.tree(app)
    expected = {}
    main_template = ROOT / ('Entitlements.plist' if trollstore else 'Packaging/IPA.entitlements')
    for bundle, template in ((app, main_template),
                             (app / deb.SHARE, ROOT / 'ShareExtension/Entitlements.plist')):
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        name = info.get('CFBundleExecutable')
        deb.require(isinstance(name, str) and name not in ('', '.', '..') and '/' not in name,
                    'invalid bundle executable name')
        expected[bundle / name] = plistlib.loads(template.read_bytes())
    seen = set()
    for path in entries:
        if not path.is_file():
            continue
        data = path.read_bytes()
        if data[:4] not in deb.MAGICS:
            deb.require(path not in expected, 'bundle executable is not Mach-O')
            continue
        for item in deb.macho(data, signed=True):
            # Canonical plist comparison also distinguishes true from integer 1.
            deb.require(plistlib.dumps(item['entitlements']) ==
                        plistlib.dumps(expected.get(path, {})),
                        ('TIPA' if trollstore else 'IPA') + ' signature entitlement baseline mismatch')
        seen.add(path)
    deb.require(expected.keys() <= seen, 'missing app/extension Mach-O')


if __name__ == '__main__':
    try:
        if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--trollstore'):
            raise ValueError('usage: verify-ipa.py EXTRACTED_APP [--trollstore]')
        trollstore = len(sys.argv) == 3
        verify(Path(sys.argv[1]), trollstore=trollstore)
        print(('TIPA' if trollstore else 'IPA') + ' embedded entitlement baselines verified (not an AMFI trust check)')
    except (ValueError, OSError, KeyError) as error:
        sys.exit(str(error))
