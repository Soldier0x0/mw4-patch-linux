#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
chmod +x "$SCRIPT_DIR/community-artifact-fix.sh"
printf 'Executable permission set on %s/community-artifact-fix.sh\n' "$SCRIPT_DIR"
