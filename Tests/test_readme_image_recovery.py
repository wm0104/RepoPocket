"""Network-free checks for the fixed, isolated README image recovery script."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def recovery_script():
    return (ROOT / 'RepoPocket/ReadmeDocument.swift').read_text().split(
        'static let imageRecovery = """', 1)[1].split('"""', 1)[0]


class ReadmeImageRecoveryTests(unittest.TestCase):
    def test_recovery_is_isolated_in_both_inline_and_fullscreen_views(self):
        source = (ROOT / 'RepoPocket/ReadmeHTMLView.swift').read_text()
        injection = source.split('source: ReadmeDocumentRules.imageRecovery,', 1)[1]
        self.assertTrue(injection.startswith('\n            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)'))
        self.assertLess(source.index('source: ReadmeDocumentRules.imageRecovery'), source.index('if !scrolling'))
        self.assertIn('allowsContentJavaScript = false', source)
        self.assertIn('removeAllUserScripts()', source)
        script = recovery_script()
        for forbidden in ('fetch(', 'XMLHttpRequest', 'data-canonical-src', 'Authorization', 'setInterval', 'location.reload'):
            self.assertNotIn(forbidden, script)

    @unittest.skipUnless(shutil.which('node'), 'Node executes production app-owned JS')
    def test_only_failed_simple_images_retry_once_including_late_failure(self):
        harness = r'''
const assert = require('node:assert/strict');
class Image {
  constructor({complete = true, width = 0, src = 'https://images.example/badge.svg', srcset = false, picture = false} = {}) {
    Object.assign(this, {complete, naturalWidth: width, src, srcset, picture, writes: []});
  }
  getAttribute(name) { assert.equal(name, 'src'); return this.src; }
  hasAttribute(name) { assert.equal(name, 'srcset'); return this.srcset; }
  closest(name) { assert.equal(name, 'picture'); return this.picture ? {} : null; }
  setAttribute(name, value) { this.writes.push([name, value]); }
}
global.HTMLImageElement = Image;
const healthy = new Image({width: 112}), failed = new Image(), pending = new Image({complete: false});
const lazy = new Image({complete: false}), missing = new Image({src: null});
const responsive = new Image({srcset: true}), picture = new Image({picture: true});
let onError;
const article = {
  addEventListener(name, handler, capture) { assert.equal(name, 'error'); assert.equal(capture, true); onError = handler; },
  querySelectorAll(name) { assert.equal(name, 'img'); return [healthy, failed, pending, lazy, missing, responsive, picture]; }
};
global.document = {getElementById: id => { assert.equal(id, 'repopocket-readme'); return article; }};
SCRIPT
assert.deepEqual(failed.writes, [['src', failed.src]]);
onError({target: failed}); onError({target: failed});
assert.equal(failed.writes.length, 1);
for (const image of [healthy, pending, lazy, missing, responsive, picture]) assert.equal(image.writes.length, 0);
pending.complete = true;
onError({target: pending}); onError({target: pending});
assert.deepEqual(pending.writes, [['src', pending.src]]);
onError({target: {}});
// Failed recovery is bounded even if it generates another error immediately.
assert.equal(pending.writes.length, 1);
assert.equal(lazy.writes.length, 0);
console.log('PASS: failed-at-install, late-failure, once-only, healthy, pending, lazy, no-src, srcset, picture, non-image');
'''.replace('SCRIPT', recovery_script())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image-recovery.cjs'
            path.write_text(harness)
            subprocess.run([shutil.which('node'), str(path)], check=True, timeout=10)


if __name__ == '__main__':
    unittest.main()
