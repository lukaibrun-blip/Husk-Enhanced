<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
# Husk Enhanced: technical roadmap

## Status and constraints

This roadmap follows the technical audit of Husk 3.4 (149) and the user's later request to implement fixes and prepare a SideStore IPA. Work remains local until reviewed and published; no finding below should be treated as device-verified unless it explicitly says so.

Keep the project under GPL-2.0-or-later. Preserve existing changes, and do not merge into `main` without explicit authorization.

Product and compatibility constraints:

- Preserve the existing APK Store and Google Play path; do not restart that implementation.
- The current native/import implementation allows one base APK plus up to 47 additional APKs (48 total); representative bundle fixtures and memory/resource tests remain outstanding.
- Keep QEMU Full Android's GPU/CPU selection distinct from Translation Layer games. Do not present the QEMU machine/snapshot choice as a per-game renderer option.
- The requested per-game Translation Layer renderer selector is implemented for SDL and Unreal, defaulting to `Automatic (Recommended)`; compatibility and device tests remain outstanding.
- Do not guess JNI results, reduce Unity reservations arbitrarily, reuse an invalid JIT session, add an improvised garbage collector, or switch renderers after unsafe initialization.
- A successful build is not evidence that a particular game works.

## P0 — Establish reproducible safety and compatibility evidence

### 1. Bundle ingestion: parser fixtures before declaring it resolved

Add isolated fixtures for `BundleUnpacker.swift` and test the current parser before changing it. Cover ordinary ZIP and ZIP64 EOCD/locator/record combinations; maximum legal and overflowing offsets/counts/sizes; multi-disk metadata; central/local header disagreements; malformed and duplicate extra fields; encrypted and unsupported flags/methods; invalid UTF-8 names; traversal, duplicate output names, directories and irrelevant entries; data descriptors with and without signatures; truncated and trailing data; stored and deflated payloads; CRC mismatch; declared-size mismatch; and corruption at each read boundary.

Verify ZIP method 8 against actual APKMirror/APKPure/bundletool samples: ZIP uses raw DEFLATE, so the `Compression` `.zlib` stream behavior must be demonstrated with fixtures rather than assumed. Check archive entry boundaries and ensure failures do not leave a partially installed bundle. Test the interaction with `TranslationLayer`'s destination-directory cleanup.

The parser bounds its central directory to 64 MiB, streams payloads in 4 MiB chunks, and now rejects selected entries above 2 GiB or aggregate output above 4 GiB both from declared sizes and while writing. Exact-boundary, overflow, and disk-full fixtures remain outstanding; do not call extraction fully resolved until those tests pass. Review ZIP64 and `UInt64`-to-`Int` conversions under fuzzing or property-based fixtures.

### 2. APK, split and DEX limits

Create real APK/XAPK/APKM/APKS fixtures with base, ABI, language, density, asset-pack and install-time splits; manifest-confirmed and filename-guessed order; duplicate names; missing base; malformed manifests/DEX; and exactly-at/over-limit DEX counts, byte totals, classes and strings. Prove class/method resolution sees split DEX entries and that a failed index prevents every relevant engine start.

Validate the 48-total-APK cap against representative products and installer behavior. Keep the current 47-additional-APK proposal only if fixtures and real-device ingestion pass; otherwise document the limit and failure mode. Exercise install, cancellation, failed unpack, retry, and recovery so no partial library entry is exposed.

### 3. Downloads and repository inputs

Add deterministic HTTP fixtures for direct and background downloads, including full responses, valid and invalid `206`, stale `416`, ignored ranges (`200`), truncation, changed file sizes, retries, cancellation, process relaunch, checksum mismatch and disk exhaustion. The current parser requires a numeric `Content-Range` total and validates resumed body length; fixtures must verify both delegate paths and confirm no partial file is marked complete.

Validate folder manifests before scheduling: nonnegative sizes, safe relative paths, duplicate paths, URL resolution, bounded manifest bytes, and status/content-type handling. Same-path entries currently map to the same task key and completion lookup; establish a test and then either reject duplicates or handle them deterministically. Ensure retries do not overwrite or misattribute another entry.

For APK Store/catalog sources, bound index response size, validate HTTP status and schema fields, validate artifact URLs and filenames, and document the repository trust model. F-Droid metadata hashes are passed to download ingestion when they are SHA-256; this is integrity checking against the fetched index, not repository-signature verification. Decide explicitly whether repository signatures are required. Preserve the current Store/Google Play UI and artifact-ingest path.

### 4. Test infrastructure and clean build

A macOS GitHub Actions workflow now runs the clean iOS build on pushes to `main` and the current audit branch, or by manual dispatch, and uploads the SideStore IPA as an artifact. The PS4 layer is optional because its Bachata-S4/FEXCore sources are separate checkouts. A successful Actions run is still required before claiming the IPA build path works; deterministic host-side fixtures and clean-checkout validation remain outstanding.

## P1 — Runtime correctness and lifecycle

### 5. JNI, Java runtime and engine initialization

Build targeted APK/DEX fixtures for inherited and overloaded methods, static/instance mismatches, exact descriptors, class initialization, app/framework class identity, split-defined classes, missing methods, pending exceptions, class-loader changes and JNI `GetMethodID` behavior. Follow reported names and descriptors exactly, including `Window.getAttributes()` and the reported Yodo1 `initMas` symbol; do not infer successful runtime lookup from a Java source declaration.

