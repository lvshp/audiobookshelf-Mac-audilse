# Portable fixed VLCKit source build

This is an offline source build, not a download fallback to the old official binary. The entry uses Python 3.9 APIs, full Xcode, macOS, and the exact reviewed SourceMaterials.tar. The tested environment is listed below; other toolchains have not been validated. The source archive SHA256 is pinned in build-vlc.py. No old private build tree or installed Vendor framework is used.

Default verification/planning:

Choose your own existing repository, material and entry locations; replace every `/path/to/...` placeholder. Run this command from the portable entry directory:

```sh
/usr/bin/python3 -I ./build-vlc.py \
  --materials /path/to/materials/SourceMaterials.tar \
  --repository /path/to/project \
  --work /path/to/new-work \
  --output /path/to/new-output \
  --protect /path/to/previous-artifacts \
  --arch universal
```

Add `--run` only to start the real build. Work/output must be new, separate directories outside the repository, program directory, material directory and protected paths. Their parents must already exist. Fixed upstream shell code requires work/output paths without whitespace/metacharacters. Existing work/output is refused; a lost command handle is not permission to restart an existing build. Check BuildReceipt.json, logged PID and actual processes first.

The entry validates all 6018 material entries, safe paths/symlinks, the two original source archives, 47 upstream patches plus the local copy-drain patch, 62 fixed SHA512 dependency archives, prepared source file hashes and actual Git history. It derives drivers from the fixed source, applies macOS14 and xpg_echo corrections, gates the exact 46-component set, builds native host tools once, and isolates each architecture's sources, contrib, libVLC, DerivedData and module cache. The second architecture only reuses newly built host tools read-only.

Every external stage has a private cwd, a clean environment, the unchanged real HOME, private TMPDIR and explicit cache directories, recorded PID, log and real exit code. Build commands run under deny-network and deny-repository policies; --protect paths are also read/write denied. Old artifacts/evidence can therefore be protected even during proof of a different-path build. No formal signing or notarization is performed.

Each generated framework must have the expected architecture, macOS14 load commands, system-only dynamic dependencies and a matching dSYM. The public libVLC version/changeset must exactly match the fixed patched identity. A fresh synthetic 96417-frame WAV must round-trip byte-for-byte through the actual rebuilt framework, with no padding. A target architecture must be executable on the build host for this validation; Rosetta is explicitly recorded, never labeled Intel hardware.

For universal output the two same-platform binaries and their DWARF are combined before a single -create-xcframework call. Original per-architecture private generated headers are preserved behind an architecture wrapper. Thin hashes and packaged dSYM are checked, and each final packaged slice is actually decoded again. Compiler/toolchain/path differences can change binary bytes: this recipe promises checked source identity and validated output, not bit-identical binaries on arbitrary Xcode installations.

`test-boundaries.py` exercises malformed paths, escaping symlinks, checksum rejection even under Python optimization, and exact adapter command planning without executing Xcode or a build. It does not substitute for a real build receipt.

## Actual clean build evidence

On 2026-10-14 the unchanged entry recipe SHA256 `ed8ec33b18b60d254228d2be8b9b84d3adf58f9c6caf92bf4b536471b8710a88` completed all 44 stages with exit 0. It ran on an Apple Silicon host with macOS 27.0, Xcode 27.0 build 27A266a, macOS SDK 27.0 and Apple `/usr/bin/python3` 3.9.6. ARM64 executed natively; x86_64 executed through installed Rosetta. Universal validation requires both target executables to run; the entry checks availability and fails instead of silently skipping a target. Intel hardware and other Xcode/SDK/Python combinations were not tested.

The test used separately copied entry/material directories and new work/output directories, while its child sandbox denied all reads and writes to the original private build tree. The delivered evidence is retained in `build/vlc-source-delivery/validation/`; historical paths inside receipts describe the completed test, not required input locations.

Both single-architecture and final packaged frameworks decoded a fresh 96,417-frame PCM fixture byte-for-byte, including its final 417 frames. Framework minOS14, system dynamic dependencies, per-slice hashes and final packaged dSYM UUIDs passed. The prior 655-item evidence manifest stayed unchanged. The resulting universal binary SHA256 is `6d8a6702b7e5aae8823ed5fe4d90b3c795d8580abcae9f4eda20983282a99b5c`; it differs from the earlier historical build and is not a claim of bit-identical reproduction. No product or Vendor integration occurred. This tail test does not revalidate product transport, listening-time semantics or physical Intel playback.

## Project checkout workflow

The source materials and candidate are delivered outside tracked source under `build/vlc-source-delivery/`. Keep this directory with the project delivery; a fresh checkout alone does not contain the 446 MB source archive. No network fallback is used. Its README lists the archive hash and validation evidence.

From the project root, the current reviewed candidate can be checked without changing Vendor:

```sh
/usr/bin/python3 -I scripts/import-patched-vlc.py --source build/vlc-source-delivery/exclusion-candidate-20261015/VLCKit.xcframework
```

Adding `--apply` stages and validates a copy, renames the existing Vendor framework to a unique backup, then renames the staged candidate into place. A failed final rename restores the backup when the destination is still absent. Each rename is atomic; the pair is not a single filesystem transaction. Do not run an import concurrently with a build. The old backup remains available for recovery. `scripts/prepare-vlc.sh` only verifies the current Vendor; it never downloads or silently accepts the historical official binary.

To rebuild from the project checkout, replace the two `/path/to/new-...` locations with new directories whose parent directories already exist:

