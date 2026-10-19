import SwiftUI
import AppKit

@main
struct ShelfMacApp: App {
    @State private var store = AppStore()
    @Environment(\.openWindow) private var openWindow
    @State private var languages = AppLanguageStore.shared
    @NSApplicationDelegateAdaptor(ShelfAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Audisle", id: "main") {
            MainWindowContent(store: store, appDelegate: appDelegate)
                .background(WindowPlacement(isMain: true))
                .frame(minWidth: 920, minHeight: 650)
                .task { appDelegate.store = store; await store.bootstrap() }
                .preferredColorScheme(store.appearance.colorScheme)
                .tint(ShelfTheme.accent)
                .environment(\.locale, languages.selection.locale)
                .environment(\.layoutDirection, .leftToRight)
                .textFieldStyle(.shelfLeading)
        }
        .defaultSize(width: 1280, height: 840)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button(L10n.tr("打开公开分享…")) { openWindow(id: "public-share") }
                Button(L10n.tr("连接服务器…")) { store.showConnection = true }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu(L10n.tr("播放")) {
                Button(store.activePlayer?.isPlaybackRequested == true ? L10n.tr("暂停") : L10n.tr("继续播放")) {
                    store.activePlayer?.togglePlayPause()
                }.keyboardShortcut(.space, modifiers: [])
                Button(L10n.format("后退 %1$@ 秒", String(describing: store.playbackPreferences.jumpBackwardAmount))) {
                    let player = store.activePlayer, amount = store.playbackPreferences.jumpBackwardAmount
                    Task { await player?.skip(by: -Double(amount)) }
                }.keyboardShortcut(.leftArrow, modifiers: [.command]).disabled(store.activePlayer?.currentMedia == nil)
                Button(L10n.format("前进 %1$@ 秒", String(describing: store.playbackPreferences.jumpForwardAmount))) {
                    let player = store.activePlayer, amount = store.playbackPreferences.jumpForwardAmount
                    Task { await player?.skip(by: Double(amount)) }
                }.keyboardShortcut(.rightArrow, modifiers: [.command]).disabled(store.activePlayer?.currentMedia == nil)
                Button(L10n.format("减慢 %1$@×", String(describing: store.playbackPreferences.playbackRateIncrementDecrement.formatted()))) {
                    if let player = store.activePlayer { store.adjustPlaybackRate(-1, for: player) }
                }.disabled(store.activePlayer?.currentMedia == nil || store.activePlayer?.canAdjustRate(by: -store.playbackPreferences.playbackRateIncrementDecrement) != true)
                Button(L10n.format("加快 %1$@×", String(describing: store.playbackPreferences.playbackRateIncrementDecrement.formatted()))) {
                    if let player = store.activePlayer { store.adjustPlaybackRate(1, for: player) }
                }.disabled(store.activePlayer?.currentMedia == nil || store.activePlayer?.canAdjustRate(by: store.playbackPreferences.playbackRateIncrementDecrement) != true)
                Button(L10n.tr("停止播放并同步")) { Task { await store.stopPlaybackAndSync() } }
            }
            CommandGroup(replacing: .help) {
                Link(L10n.tr("Audiobookshelf 文档"), destination: URL(string: "https://audiobookshelf.org/docs/")!)
            }
        }
        Window(L10n.tr("公开分享"), id: "public-share") {
            PublicShareView(store: store)
                .background(WindowPlacement())
                .preferredColorScheme(store.appearance.colorScheme)
                .tint(ShelfTheme.accent)
                .environment(\.locale, languages.selection.locale)
                .environment(\.layoutDirection, .leftToRight)
                .textFieldStyle(.shelfLeading)
        }
        .defaultSize(width: 900, height: 720)
        .windowStyle(.titleBar)
        MenuBarExtra("Audisle", systemImage: "headphones") {
            MenuBarPlayerView(store: store)
                .environment(\.locale, languages.selection.locale)
        }.menuBarExtraStyle(.window)
        Settings {
            PreferencesView(store: store)
                .background(WindowPlacement())
                .frame(width: 560, height: 460)
                .environment(\.locale, languages.selection.locale)
                .environment(\.layoutDirection, .leftToRight)
                .textFieldStyle(.shelfLeading)
        }
    }
}

@MainActor
final class ShelfAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    var reopenMainWindow: (() -> Void)?
    private var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        guard let store else { return .terminateNow }
        isTerminating = true
        Task {
            let mayTerminate = await store.shutdown()
            if !mayTerminate { isTerminating = false }
            sender.reply(toApplicationShouldTerminate: mayTerminate)
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenMainWindow?()
        sender.activate(ignoringOtherApps: true)
        return false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct MainWindowContent: View {
    @Bindable var store: AppStore
    let appDelegate: ShelfAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ShellView(store: store)
            .onAppear {
                appDelegate.reopenMainWindow = { openWindow(id: "main") }
            }
    }
}
