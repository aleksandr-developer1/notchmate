import AppKit
import SwiftUI

enum Theme {
    static let surface = Color.white.opacity(0.06)
    static let surfaceHover = Color.white.opacity(0.11)
    static let stroke = Color.white.opacity(0.07)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    static let obsidian = Color(red: 0.55, green: 0.42, blue: 0.98)
    static let yandex = Color(red: 1.0, green: 0.8, blue: 0.0)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct CardBackground: ViewModifier {
    var radius: CGFloat = 16
    var fill: Color = Theme.surface
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 0.5))
        )
    }
}

extension View {
    func card(radius: CGFloat = 16, fill: Color = Theme.surface) -> some View {
        modifier(CardBackground(radius: radius, fill: fill))
    }
}

/// Round icon button with hover highlight and press scale.
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 13
    var frame: CGFloat = 28
    var tint: Color = .white
    var filled = false
    var help: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint.opacity(hovering || filled ? 1 : 0.8))
                .frame(width: frame, height: frame)
                .background(Circle().fill(filled ? Theme.surfaceHover : (hovering ? Theme.surface : .clear)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(help ?? "")
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Pill button with label.
struct PillButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = .white
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
                Text(title).font(Theme.font(12, .semibold)).lineLimit(1)
            }
            .foregroundStyle(prominent ? Color.black : tint)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                Capsule().fill(prominent ? tint.opacity(hovering ? 1 : 0.9) : (hovering ? Theme.surfaceHover : Theme.surface))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// Hover-reactive row background.
struct HoverRow<Content: View>: View {
    var selected = false
    var radius: CGFloat = 10
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Theme.surfaceHover : (hovering ? Theme.surface : .clear))
            )
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

/// Draggable progress bar that thickens on hover.
struct Scrubber: View {
    var value: Double           // 0...1
    var tint: Color = .white
    var onCommit: (Double) -> Void
    var onDragChanged: ((Double?) -> Void)? = nil

    @State private var hovering = false
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let v = dragValue ?? value
            let h: CGFloat = hovering || dragValue != nil ? 7 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(tint)
                    .frame(width: max(h, geo.size.width * CGFloat(min(max(v, 0), 1))))
                    .shadow(color: tint.opacity(0.5), radius: hovering ? 6 : 0)
            }
            .frame(height: h)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragValue = min(max(Double(g.location.x / geo.size.width), 0), 1)
                        onDragChanged?(dragValue)
                    }
                    .onEnded { g in
                        let final = min(max(Double(g.location.x / geo.size.width), 0), 1)
                        onCommit(final)
                        onDragChanged?(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dragValue = nil }
                    }
            )
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        }
        .frame(height: 14)
    }
}

/// Animated audio bars.
struct EqualizerBars: View {
    var isPlaying: Bool
    var tint: Color
    var bars = 4
    var height: CGFloat = 14

    var body: some View {
        // These bars are also used in the collapsed notch; a lower cadence is enough there.
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !isPlaying)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let phase = Double(i) * 1.3
                    let amp = isPlaying
                        ? 0.35 + 0.65 * abs(sin(t * (3.1 + Double(i) * 0.7) + phase) * cos(t * 1.7 + phase * 0.5))
                        : 0.18
                    Capsule()
                        .fill(tint)
                        .frame(width: 3, height: max(3, height * amp))
                }
            }
            .frame(height: height)
        }
    }
}

/// App icon for a bundle id.
struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 16
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}

/// Circular progress ring.
struct Ring: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat = 3
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Styled search / input field.
struct GlassField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .foregroundStyle(.white)
                .focused(focus)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .card(radius: 9, fill: Color.white.opacity(focus.wrappedValue ? 0.1 : 0.06))
    }
}

func formatTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let i = Int(s)
    return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
}
