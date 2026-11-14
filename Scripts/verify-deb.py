#!/usr/bin/env python3
"""App-only Debian packaging. Never executes a payload or changes its source."""
import argparse
from contextlib import contextmanager
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[1]
FLAVORS = {"roothide": ("iphoneos-arm64e", "Applications/RepoPocket.app"),
           "rootless": ("iphoneos-arm64", "var/jb/Applications/RepoPocket.app")}
APP_ID = "com.wm0104.RepoPocket"
SHARE = "PlugIns/RepoPocketShare.appex"
CONTAINER = "com.apple.private.security.container-required"
MAGICS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe",
          b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
          b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def remove_tree(path):
    # iOS File Provider mounts can report different path/fd inodes, making
    # shutil.rmtree's fd identity test reject real directories as symlinks.
    # Only used on private mkdtemp directories; never traverse symlinks.
    with os.scandir(path) as entries:
        for entry in entries:
            if entry.is_dir(follow_symlinks=False):
                remove_tree(entry.path)
            else:
                os.unlink(entry.path)
    os.rmdir(path)


@contextmanager
def temporary_directory(**kwargs):
    path = tempfile.mkdtemp(**kwargs)
    try:
        yield path
    finally:
        remove_tree(path)


def run(*args):
    # Do not relay tool stderr: signing tools may print entitlement values.
    result = subprocess.run([str(a) for a in args], capture_output=True)
    require(result.returncode == 0, f"tool failed: {Path(str(args[0])).name}")
    return result.stdout


def version_tuple(value):
    require(isinstance(value, str) and re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value),
            "invalid OS version")
    return tuple((list(map(int, value.split('.'))) + [0])[:3])


def tree(root):
    require(not root.is_symlink() and root.is_dir(), "App must be a real directory")
    entries = sorted(root.rglob("*"))
    for path in entries:
        mode = path.lstat().st_mode
        require(not stat.S_ISLNK(mode), "symlinks are not allowed")
        require(stat.S_ISDIR(mode) or stat.S_ISREG(mode), "special files are not allowed")
        require(not path.is_file() or path.stat().st_nlink == 1, "hardlinks are not allowed")
        require(path.name not in {".DS_Store", ".git", "embedded.mobileprovision"}
                and not path.name.startswith(("._", ".ldid"))
                and path.suffix.lower() not in {".deb", ".ipa", ".tipa", ".o", ".a", ".dsym"},
                "unexpected packaging/development file in App")
    return entries


def snapshot(root):
    return {str(p.relative_to(root)): (p.stat().st_mode & 0o7777,
            hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None)
            for p in [root] + tree(root)}


