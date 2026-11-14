"""Build a production Swift fixture with the same pinned Yams as the app, outside the repo."""
from pathlib import Path
import os
import subprocess
import tempfile


def run_swift_fixture(source, name='workflow-inputs', timeout=180):
    mount = Path('/var/minis/mounts/minis缓存目录')
    fallback = mount if mount.is_dir() else Path(os.environ.get('TMPDIR', tempfile.gettempdir()))
    cache = Path(os.environ.get('REPOPOCKET_TEST_CACHE', str(fallback / 'RepoPocket-workflow-inputs-tests')))
    cache.mkdir(parents=True, exist_ok=True)
    # All generated packages, checkouts, binaries and logs stay outside the worktree.
    with tempfile.TemporaryDirectory(prefix=name + '-', dir=cache) as folder:
        root = Path(folder)
        (root / 'Sources' / 'Fixture').mkdir(parents=True)
        (root / 'Sources' / 'Fixture' / 'Fixture.swift').write_text(source)
        (root / 'Package.swift').write_text('''// swift-tools-version:5.7
import PackageDescription
let package = Package(name: "WorkflowInputsFixture", platforms: [.macOS(.v12)],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "5.1.3")],
    targets: [.executableTarget(name: "Fixture", dependencies: [.product(name: "Yams", package: "Yams")])])
''')
        subprocess.run(['swift', 'build', '--package-path', str(root), '--scratch-path', str(root / 'build'), '--cache-path', str(root / 'cache')], check=True, timeout=timeout)
        subprocess.run([str(root / 'build' / 'debug' / 'Fixture')], check=True, timeout=60)
