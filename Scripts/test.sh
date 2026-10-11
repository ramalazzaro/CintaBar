#!/bin/bash
# Runs the unit tests.
#
# With Xcode installed this is just `swift test`. With only the Command Line Tools, SwiftPM
# doesn't look where Swift Testing lives, so this points it there.
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir=$(xcode-select --print-path)
if [[ "$developer_dir" != */CommandLineTools ]]; then
    exec swift test "$@"
fi

frameworks="$developer_dir/Library/Developer/Frameworks"
exec swift test \
    -Xswiftc -F -Xswiftc "$frameworks" \
    -Xswiftc -plugin-path -Xswiftc "$developer_dir/usr/lib/swift/host/plugins/testing" \
    -Xlinker -F -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib" \
    "$@"