def signature(data, offset, size):
    """Read embedded entitlements and verify CodeDirectory page/entitlement hashes.

    This is integrity checking, not an AMFI/CMS trust decision. macOS additionally
    runs codesign --verify --deep --strict for bundle/resource seal validation.
    """
    require(0 < offset < len(data) and 12 <= size <= len(data) - offset,
            "missing or invalid code signature")
    blob = data[offset:offset + size]
    magic, length, count = struct.unpack_from(">III", blob)
    require(magic == 0xfade0cc0 and 12 + count * 8 <= length <= len(blob),
            "invalid signature superblob")
    slots = {}
    for i in range(count):
        slot, start = struct.unpack_from(">II", blob, 12 + i * 8)
        require(start + 8 <= length and slot not in slots, "invalid signature index")
        _, length2 = struct.unpack_from(">II", blob, start)
        require(8 <= length2 <= length - start, "invalid signature slot")
        slots[slot] = blob[start:start + length2]
    ent = {}
    if 5 in slots:
        require(struct.unpack_from(">I", slots[5])[0] == 0xfade7171, "invalid entitlement blob")
        ent = plistlib.loads(slots[5][8:])
        require(isinstance(ent, dict), "entitlements must be a dictionary")
    directories = [v for k, v in slots.items() if k == 0 or 0x1000 <= k <= 0x1005]
    require(directories, "missing CodeDirectory")
    for cd in directories:
        require(len(cd) >= 44 and struct.unpack_from(">I", cd)[0] == 0xfade0c02,
                "invalid CodeDirectory")
        hash_offset, _, n_special, n_code, limit = struct.unpack_from(">IIIII", cd, 16)
        hash_size, hash_type, _, page = struct.unpack_from("4B", cd, 36)
        algorithms = {1: ('sha1', 20), 2: ('sha256', 32), 3: ('sha256', 20), 4: ('sha384', 48)}
        require(hash_type in algorithms and hash_size == algorithms[hash_type][1]
                and page <= 30 and limit == offset, "unsupported CodeDirectory layout")
        page_size = (1 << page) if page else limit
        require(page_size > 0 and n_code == (limit + page_size - 1) // page_size
                and n_special * hash_size <= hash_offset
                and hash_offset + n_code * hash_size <= len(cd), "invalid code hash table")
        def digest(value):
            return hashlib.new(algorithms[hash_type][0], value).digest()[:hash_size]
        for i in range(n_code):
            require(digest(data[i * page_size:min((i + 1) * page_size, limit)]) ==
                    cd[hash_offset + i * hash_size:hash_offset + (i + 1) * hash_size],
                    "code page hash mismatch")
        for slot in (2, 5, 7):
            if slot in slots:
                require(slot <= n_special and digest(slots[slot]) ==
                        cd[hash_offset - slot * hash_size:hash_offset - (slot - 1) * hash_size],
                        "signature special slot mismatch")
    return ent


def macho(data, signed):
    """Return every arm64 slice; check iOS platform and minimum deployment OS."""
    require(data[:4] in MAGICS, "expected 64-bit Mach-O")
    slices = []
    if data[:4] in {b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}:
        endian = ">" if data[0] == 0xca else "<"
        wide = data[:4] in {b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
        count = struct.unpack_from(endian + "I", data, 4)[0]
        width = 32 if wide else 20
        require(0 < count <= 16 and 8 + count * width <= len(data), "invalid fat header")
        previous = 8 + count * width
        records = []
        for i in range(count):
            fmt = "IIQQII" if wide else "IIIII"
            cpu, sub, start, size, *_ = struct.unpack_from(endian + fmt, data, 8 + i * width)
            records.append((start, size, cpu, sub))
        for start, size, cpu, sub in sorted(records):
            require(start >= previous and size >= 32 and start + size <= len(data), "overlapping fat slices")
            previous = start + size
            slices.append((data[start:start + size], cpu, sub))
    else:
        slices.append((data, None, None))
    result = []
    for thin, fat_cpu, fat_sub in slices:
        require(thin[:4] in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}, "unsupported Mach-O slice")
        endian = "<" if thin[0] == 0xcf else ">"
        _, cpu, sub, filetype, ncmds, sizeofcmds, _, _ = struct.unpack_from(endian + "8I", thin)
        require(cpu == 0x100000c and sub & 0xffffff in (0, 2), "only arm64/arm64e device slices are allowed")
        require(fat_cpu is None or (cpu == fat_cpu and sub == fat_sub), "fat/thin architecture mismatch")
        require(filetype in (2, 6, 8) and 32 + sizeofcmds <= len(thin), "unsupported Mach-O type")
        minimum, sig, pos = None, None, 32
        for _ in range(ncmds):
            require(pos + 8 <= 32 + sizeofcmds, "truncated load command")
            cmd, size = struct.unpack_from(endian + "II", thin, pos)
            require(size >= 8 and pos + size <= 32 + sizeofcmds, "invalid load command")
            if cmd == 0x32:
                require(size >= 24 and minimum is None, "short or duplicate build version")
                platform, minimum, _, tools = struct.unpack_from(endian + "4I", thin, pos + 8)
                require(platform == 2 and 24 + tools * 8 <= size, "non-iOS-device Mach-O")
            elif cmd == 0x25:
                require(size >= 16 and minimum is None, "short or duplicate iOS minimum version")
                minimum = struct.unpack_from(endian + "I", thin, pos + 8)[0]
            elif cmd in (0x24, 0x2f, 0x30):
                raise ValueError("non-iOS Mach-O")
            elif cmd == 0x1d:
                require(size == 16 and sig is None, "invalid code signature command")
                sig = struct.unpack_from(endian + "II", thin, pos + 8)
            pos += size
        require(pos == 32 + sizeofcmds and minimum is not None
                and 0 < minimum <= 0x000f0000, "Mach-O minimum OS exceeds iOS 15.0 or is missing")
        require(sig is None or sig[0] >= pos, "signature overlaps load commands")
        ent = signature(thin, *sig) if signed and sig else {}
        require(not signed or sig is not None, "unsigned Mach-O")
        result.append({"architecture": "arm64e" if sub & 0xffffff == 2 else "arm64",
                       "minimum_os": f"{minimum >> 16}.{(minimum >> 8) & 255}.{minimum & 255}",
                       "entitlements": ent})
    require(len({x['architecture'] for x in result}) == len(result), "duplicate architecture slices")
    require(any(x['architecture'] == 'arm64' for x in result), "arm64 slice required for both bootstrap flavors")
    return result