For Unity, verify the actual sequence: DEX index and APK registration, optional ANGLE setup, `libmain.so` load/initialization, `JNI_OnLoad`, `NativeLoader.load(String)`, its boolean result, and subsequent IL2CPP hook/library discovery. Add logs/fixtures that distinguish a missing DEX method, a Java exception, library mapping failure, NativeLoader false, and a later UnityMain/IL2CPP crash. Test Unity versions and split layouts before changing this order.

For Godot, add versioned exported-JNI fixtures for Godot 3 and 4 touch signatures and compare action/pointer payloads with Android's contract. The current Godot path may send `ACTION_POINTER_DOWN` without pointer-index bits; treat it as a test lead, not an established cause of issue #200.

### 6. Memory, IL2CPP and JIT

Instrument Unity's requested virtual-memory ranges, alignment, reservation lifetime, actual mmap arguments/results, allocator choice, available-memory snapshots and first failing operation. Reproduce the iPhone 11/iOS 27/ARM64/Husk 3.4 (149) report with the actual game and captured logs before changing reservation sizes or allocator defaults. Keep allocation failures and signal/exception state distinct in diagnostics.

The DVM currently has no tracing garbage collector (`Runtime.gc` is a no-op and Java-reachable objects are intentionally not freed by native reference counting). Treat this as proven retained-object risk, but not as the proven cause of Hill Climb Racing's reported memory growth. First add bounded allocation/retention telemetry and representative long-session fixtures; a collector design needs separate reachability, JNI-reference and thread-root correctness work.

Test JIT bootstrap and StikDebug handoff on supported iOS/device combinations: helper attachment, trap servicing, prewarm allocation, executable self-test, detach/keep-attached behavior, relaunch, and timeout. Do not equate `CS_DEBUGGED` with a working trap servicer, and do not probe in a way that can stall or kill the app. Track the old Husk 3.0 timeout in #183 separately from current-build reports.

### 7. Safe game switching and session cleanup

The current product path stops the active session before starting another; preserve that safety. Audit the cleanup performed by `resetSession`, native loader state, Java globals/class caches, DEX index, threads, EGL/Metal objects, WebViews, audio and temporary files. A fresh-session PR or host test is not sufficient proof that repeated in-process switching is safe on iOS. Require repeated real-APK open/close/reopen tests and memory/thread/resource checks before enabling it. Until then, keep the close-Husk-to-switch behavior.

### 8. Graphics and per-game renderer compatibility

Maintain a renderer/initialization inventory by engine and tested game. Current paths include ANGLE over Metal for GLES-based Translation Layer views; MoltenVK for UE4/Vulkan; Vulkan paths for applicable SDL games; and separate QEMU Full Android GPU and CPU modes. Record the layer, initialization point, device/API requirements, surface/swapchain ownership, first-frame outcome and known fallback behavior for each tested title.

Investigate #188's QEMU GPU first-frame GL error separately from Translation Layer black screens. Capture the first EGL/Vulkan/Metal error and frame/surface state, and compare with CPU mode without treating its reported slow lock-screen boot as equivalent graphics behavior. The per-game renderer selector applies before engine initialization; keep it restricted to the implemented SDL and Unreal paths until compatibility evidence supports other engines.

### 9. Keyboard, text, touch, orientation and controllers

Create input fixtures that cover ASCII and Unicode text/IME composition, key-down/up pairing, hardware HID mapping, gamepad/controller events, pointer IDs, pointer-index action encoding, cancellation, rapid multi-touch, rotation, resizing, keyboard insets and WebView gesture ownership. The software keyboard path uses a US ASCII mapping and logs/drops unsupported characters; establish desired Android text/IME semantics with reproducible apps before changing it.

The SwiftUI touch-cancel path and Godot pointer-index construction are static leads only. Verify complete paths from UIKit to each engine, including cancellation and pointer state cleanup. Keep the #229 keyboard claim separate from its reported black/loading screen because the attached screenshot does not show a typed character reaching the field.

## P2 — Import, signing, issue reproduction and release confidence

### 10. P12 import and signing

Use known-good, wrong-password, empty-password, malformed and truncated PKCS#12 fixtures. Trace picker copy/security-scoped access, passphrase variants, `SecPKCS12Import` status, Keychain write/read and signing-code handoff separately. Verify Keychain accessibility across relaunch and device lock. Do not interpret `-25293` alone as proof of a bad file or password. Keep the #220 release fix separate from #246 until its inaccessible `husk.log` or a reproduction is available.

### 11. Issue reproduction matrix

Track each result as proven, hypothesized, fixed, old, device-specific, unreproduced or insufficient evidence. Record exact device, iOS, Husk build, game/version, install/JIT method, renderer, logs, reproduction steps and first failing event. Do not mark a game fixed based solely on a source change, PR claim, another device, or a successful build.

### 12. Acceptance gate

Before implementation is considered complete: parser and ingestion fixtures pass; no partial artifact is installed; limits and errors are user-visible; download recovery and checksum behavior pass deterministic tests; JNI/engine tests preserve correct class/method behavior; lifecycle changes pass repeated device sessions; graphics choices are documented per game; P12 fixtures pass; and a clean build/package path is demonstrated. Run device/game validation on the relevant hardware separately. Report every test and device actually used.
