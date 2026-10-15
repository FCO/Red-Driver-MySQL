#!/bin/sh
set -eu
export RAKUDO_RAKUAST=0
driver_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
red_source=${RED_SOURCE:-/red}
export RED_SOURCE="$red_source"
expected_revision=$(cat "$driver_root/tools/red-revision")
actual_revision=$(git -C "$red_source" rev-parse HEAD)
if [ "$actual_revision" != "$expected_revision" ]; then
    echo "Red revision mismatch: expected $expected_revision, got $actual_revision" >&2
    exit 1
fi
cd "$driver_root"
prove6 -j "${TEST_JOBS:-4}" -e "raku $driver_root/tools/red-test-exec.raku" t
cd "$red_source"
prove6 -j "${TEST_JOBS:-4}" -e "raku $driver_root/tools/red-test-exec.raku" t
