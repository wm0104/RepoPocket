#!/usr/bin/env bash
# Python owns validation, isolated staging, signing, and transactional publication.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/verify-deb.py" build "$@"