def app_audit(app, version, signed=True):
    entries = tree(app)
    bundles = [(app, APP_ID, REPO / 'Entitlements.plist'),
               (app / SHARE, APP_ID + '.Share', REPO / 'ShareExtension/Entitlements.plist')]
    require(sorted(p.relative_to(app).as_posix() for p in entries if p.suffix == '.appex') == [SHARE],
            "exactly RepoPocketShare.appex is required")
    expected = {}
    for bundle, identifier, template in bundles:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        require(info.get('CFBundleIdentifier') == identifier, "unexpected bundle identifier")
        require(info.get('CFBundleShortVersionString') == version
                and info.get('CFBundleVersion') == version, "bundle version mismatch")
        require(version_tuple(info.get('MinimumOSVersion')) == (15, 0, 0), "bundle minimum OS must be 15.0")
        name = info.get('CFBundleExecutable')
        require(isinstance(name, str) and name not in ('', '.', '..') and '/' not in name,
                "invalid bundle executable name")
        executable = bundle / name
        require(executable.is_file(), "missing bundle executable")
        expected[executable] = plistlib.loads(template.read_bytes())
        if bundle == app:
            require(info.get('UIFileSharingEnabled') is True
                    and info.get('LSSupportsOpeningDocumentsInPlace') is True, "Documents sharing flags required")
    audit = []
    binaries = []
    for path in entries:
        if not path.is_file():
            continue
        data = path.read_bytes()
        if data[:4] not in MAGICS:
            # A missing/renamed app executable must not pass as an ordinary resource.
            require(path not in expected, "bundle executable is not Mach-O")
            continue
        relative = path.relative_to(app).as_posix()
        if path not in expected:
            parts = path.relative_to(app).parts
            require('Frameworks' in parts and
                    (path.suffix == '.dylib' or any(x.endswith('.framework') for x in parts)),
                    "unexpected executable outside app/extension/frameworks")
        slices = macho(data, signed)
        for item in slices:
            ent = item.pop('entitlements')
            if signed:
                require(ent == expected.get(path, {}), "signature entitlement baseline mismatch")
                # Baseline currently omits this key: absence means containerized in
                # both audited uikittools implementations, not no-container/no-sandbox.
                require(CONTAINER not in ent, "unexpected container override")
            item['entitlement_keys'] = sorted(ent)
        audit.append({'path': relative, 'slices': slices})
        binaries.append(path)
    require(all(p in binaries for p in expected), "missing app/extension Mach-O")
    if signed and sys.platform == 'darwin':
        require(shutil.which('codesign'), "codesign is required on macOS")
        run('codesign', '--verify', '--deep', '--strict', app)
    return audit, binaries, expected


