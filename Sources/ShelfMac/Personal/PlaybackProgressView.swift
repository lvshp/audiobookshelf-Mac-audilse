import SwiftUI
import ShelfPlayback

/// Dragging retains the chapter bounds from the start of the gesture.
struct PlaybackProgressView: View {
    let player: PlaybackController
    let useChapterProgress: Bool
    @State private var scrubBounds: ClosedRange<Double>?
    @State private var scrubPosition = 0.0
    @State private var scrubMediaID: String?
    @State private var scrubSessionID: String?

    private var currentBounds: ClosedRange<Double> {
        let duration = max(0, player.duration)
        if useChapterProgress, let chapter = player.currentChapter,
           chapter.start.isFinite, chapter.end.isFinite {
            let start = min(duration, max(0, chapter.start)), end = min(duration, chapter.end)
            if end > start { return start...end }
        }
        return 0...duration
    }
    private var bounds: ClosedRange<Double> { scrubBounds ?? currentBounds }
    private var length: Double { bounds.upperBound - bounds.lowerBound }
    private var position: Double { min(length, max(0, scrubBounds == nil ? player.position - bounds.lowerBound : scrubPosition)) }

    var body: some View {
        HStack(spacing: 9) {
            Text(position.shelfTime).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 49, alignment: .trailing)
            Slider(value: Binding(get: { position }, set: { value in
                beginScrubbing()
                scrubPosition = value
            }), in: 0...max(1, length), onEditingChanged: { editing in
                if editing { beginScrubbing() }
                else { finishScrubbing() }
            }).controlSize(.mini).tint(ShelfTheme.accent)
                .accessibilityLabel(useChapterProgress && player.currentChapter != nil ? L10n.tr("当前章节播放进度") : L10n.tr("播放进度"))
                .disabled(length <= 0)
            Text("−" + max(0, length - position).shelfTime).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 55, alignment: .leading)
        }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
        .onChange(of: player.currentMedia?.id) { _, _ in resetScrubbing() }
        .onChange(of: player.currentSessionID) { _, _ in resetScrubbing() }
        .onChange(of: useChapterProgress) { _, _ in resetScrubbing() }
    }
    private func beginScrubbing() {
        guard scrubBounds == nil else { return }
        scrubBounds = currentBounds
        scrubPosition = min(length, max(0, player.position - bounds.lowerBound))
        scrubMediaID = player.currentMedia?.id; scrubSessionID = player.currentSessionID
    }
    private func finishScrubbing() {
        guard let scrubBounds else { return }
        let target = scrubBounds.lowerBound + min(length, max(0, scrubPosition))
        let mediaID = scrubMediaID, sessionID = scrubSessionID
        resetScrubbing()
        Task {
            guard player.currentMedia?.id == mediaID, player.currentSessionID == sessionID else { return }
            await player.seek(to: target)
        }
    }
    private func resetScrubbing() { scrubBounds = nil; scrubMediaID = nil; scrubSessionID = nil }
}

struct PlaybackSkipLabel: View {
    var forward: Bool
    var seconds: Int
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: forward ? "goforward" : "gobackward").font(.system(size: 20))
                .overlay { Text(String(seconds)).font(.system(size: seconds > 99 ? 6 : 8, weight: .medium)).offset(y: 2) }
        }.accessibilityHidden(true)
    }
}