```sh
/usr/bin/python3 -I Packaging/VLC/portable/build-vlc.py \
  --materials build/vlc-source-delivery/SourceMaterials.tar \
  --repository "$PWD" \
  --work /path/to/new-work \
  --output /path/to/new-output \
  --arch universal
```

This is check-only until `--run` is added. A fresh rebuild can produce different binary bytes. The importer accepts only the candidate locked in `Packaging/VLC/patched-lock.json`; a different rebuilt artifact requires explicit review and a new lock, not a verification bypass. `source-lock.json` and the older `vlc-source-kit` commands retain their historical official-binary scope.

The package lock is checked before local ad hoc signing. Signing the copied app framework changes its Mach-O hash; do not compare that signed copy to the unsigned package digest. App validation must separately check the signature, architectures, fixed runtime identity and playback. Formal signing and notarization are outside this project scope. Static package verification does not replace the native bridge's runtime changeset gate.

## A new binary from the same fixed sources

The reviewed build may produce new bytes in a different directory or toolchain. Keep the complete build work directory and its `BuildReceipt.json` until review finishes. The following tool creates a separate candidate lock; it does not activate it:

```sh
/usr/bin/python3 -I scripts/create-patched-vlc-lock.py \
  --package /path/to/new-output/VLCKit.xcframework \
  --receipt /path/to/new-output/BuildReceipt.json \
  --materials build/vlc-source-delivery/SourceMaterials.tar \
  --work /path/to/new-work \
  --output build/rebuilt-vlc.candidate.json
```

The output must be a new `.candidate.json` outside the input package/work trees. An existing output is refused. The generator verifies the pinned source archive and recipe, both actual source trees and Git identities, the expected package layout and safe internal links, actual file hashes/modes, both slices, macOS14 load commands, dynamic dependencies and matching dSYM UUIDs. It recompiles the capture harness and decodes all 96,417 frames through each actual candidate slice, checking the loaded path and fixed runtime identity. The source/work directory is needed for verified headers and source checks; the old machine's historical receipt paths are not used to locate those inputs. Read-only subprocesses run with network and input writes denied. Python imports do not write bytecode into the project.

Receipt claims are compared with measured artifacts; a receipt is not cryptographic proof that a binary was compiled from those sources. The candidate records `GENERATED_NOT_ACTIVATED`. Review the source inputs, build logs, runtime evidence and candidate diff before intentionally replacing the active project lock. The generator never edits `Packaging/VLC/patched-lock.json`, Vendor or the Swift runtime gate. Its build-environment fields originate in the build receipt; do not infer arbitrary toolchain compatibility from them.

After review, explicitly back up the active lock and copy the reviewed candidate to `Packaging/VLC/patched-lock.json`, then run the existing import plan and explicit `--apply` commands against the new package. Perform this while no build/import is running. Changing only `import --lock` is insufficient: all product build entry points read the canonical project lock. The same fixed-source changeset needs no Swift runtime change. Keep the old lock together with the importer-created Vendor backup so that both can be restored as a pair if validation fails. Do not rename a candidate to the active lock merely because generation succeeded.

The focused boundary test uses disposable cloned packages and records that the active lock, Vendor binary and runtime source remain unchanged:

```sh
/usr/bin/python3 -I scripts/test-patched-vlc-lock.py \
  --package /path/to/new-output/VLCKit.xcframework \
  --receipt /path/to/new-output/BuildReceipt.json \
  --materials build/vlc-source-delivery/SourceMaterials.tar \
  --work /path/to/new-work \
  --test-root /path/to/new-private-test-directory
```

## An intentionally modified library

The generator above supports the fixed source identity only. It deliberately rejects an unrelated changeset; it is not an arbitrary-library trust switch. For a user modification, keep the original source tar unchanged, retain the 47 upstream patches and copy-drain patch, and maintain an explicit local recipe branch with the additional patch and its SHA256. Record the modified tree manifest, actual final Git HEAD/commit sequence and a distinct runtime changeset. Update the local recipe's exact expected source/runtime values and validate the patch before building; retain the source, archive, architecture, dSYM and real-tail checks. Do not remove the checks or claim the old changeset for new source. The existing fixed recipe has no automatic user-patch mode.

A reviewed modified-library integration must update these explicit expectations together:

1. The local build recipe's `load_materials`, `verify_source` and runtime expectations, with the new patch/tree/commit evidence; do not rewrite the historical provenance as if it were the original build.
2. The reviewed package lock's file/mode/link, fat/thin, source and runtime fields. If the lock identity is changed, update the verifier's exact supported identity as well.
3. The exact version/changeset guard in `Sources/ShelfPlayback/NativePCMCompatibilityEngine.swift`. Keep a precise comparison; do not use a wildcard or accept any library reporting VLC 3.x.

These are intentional source changes requiring review, not flags supplied to the fixed candidate generator. After updating the reviewed project lock and runtime expectations, import the matching framework, run `scripts/prepare-vlc.sh`, `scripts/test.sh`, the Release build and `scripts/build-app.sh` into a fresh app directory. Verify the locally signed bundle and re-run actual loaded-path, variant identity and tail PCM checks against the app's framework, followed by the affected transport/lifecycle tests. Wrong identities and the old tail-dropping library must still fail. This workflow rebuilds the application with explicit expectations; simply dropping a different library into the existing signed app is not supported by its current exact identity gate. No formal signing, notarization or publication system is required.
