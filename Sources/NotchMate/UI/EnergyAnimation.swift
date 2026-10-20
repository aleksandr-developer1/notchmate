import SwiftUI

/// Pause decorative timelines without unmounting the UI and losing drafts or scroll state.
struct EnergyAnimation<Content: View>: View {
    @ObservedObject private var energy = EnergyPolicy.shared
    private let minimumInterval: TimeInterval
    private let paused: Bool
    private let content: (TimelineViewDefaultContext) -> Content

    init(minimumInterval: TimeInterval, paused: Bool = false,
         @ViewBuilder content: @escaping (TimelineViewDefaultContext) -> Content) {
        self.minimumInterval = minimumInterval
        self.paused = paused
        self.content = content
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: max(minimumInterval, energy.state.reducedEffects ? 1.0 / 12 : 0),
                                paused: paused || energy.state.suspended), content: content)
    }
}
