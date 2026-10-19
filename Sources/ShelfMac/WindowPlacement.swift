import AppKit
import SwiftUI
import CoreGraphics

/// Coordinates are relative to the selected display's visible frame, so arranging
/// displays differently does not send a restored window onto another display.
struct SavedWindowPlacement: Codable, Equatable {
    var displayID: String
    var displayName: String? = nil
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func frame(in visible: CGRect) -> CGRect {
        let width = min(max(self.width, 1), visible.width)
        let height = min(max(self.height, 1), visible.height)
        return CGRect(x: min(max(visible.minX + x, visible.minX), visible.maxX - width),
                      y: min(max(visible.minY + y, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }

    var isValid: Bool {
        !displayID.isEmpty && [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}

@MainActor
final class WindowPlacementStore {
    static let shared = WindowPlacementStore()
    static let key = "mainWindowPlacement.v1"
    static let preferredScreenNameKey = "preferredWindowScreenName.v1"
    weak var mainWindow: NSWindow?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var saved: SavedWindowPlacement? {
        guard let data = defaults.data(forKey: Self.key),
              let value = try? JSONDecoder().decode(SavedWindowPlacement.self, from: data), value.isValid else { return nil }
        return value
    }

    func save(_ value: SavedWindowPlacement) {
        guard value.isValid, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.key)
    }

    static func identity(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            return screen.localizedName
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var preferredScreen: NSScreen? {
        if let saved, let screen = NSScreen.screens.first(where: { Self.identity($0) == saved.displayID }) { return screen }
        if let name = saved?.displayName ?? defaults.string(forKey: Self.preferredScreenNameKey),
           let screen = NSScreen.screens.first(where: { $0.localizedName == name }) { return screen }
        return mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }
}

/// The backing view discovers only its own scene window; it never selects a
/// key window (which may be a sheet or another app's newly opened scene).
struct WindowPlacement: NSViewRepresentable {
    var isMain = false
    func makeNSView(context: Context) -> PlacementView { PlacementView(isMain: isMain) }
    func updateNSView(_ nsView: PlacementView, context: Context) {}

    @MainActor final class PlacementView: NSView {
        let isMain: Bool
        private weak var trackedWindow: NSWindow?
        private var restoring = false
        private var receivedFirstKey = false
        private let store = WindowPlacementStore.shared

        init(isMain: Bool) { self.isMain = isMain; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== trackedWindow else { return }
            NotificationCenter.default.removeObserver(self)
            trackedWindow = window
            receivedFirstKey = false
            guard let window else { return }
            if isMain { store.mainWindow = window }
            restore()
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(firstKey), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(changed), name: NSWindow.didMoveNotification, object: window)
            center.addObserver(self, selector: #selector(changed), name: NSWindow.didResizeNotification, object: window)
            center.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }

        private func restore() {
            guard let window = trackedWindow, !window.styleMask.contains(.fullScreen), let screen = store.preferredScreen else { return }
            restoring = true
            defer { restoring = false }
            if isMain, let saved = store.saved {
                window.setFrame(saved.frame(in: screen.visibleFrame), display: false)
            } else if !isMain || store.saved == nil {
                let visible = (isMain ? screen : (store.mainWindow?.screen ?? screen)).visibleFrame
                let size = window.frame.size
                let centered = SavedWindowPlacement(displayID: "temporary", x: (visible.width - size.width) / 2,
                    y: (visible.height - size.height) / 2, width: size.width, height: size.height)
                window.setFrame(centered.frame(in: visible), display: false)
            }
        }

        @objc private func firstKey() {
            guard !receivedFirstKey else { return }
            // SwiftUI may apply its default positioning after attaching content.
            restore()
            receivedFirstKey = true
            if isMain, store.saved == nil { changed() }
        }

        @objc private func changed() {
            guard isMain, receivedFirstKey, !restoring, let window = trackedWindow,
                  !window.isMiniaturized, !window.styleMask.contains(.fullScreen),
                  let screen = NSScreen.screens.max(by: { lhs, rhs in
                      let left = window.frame.intersection(lhs.frame), right = window.frame.intersection(rhs.frame)
                      return (left.isNull ? 0 : left.width * left.height) < (right.isNull ? 0 : right.width * right.height)
                  }) else { return }
            // A display disappearing must not erase the user's preferred display.
            // A deliberate drag while disconnected can still select another one.
            if let saved = store.saved,
               !NSScreen.screens.contains(where: { WindowPlacementStore.identity($0) == saved.displayID }),
               NSEvent.pressedMouseButtons == 0 { return }
            let frame = window.frame, visible = screen.visibleFrame
            store.save(SavedWindowPlacement(displayID: WindowPlacementStore.identity(screen),
                displayName: screen.localizedName, x: frame.minX - visible.minX, y: frame.minY - visible.minY, width: frame.width, height: frame.height))
        }

        @objc private func screensChanged() { restore() }
    }
}
