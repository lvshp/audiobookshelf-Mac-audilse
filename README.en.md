<p align="center">
  <img src="Packaging/AppIcon.png" width="128" alt="Audilse icon">
</p>

<h1 align="center">Audilse</h1>

<p align="center"><a href="README.md">简体中文</a> · English</p>

<p align="center">Listen to your Audiobookshelf library on Mac.</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-007AFF" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
</p>

<p align="center">
  <a href="#installation">Installation</a> ·
  <a href="#features">Features</a> ·
  <a href="#building-from-source">Building from source</a> ·
  <a href="https://github.com/lvshp/audiobookshelf-Mac-audilse/issues">Report an issue</a>
</p>

Audilse is a native macOS client built with Swift, SwiftUI, and AppKit. It connects to your own [Audiobookshelf](https://github.com/advplyr/audiobookshelf) server and supports audiobooks, podcasts, and ebooks.

This is an independent client project and is not affiliated with Audiobookshelf. You need an existing Audiobookshelf server and account to use it.

## Features

- **Audiobook playback**: Stream online, jump between chapters, add bookmarks, adjust playback speed, set a sleep timer, and manage the playback queue.
- **Offline listening**: Download to your Mac and keep listening without a connection. Listening progress syncs when you reconnect.
- **macOS playback controls**: A menu bar player, system media controls, and continued playback after closing the main window.
- **Library browsing**: Cover grids and lists, search, sorting, filters, authors, series, collections, and playlists.
- **Podcast subscriptions**: Search for shows, add RSS feeds, import and export OPML, select episodes to download, and automatically download new episodes.
- **Ebook reading**: EPUB, PDF, CBZ, CBR, and basic reading support for DRM-free MOBI/AZW3 files.
- **Listening activity**: History, listening statistics, and a year in review.
- **Content management**: Edit metadata, covers, chapters, and audio tracks; upload files and manage libraries.
- **Server administration**: Users and permissions, sessions, API keys, backups, logs, and server settings. Available actions depend on your account permissions.
- **Multiple accounts and languages**: Switch between servers and accounts. Supports Simplified Chinese and English.

## Installation

| Item | Requirement |
| --- | --- |
| Operating system | macOS 14 or later |
| Processor | Apple Silicon (M series) |
| Server | Audiobookshelf 2.26+; feature compatibility is based on 2.37.1 |

Download the Apple Silicon DMG from [Releases](https://github.com/lvshp/audiobookshelf-Mac-audilse/releases/latest), open it, and drag **Audilse.app** into **Applications**.

The app is ad-hoc signed and has not been notarized by Apple. To open it for the first time:

1. Double-click Audilse in Applications. If macOS says it cannot verify the developer or check the app for malicious software, dismiss the message.
2. Open **System Settings → Privacy & Security**, scroll down to the message about Audilse, and click **Open Anyway**.
3. Authenticate when prompted, then click **Open**. You can open the app normally afterward.

See [Apple's instructions](https://support.apple.com/en-us/102445).

## Connecting to your server

1. Open Audilse and select **Connect to server**.
2. Enter your server address, such as `https://books.example.com`. If your server uses a subpath, include the full path, such as `https://example.com/audiobookshelf`.
3. Sign in with your server account and select a library to start listening.

Listening progress syncs through your Audiobookshelf server. Downloaded audio can be played offline. Account credentials are stored locally in encrypted form; your login password is not retained.

Audio keeps playing when you close the window using the button in the top-left corner. Use the menu bar icon to reopen the window, or press `⌘Q` to quit the app.

### Adding podcasts

In a podcast library, click **Subscribe** and search by name or paste an RSS URL. After subscribing, open **Manage podcast and episodes → RSS episode selection** and select the episodes to download.

Audiobookshelf downloads podcast episodes to the server first. To listen offline on your Mac, download them to your Mac as well. Enable **Automatically check for and download new episodes** to get future episodes.

## Building from source

You need the full Xcode installation, Swift 6.1 or later, and the patched VLCKit 3.7.3 used by this project. The VLC framework and corresponding source materials are provided separately and are not included in the Git repository. See [dependency setup](BUILDING.md#首次准备依赖) and the [VLC build guide](Packaging/VLC/portable/README.md) (in Chinese).

After importing the verified framework, run this from the project root:

```bash
bash scripts/build-app.sh
```

The app is generated at `build/Audilse.app`. To create a DMG:

```bash
bash scripts/package-dmg.sh build/Audilse.app build/delivery
```

To run tests:

```bash
bash scripts/test.sh
```

You can also open `Audilse.xcodeproj` in Xcode and select the `AudilseApp` scheme.

[GitHub Actions](https://github.com/lvshp/audiobookshelf-Mac-audilse/actions/workflows/build-macos.yml) runs tests and creates a DMG. Build outputs are available under **Artifacts** in successful workflow runs. See the [automated packaging guide](BUILDING.md) (in Chinese) for repository setup.

## Feedback and contributions

Please open an [issue](https://github.com/lvshp/audiobookshelf-Mac-audilse/issues) to report a problem or suggest a feature. Include your macOS, Audilse, and server versions, along with steps to reproduce the problem. For playback issues, include the audio format and whether you were listening online or offline. Remove passwords, tokens, and private server information from logs before sharing them.

Fixes, translations, and interface improvements are welcome. Simplified Chinese and English language resources are in `Sources/Audilse/Resources/`.

## License

Original project material is licensed under the [MIT License](LICENSE).

Third-party components retain their own licenses; see the [third-party notices](Packaging/THIRD_PARTY_NOTICES.md). When distributing an app that includes VLC, also provide the [corresponding source and licensing materials](Packaging/VLC_DISTRIBUTION.md).

Thanks to [Audiobookshelf](https://github.com/advplyr/audiobookshelf), [VideoLAN](https://www.videolan.org/), [GRDB](https://github.com/groue/GRDB.swift), [Socket.IO-Client-Swift](https://github.com/socketio/socket.io-client-swift), [EPUB.js](https://github.com/futurepress/epub.js), and other projects.