def control_fields(text):
    fields = {}
    for line in text.splitlines():
        if line.startswith(' '):
            require('Description' in fields, "invalid control continuation")
            continue
        key, sep, value = line.partition(': ')
        require(sep and key not in fields, "invalid or duplicate control field")
        fields[key] = value
    return fields


def members(deb, control=False):
    data = run('dpkg-deb', '--ctrl-tarfile' if control else '--fsys-tarfile', deb)
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
        seen, result = set(), []
        for member in archive:
            name = member.name.removeprefix('./').rstrip('/')
            if name in ('', '.'):
                require(member.isdir() and member.uid == member.gid == 0, "invalid archive root")
                continue
            path = PurePosixPath(name)
            require(not path.is_absolute() and '..' not in path.parts and name not in seen,
                    "unsafe or duplicate archive path")
            seen.add(name)
            require(member.isfile() or member.isdir(), "links/special archive entries forbidden")
            require(member.uid == member.gid == 0, "archive ownership must be root:root")
            require(member.mode == (0o755 if member.isdir() else 0o644)
                    or (not control and member.isfile() and member.mode == 0o755), "invalid archive mode")
            result.append((name, member, archive.extractfile(member).read() if member.isfile() else None))
        return result


def verify(deb, flavor, version=None):
    require(deb.is_file() and not deb.is_symlink(), "deb must be a regular file")
    architecture, app_path = FLAVORS[flavor]
    controls = members(deb, True)
    require(len(controls) == 1 and controls[0][0] == 'control' and controls[0][1].isfile(),
            "only DEBIAN/control is allowed; no hooks")
    fields = control_fields(controls[0][2].decode())
    actual_version = fields.get('Version', '')
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+){2}', actual_version), "invalid package version")
    require(version is None or actual_version == version, "control version mismatch")
    size = fields.get('Installed-Size', '')
    require(size.isdigit(), "invalid Installed-Size")
    expected = control_fields((REPO / 'Packaging/control.in').read_text().format(
        version=actual_version, architecture=architecture, installed_size=size))
    require(fields == expected, "control fields/flavor mismatch")
    payload = members(deb)
    ancestors = {str(p) for p in PurePosixPath(app_path).parents if str(p) != '.'}
    with temporary_directory(prefix='repopocket-verify-') as temporary:
        root = Path(temporary)
        for name, member, data in payload:
            require(name == app_path or name.startswith(app_path + '/')
                    or (name in ancestors and member.isdir()), "unexpected payload outside App")
            target = root / name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                target.chmod(member.mode)
                require(member.mode == (0o755 if data[:4] in MAGICS else 0o644),
                        "payload executable/resource mode mismatch")
        app = root / app_path
        audit, _, _ = app_audit(app, actual_version)
        installed_size = sum((p.stat().st_size + 1023) // 1024 for p in tree(app) if p.is_file())
        require(int(size) == installed_size, "Installed-Size mismatch")
        files = {name: hashlib.sha256(data).hexdigest()
                 for name, _, data in payload if data is not None}
    return {'package': fields['Package'], 'version': actual_version, 'flavor': flavor,
            'architecture': architecture, 'app_path': app_path,
            'deb_sha256': hashlib.sha256(deb.read_bytes()).hexdigest(),
            'signature_check': 'CodeDirectory pages/embedded entitlements' +
                (' + codesign deep strict' if sys.platform == 'darwin' else ' (not AMFI/CMS or resource-seal trust)'),
            'macho': audit, 'files_sha256': files}


def build(args):
    source = Path(args.app).absolute()
    require(not source.is_symlink(), "source App cannot be a symlink")
    source = source.resolve()
    output = Path(args.output).resolve()
    require(source != output and source not in output.parents, "output cannot be inside source App")
    before = snapshot(source)
    info = plistlib.loads((source / 'Info.plist').read_bytes())
    version = args.version or info.get('CFBundleShortVersionString', '')
    require(isinstance(version, str) and re.fullmatch(r'[0-9]+(?:\.[0-9]+){2}', version), "invalid version")
    app_audit(source, version, signed=args.sign_mode == 'preserve')
    require(shutil.which('dpkg-deb'), "dpkg-deb is required")
    if args.sign_mode == 'ldid':
        require(shutil.which('ldid'), "ldid is required; use --sign-mode preserve only for a verified signed App")
    output.mkdir(parents=True, exist_ok=True)
    architecture, app_path = FLAVORS[args.flavor]
    destination = output / f'RepoPocket_{version}_{architecture}.deb'
    published = [destination, Path(str(destination) + '.sha256'), Path(str(destination) + '.verification.json')]
    require(not any(p.exists() or p.is_symlink() for p in published), "output artifacts already exist")
    created = []
    try:
        with temporary_directory(prefix='.repopocket-stage-', dir=output) as temporary:
            work = Path(temporary)
            root = work / 'root'
            app = root / app_path
            app.parent.mkdir(parents=True)
            shutil.copytree(source, app)
            _, binaries, expected = app_audit(app, version, signed=False)
            for path in [root] + sorted(root.rglob('*')):
                path.chmod(0o755 if path.is_dir() or path in binaries else 0o644)
            if args.sign_mode == 'ldid':
                for index, binary in enumerate(sorted(binaries, key=lambda p: (-len(p.parts), str(p)))):
                    entitlements = work / f'entitlements-{index}.plist'
                    entitlements.write_bytes(plistlib.dumps(expected.get(binary, {})))
                    run('ldid', '-S' + str(entitlements), binary)
                # -s preserves each binary's existing entitlements while rebuilding
                # nested CodeResources from inside out (Procursus ldid, bundle support).
                run('ldid', '-s', app)
            app_audit(app, version)
            # Some ldid builds create .ldid temporary files: reject, never ship them.
            for path in [root] + sorted(root.rglob('*')):
                path.chmod(0o755 if path.is_dir() or path in binaries else 0o644)
            size = sum((p.stat().st_size + 1023) // 1024 for p in tree(app) if p.is_file())
            control = root / 'DEBIAN/control'
            control.parent.mkdir(mode=0o755)
            control.write_text((REPO / 'Packaging/control.in').read_text().format(
                version=version, architecture=architecture, installed_size=size))
            control.chmod(0o644)
            archive = work / 'package.deb'
            run('dpkg-deb', '--root-owner-group', '-Zgzip', '--build', root, archive)
            report = verify(archive, args.flavor, version)
            require(snapshot(source) == before, "source App changed during packaging")
            checksum = work / 'checksum'
            checksum.write_text(f"{report['deb_sha256']}  {destination.name}\n")
            evidence = work / 'verification.json'
            evidence.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
            for origin, target in zip((archive, checksum, evidence), published):
                os.replace(origin, target)
                created.append(target)
    except BaseException:
        for path in created:
            path.unlink(missing_ok=True)
        raise
    print(json.dumps({'deb': str(destination), 'sha256': report['deb_sha256'],
                      'verification': str(published[2])}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    pack = commands.add_parser('build')
    pack.add_argument('--app', required=True)
    pack.add_argument('--output', required=True)
    pack.add_argument('--flavor', choices=FLAVORS, required=True)
    pack.add_argument('--version', help='must match both bundle versions; defaults to Info.plist')
    pack.add_argument('--sign-mode', choices=('ldid', 'preserve'), default='preserve')
    check = commands.add_parser('verify')
    check.add_argument('--deb', required=True)
    check.add_argument('--flavor', choices=FLAVORS, required=True)
    check.add_argument('--version')
    args = parser.parse_args()
    try:
        if args.command == 'build':
            build(args)
        else:
            print(json.dumps(verify(Path(args.deb), args.flavor, args.version), indent=2, sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError, struct.error, plistlib.InvalidFileException,
            tarfile.TarError) as error:
        # Never print parsed entitlement contents or subprocess output.
        print(f'Packaging rejected: {type(error).__name__}: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
