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
# A symbol this test does not define is bound to NULL by that dynamic lookup, and the first call to it faults at address 0 with
# no name in the backtrace. These are the entry points the exercised paths reach and the test defines itself; if one of them is
# left undefined, say which before the run instead of leaving a pc=0x0 to work back from.
undefined_symbols=$(nm -u "$OUT/test" | awk '{print $NF}' | sed 's/^_//' \
  | grep -x -E 'test_mmap|test_backtrace|bounded_vm_map|tl_log_line|husk_binder_is_fd|tl_codewrite_enabled|tl_ld_aot_contains|tl_ld_covers|tl_xmem_contains|tl_errno_to_guest|tl_set_guest_errno|tl_note_once|tl_ld_map_code|tl_ld_symbol_at' || true)
if [ -n "$undefined_symbols" ]; then
  printf 'The test leaves these entry points to the dynamic lookup, which binds them to NULL:\n%s\n' "$undefined_symbols" >&2
  exit 1
fi
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
