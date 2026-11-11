#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# macOS only. Unrelated runtime entry points are not invoked.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
clang -O1 -g -fno-omit-frame-pointer -ffunction-sections -fdata-sections -I"$ROOT/src/translation-layer-next" -I"$ROOT/src/translation-layer" \
  "$ROOT/tests/translation-layer/compressed_heap.c" "$ROOT/tests/translation-layer/compressed_heap_window.c" \
  -Wl,-dead_strip -Wl,-undefined,dynamic_lookup -o "$OUT/test"
if "$OUT/test" late; then
  "$OUT/test"
else
  late_status=$?
  printf 'Late test failed with status %s; collecting an LLDB backtrace.\n' "$late_status"
  lldb --batch -o run -o 'register read pc x30 x29 sp' -o 'thread backtrace all' -- "$OUT/test" late || true
  if "$OUT/test"; then
    early_status=0
  else
    early_status=$?
  fi
  printf 'Late test exit status: %s; early test exit status: %s\n' "$late_status" "$early_status"
  exit "$late_status"
fi
