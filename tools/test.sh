#!/bin/sh
set -eu
driver_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
red_source=${RED_SOURCE:-/red}
export RED_SOURCE="$red_source"
expected_revision=$(cat "$driver_root/tools/red-revision")
actual_revision=$(git -C "$red_source" rev-parse HEAD)
if [ "$actual_revision" != "$expected_revision" ]; then
    echo "Red revision mismatch: expected $expected_revision, got $actual_revision" >&2
    exit 1
fi
patch_file="$driver_root/tools/red-suite-mysql.patch"
if git -C "$red_source" apply --check "$patch_file" 2>/dev/null; then
    git -C "$red_source" apply "$patch_file"
else
    # A rerun may use the same checkout. Reject any other upstream mismatch.
    git -C "$red_source" apply --reverse --check "$patch_file"
fi
cd "$driver_root"
prove6 -j "${TEST_JOBS:-4}" -e "raku $driver_root/tools/red-test-exec.raku" t
cd "$red_source"
prove6 -j "${TEST_JOBS:-4}" -e "raku $driver_root/tools/red-test-exec.raku" t
