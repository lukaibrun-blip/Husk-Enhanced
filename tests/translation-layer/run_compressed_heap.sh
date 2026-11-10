#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# macOS only. Unrelated runtime entry points are not invoked.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
clang -O1 -ffunction-sections -fdata-sections -I"$ROOT/src/translation-layer-next" -I"$ROOT/src/translation-layer" \
  "$ROOT/tests/translation-layer/compressed_heap.c" "$ROOT/tests/translation-layer/compressed_heap_window.c" \
  -Wl,-dead_strip -Wl,-undefined,dynamic_lookup -o "$OUT/test"
"$OUT/test" late
"$OUT/test"
