import AppKit
import SwiftUI

/// A step-by-step permission flow: one screen per permission, one button to press.
/// macOS shows its own dialog only the first time, so every screen also has the
/// direct link to the exact System Settings page.
struct PermissionsFlowView: View {
    @ObservedObject private var center = PermissionCenter.shared
    let items: [Permission]
    var onFinish: () -> Void

    @State private var index = 0
    @State private var asking = false

    private var current: Permission? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        VStack(spacing: 0) {
            if let p = current {
                card(p)
                    .id(p)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            } else {
                summary
            }
        }
        .frame(width: 380, height: 360)
        .background(background)
        .onAppear { center.refresh(); center.startWatching() }
        .onDisappear { center.stopWatching() }
    }

    private var background: some View {
        LinearGradient(colors: [Color(nsColor: .windowBackgroundColor),
                                (current?.tint ?? .green).opacity(0.14)],
                       startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }

    private func card(_ p: Permission) -> some View {
        let state = center.state(p)
        return VStack(spacing: 0) {
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(p.tint.opacity(0.16)).frame(width: 64, height: 64)
                    Image(systemName: p.icon).font(.system(size: 27, weight: .medium)).foregroundStyle(p.tint)
                }
                .padding(.top, 20)

                VStack(spacing: 6) {
                    Text(p.title).font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(p.why)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                        .fixedSize(horizontal: false, vertical: true)
                }

                statusPill(state)

                if state == .denied {
                    Text("macOS уже спрашивал и больше не спросит. Откройте список и включите «\(Bundle.main.appName)».")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 300)
                }

                VStack(spacing: 8) {
                    Button {
                        if state == .granted { advance(); return }
                        asking = true
                        Task {
                            await center.request(p)
                            asking = false
                            if center.state(p) == .granted { advance() }
                        }
                    } label: {
                        Text(buttonTitle(state)).frame(maxWidth: 190)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(state == .granted ? .green : p.tint)
                    .disabled(asking)

                    if state != .granted, state != .denied {
                        Button("Открыть Системные настройки") { center.open(p) }
                            .buttonStyle(.link)
                    }
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            footer
        }
    }

    private func buttonTitle(_ state: PermissionState) -> String {
        if asking { return "Ждём macOS…" }
        switch state {
        case .granted: return index == items.count - 1 ? "Готово" : "Дальше"
        case .denied: return "Открыть настройки macOS"
        default: return "Разрешить"
        }
    }

    private func statusPill(_ state: PermissionState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : (state == .denied ? "xmark.circle.fill" : "circle.dashed"))
            Text(state.title)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(state.color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(state.color.opacity(0.12)))
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(items.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? Color.primary.opacity(0.7)
                              : (center.state(items[i]) == .granted ? Color.green.opacity(0.6) : Color.secondary.opacity(0.28)))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            Text("\(min(index + 1, items.count)) из \(items.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(index == items.count - 1 ? "Готово" : "Позже") { advance() }
                .buttonStyle(.accessoryBar)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var summary: some View {
        VStack(spacing: 12) {
            Image(systemName: center.missing.isEmpty ? "checkmark.seal.fill" : "hand.thumbsup.fill")
                .font(.system(size: 38)).foregroundStyle(center.missing.isEmpty ? .green : .orange)
            Text(center.missing.isEmpty ? "Всё готово" : "Можно вернуться позже")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            if !center.missing.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(center.missing) { p in
                        Label(p.title, systemImage: p.icon).foregroundStyle(.secondary)
                    }
                }
                Text("Эти разрешения всегда можно выдать в Настройках → Разрешения.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Закрыть") { onFinish() }
                .buttonStyle(.borderedProminent)
        }
        .padding(22)
    }

    private func advance() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            if index >= items.count - 1 { index = items.count } else { index += 1 }
        }
        if index >= items.count, items.allSatisfy({ center.state($0) == .granted }) { onFinish() }
    }
}

/// The same permissions as a compact list — lives in Settings.
struct PermissionsSettings: View {
    @ObservedObject private var center = PermissionCenter.shared

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases) { p in
                    row(p)
                }
            } footer: {
                Text("NotchMate не просит доступ к файлам и не отправляет ничего наружу: запись созвонов, расшифровка и адреса вкладок остаются на этом компьютере.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Пройти мастер разрешений…") { PermissionsWindow.show(onlyMissing: false) }
            }
        }
        .formStyle(.grouped)
        .onAppear { center.refresh(); center.startWatching() }
        .onDisappear { center.stopWatching() }
    }

    private func row(_ p: Permission) -> some View {
        let state = center.state(p)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: p.icon)
                    .foregroundStyle(p.tint)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(p.tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title)
                    Text(p.why).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(state.color).frame(width: 7, height: 7)
                    Text(state.title).font(.caption).foregroundStyle(.secondary)
                }
                if state != .granted {
                    Button("Разрешить") { Task { await center.request(p) } }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Standalone window for the flow — shown on first launch and from the menu.
@MainActor
enum PermissionsWindow {
    private static var window: NSWindow?
    private static let introKey = "permissionsIntroShown"

    static func show(onlyMissing: Bool) {
        let center = PermissionCenter.shared
        center.refresh()
        let items = onlyMissing ? center.missing : Permission.allCases
        guard !items.isEmpty else { return }
        let view = PermissionsFlowView(items: items) { close() }
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
            window.setContentSize(NSSize(width: 380, height: 360))
        } else {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Разрешения"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
    w.setContentSize(NSSize(width: 380, height: 360))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.orderOut(nil)
    }

    /// First launch: walk the user through what the enabled features need.
    static func showIfFirstLaunch() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: introKey) else { return }
        d.set(true, forKey: introKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { show(onlyMissing: true) }
    }
}

extension Bundle {
    var appName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "NotchMate"
    }
}
