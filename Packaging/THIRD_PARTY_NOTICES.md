# Third-party components

Updated 2026-10-19. Audilse's Noncommercial License covers only original project material for which its licensors hold the necessary rights. It does not restrict or replace any third-party license. Each dependency retains its own copyright and license. This document accompanies the exact license texts; it does not replace them or declare all product acceptance complete.

| Component | Fixed version or source | License basis |
| --- | --- | --- |
| GRDB.swift | 7.11.1 | MIT |
| Socket.IO-Client-Swift | 16.1.1 | MIT |
| Starscream | 4.0.8 | Apache-2.0 |
| VLCKit / libVLC | VLCKit commit `319ed2c0724e3d4c4d34889a62fef1ae269491bc`; VLC base `79128878ddb2c280bbb6c89c76a46b31a80ade1c`, 47 upstream patches and Audilse copy-drain modification | LGPL-2.1-or-later for the covered library/module scope; bundled components have separate grants |
| EPUB.js | 0.3.93 | BSD-2-Clause |
| JSZip | 3.10.1 | MIT option selected |
| foliate-js MOBI parser | `78914aef4466eb960965702401634c2cb348e9b1` | MIT; local IIFE export adaptation recorded in Reader/VERSIONS.txt |

Sources: [GRDB](https://github.com/groue/GRDB.swift/tree/v7.11.1), [Socket.IO](https://github.com/socketio/socket.io-client-swift/tree/v16.1.1), [Starscream](https://github.com/daltoniam/Starscream/tree/4.0.8), [VLCKit](https://github.com/videolan/vlckit/tree/319ed2c0724e3d4c4d34889a62fef1ae269491bc), [EPUB.js](https://github.com/futurepress/epub.js/tree/v0.3.93), [JSZip](https://github.com/Stuk/jszip/tree/v3.10.1), [foliate-js](https://github.com/johnfactotum/foliate-js/tree/78914aef4466eb960965702401634c2cb348e9b1).

## Current VLC configuration and notices

The adopted framework is the plugin-exclusion variant, with 232 registered plugins and 295 static input paths per architecture. Its 60 contrib libraries map to 44 source packages. The previously identified eight GPL-source plugin targets, SFTP/libssh2 and Chromecast plugins are excluded from this new artifact; historical source/notices do not imply those inputs are still linked.

The source checkout contains **123 reviewed contrib notice files** under `Packaging/Licenses/VLC-Contrib/`, plus three separate VLC-Modules files. The build script copies the full notice directory into the application. Earlier development packages `73c345b7` and `9fe17df3` contained smaller notice sets; they are historical snapshots, not the current delivery. See [VLC distribution materials](VLC_DISTRIBUTION.md) for the adopted configuration and delivery record.

The current 44-source applicability table is `build/vlc-source-delivery/license-audit/final-applicability-candidate/FinalApplicability.json`. It binds actual new input paths to fixed archives, original notices, selected embedded sources and review evidence. It does not classify all libraries under a single license or require unused tools/test data to be treated as runtime inputs.

Specific retained choices and credits include:

- **FreeType 2.13.1:** the FreeType Project License (FTL) is selected. This software is based in part on the work of the FreeType Team. The complete FTL, acknowledgement and separate BDF/PCF/hash/HarfBuzz-derived notices are retained; the actual pkg-config source alteration is documented with the accompanying source materials.
- **FFmpeg IJG-derived code:** this software is based in part on the work of the Independent JPEG Group. Complete per-file grants, historical release 6a/4 README texts and a separately labelled modification statement are retained. The historical comparison releases are not represented as the unique import revisions; complete diffs accompany the sources.
- **libarchive BLAKE2:** the CC0 alternative is selected and the full official text is retained alongside the original source grants. libarchive's separate compress notices are retained rather than relying on its generic copyright template.
- **Other identified embedded sources:** soxr PFFFT/FFTPACK and Ooura, ebml utf8-cpp, HarfBuzz Microsoft ms-use and Unicode data, FriBidi Unicode data, and libxml2 hash/list grants are preserved in their applicable notices. Current Unicode V3 text is identified as the current official data grant, not falsely labelled an original historical archive member.
- **libpng/modplug:** libpng product acknowledgement is appreciated but not required by its text; source notice and alteration conditions remain. Modplug's public-domain declaration is retained without inventing a mandatory binary acknowledgement.

The independent scope review for VLC `audio_filter/spatializer/revmodel.hpp` and `stream_out/transcode/transcode.h` has passed, closing those specific provenance gaps. The basis is explicit upstream module relicensing and historical source relationships, not an inferred licence from a neighbouring file or a whole-framework legal guarantee. Three separate `Licenses/VLC-Modules/` files preserve the project explanation, original Freeverb text and review; they are not counted among the 123 contrib notices. Full evidence remains in `license-audit/vlc-header-provenance/`.

## Where the materials are provided

In the app, dependency license texts are under `Contents/Resources/Licenses`; Reader license texts remain beside their bundled Reader resources. This document and `VLC_DISTRIBUTION.md` are placed together under `Contents/Resources`. Historical resource-only staging checks are recorded in `build/release-evidence/vlc-notices-resource-20261015/ResourceUpdate.json`. Those checks describe that development snapshot, not the current application's version or executable identity.

In the accompanying local project, use `Packaging/Licenses`, `Sources/Audilse/Resources/Reader`, and **`build/vlc-source-delivery/`**. That delivery directory contains `SourceMaterials.tar`, its manifest, the new framework archive and adopted recipe/lock, actual configuration/link evidence, all reviewed notice batches, IJG original README/source diffs, FreeType change documentation and the source-applicability table. It must accompany the delivery and must not be replaced with a reference to a developer's temporary directory. Public source hosting is not required by this project's selected local delivery method.

See [VLC distribution materials](VLC_DISTRIBUTION.md) for exact source identities, local rebuild/replacement procedure and the final resource-delivery checks. Historical `candidate/`, recipe seed locks, older counts and early `INCOMPLETE` reports remain historical evidence; use the adopted recipe/lock for the current framework. No additional restriction is imposed on modification or reverse engineering for debugging library modifications.

Audilse uses macOS system frameworks and system libarchive directly. Separately, bundled VLC includes static libarchive 3.8.0, whose notices are covered by the VLC source mapping. Audiobookshelf is a separate server; its server source and branding assets are not bundled. Formal Developer ID signing, notarization and public-release operations are outside the requested scope; this does not remove source and notice delivery requirements.
