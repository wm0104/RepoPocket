"""Apply the exact local ASCII-whitespace fix to pinned libgit2 source."""
import hashlib
from pathlib import Path
import sys

ORIGINAL_SHA256 = 'bdfc1baecd9aaba56d6b1af28faf95ce8f013e6abcd37c670dd0492830d1361a'
PATCHED_SHA256 = 'd8f5b4c312e749542b0ac1108b73dc868209e9f4320d0cb038df71a743e434a2'
ASCII_SPACE = b"""
/* Git patterns are byte-oriented; UTF-8 bytes are not whitespace separators. */
static bool attr_is_ascii_space(unsigned char c)
{
\treturn c == ' ' || (c >= '\\t' && c <= '\\r');
}

"""


def apply_patch(target: Path) -> str:
    original = target.read_bytes()
    digest = hashlib.sha256(original).hexdigest()
    if digest == PATCHED_SHA256:
        return digest
    if digest != ORIGINAL_SHA256:
        raise ValueError(f'Unexpected libgit2 attr_file.c source: {digest}')
    patched = original.replace(b'git__isspace(', b'attr_is_ascii_space(')
    patched = patched.replace(b'#include <ctype.h>\n', b'#include <ctype.h>\n' + ASCII_SPACE)
    digest = hashlib.sha256(patched).hexdigest()
    if digest != PATCHED_SHA256:
        raise ValueError(f'Unexpected libgit2 patch output: {digest}')
    target.write_bytes(patched)
    return digest


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: patch_native_git.py <src/libgit2/attr_file.c>')
    print('libgit2 ASCII attribute parser SHA256:', apply_patch(Path(sys.argv[1])))
