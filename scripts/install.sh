#!/usr/bin/env bash
# Akamata CLI installer
#
# Usage:
#   ./scripts/install.sh                 # build & install to $HOME/.local/bin
#   ./scripts/install.sh --prefix=/usr/local
#   PREFIX=/opt/akamata ./scripts/install.sh
#   ./scripts/install.sh --uninstall     # remove the installed binary
#
# Requirements:
#   - zig 0.16+ on PATH
#   - bash, install(1)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_NAME="akamata"
DEFAULT_PREFIX="${PREFIX:-$HOME/.local}"
PREFIX="$DEFAULT_PREFIX"
ACTION="install"
OPTIMIZE="ReleaseSafe"

for arg in "$@"; do
    case "$arg" in
        --prefix=*)    PREFIX="${arg#*=}" ;;
        --debug)       OPTIMIZE="Debug" ;;
        --fast)        OPTIMIZE="ReleaseFast" ;;
        --small)       OPTIMIZE="ReleaseSmall" ;;
        --uninstall)   ACTION="uninstall" ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

BIN_DIR="$PREFIX/bin"
TARGET="$BIN_DIR/$BIN_NAME"

if [ "$ACTION" = "uninstall" ]; then
    if [ -f "$TARGET" ]; then
        rm -f "$TARGET"
        echo "removed: $TARGET"
    else
        echo "not installed at: $TARGET"
    fi
    exit 0
fi

if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig not found on PATH. Install Zig 0.16+ from https://ziglang.org/download/" >&2
    exit 1
fi

ZIG_VERSION="$(zig version)"
echo "==> using zig $ZIG_VERSION"
echo "==> building akamata CLI (optimize=$OPTIMIZE)"

cd "$REPO_ROOT"
zig build cli -Doptimize="$OPTIMIZE"

SRC="$REPO_ROOT/zig-out/bin/$BIN_NAME"
if [ ! -x "$SRC" ]; then
    echo "error: build did not produce $SRC" >&2
    exit 1
fi

echo "==> installing to $TARGET"
mkdir -p "$BIN_DIR"
install -m 0755 "$SRC" "$TARGET"

echo
echo "installed: $TARGET"
echo
if ! echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
    cat <<EOF
note: $BIN_DIR is not on your PATH.
      Add it by appending the following line to your shell rc file
      (~/.zshrc, ~/.bashrc, etc.):

          export PATH="$BIN_DIR:\$PATH"

EOF
fi

"$TARGET" help || true
