#!/bin/sh
set -eu

usage() {
    cat <<'EOF'
Usage: ./build.sh [--release | --debug] [--test] [--open]

  --release  Build an optimized, ad-hoc signed app (default).
  --debug    Build a debug app for development; unsuitable for DSP benchmarks.
  --test     Run Swift package tests before building the app.
  --open     Open the app after a successful build.
  --help     Show this help.

Output: build/AnaLine.app
Requires macOS and a Swift 6 toolchain. FFmpeg is a runtime dependency.
EOF
}

BUILD_CONFIGURATION=release
RUN_TESTS=0
OPEN_APP=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --release) BUILD_CONFIGURATION=release ;;
        --debug) BUILD_CONFIGURATION=debug ;;
        --test) RUN_TESTS=1 ;;
        --open) OPEN_APP=1 ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

PROJECT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "$PROJECT_DIR"
if [ "$RUN_TESTS" -eq 1 ]; then
    swift test -c "$BUILD_CONFIGURATION"
fi
sh "$PROJECT_DIR/Scripts/build-app.sh" "$BUILD_CONFIGURATION"
if [ "$OPEN_APP" -eq 1 ]; then
    /usr/bin/open "$PROJECT_DIR/build/AnaLine.app"
fi
