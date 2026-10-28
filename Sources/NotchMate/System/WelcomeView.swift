import AppKit
import SwiftUI

/// First-run tour: what NotchMate is and how to open it, then the permission flow.
struct WelcomeView: View {
    var onFinish: () -> Void

    @State private var page: Int

    init(page: Int = 0, onFinish: @escaping () -> Void) {
        _page = State(initialValue: page)
        self.onFinish = onFinish
    }
    @State private var pulse = false

    private struct Page {
        let symbol: String
        let tint: Color
        let title: String
        let text: String
    }

    private var pages: [Page] {
        [
            Page(symbol: "rectangle.topthird.inset.filled", tint: .orange,
                 title: String(localized: "Привет! Я NotchMate"),
                 text: String(localized: "Я живу за вырезом камеры и держу под рукой музыку, встречи, заметки, файлы и ИИ.")),
            Page(symbol: "cursorarrow.motionlines", tint: Color(red: 0.3, green: 0.63, blue: 1),
                 title: String(localized: "Наведите на вырез"),
                 text: String(localized: "Подведите курсор к вырезу вверху экрана — панель выедет сама. Уведите курсор, и она спрячется.")),
            Page(symbol: "keyboard", tint: Color(red: 0.65, green: 0.49, blue: 1),
                 title: String(localized: "Горячие клавиши"),
                 text: String(localized: "⌃⌥N — открыть панель, ⌃⌥M — быстрая заметка, ⌘1–6 или ← → — вкладки, Esc — закрыть.")),
            Page(symbol: "puzzlepiece.extension.fill", tint: Color(red: 0.3, green: 0.8, blue: 0.7),
                 title: String(localized: "Только нужное"),
                 text: String(localized: "Лишние функции можно выключить в каталоге плагинов. Сейчас попрошу разрешения — только для того, что включено.")),
        ]
    }

    var body: some View {
        let current = pages[page]
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(current.tint.opacity(0.14)).frame(width: 132, height: 132)
                    .scaleEffect(pulse ? 1.06 : 0.96)
                Circle().strokeBorder(current.tint.opacity(0.35), lineWidth: 1).frame(width: 104, height: 104)
                illustration(current)
            }
            .frame(height: 170)
            .padding(.top, 28)
            .id(page)
            .transition(.asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity), removal: .opacity))

            VStack(spacing: 10) {
                Text(current.title).font(.system(size: 22, weight: .bold, design: .rounded))
                Text(current.text)
                    .font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id("text\(page)")
            .transition(.opacity.combined(with: .offset(y: 6)))
            .padding(.top, 8)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule().fill(i == page ? current.tint : Color.primary.opacity(0.15))
                        .frame(width: i == page ? 18 : 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Шаг \(page + 1) из \(pages.count)"))
            .padding(.bottom, 18)

            HStack {
                if page > 0 {
                    Button(String(localized: "Назад")) { go(page - 1) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    Button(String(localized: "Пропустить")) { onFinish() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                Button(page == pages.count - 1 ? String(localized: "Начать") : String(localized: "Далее")) {
                    if page == pages.count - 1 { onFinish() } else { go(page + 1) }
                }
                .buttonStyle(.borderedProminent).tint(current.tint).controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
        }
        .frame(width: 480, height: 440)
        .background(
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), current.tint.opacity(0.16)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: page)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder private func illustration(_ page: Page) -> some View {
        if self.page == 1 {
            // A tiny notch that slides open, the way the real one does on hover.
            VStack(spacing: 0) {
                UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
                    .fill(Color.black)
                    .frame(width: pulse ? 96 : 56, height: pulse ? 44 : 14)
                    .overlay(alignment: .bottom) {
                        if pulse {
                            HStack(spacing: 4) {
                                ForEach(0..<3, id: \.self) { _ in Capsule().fill(Color.white.opacity(0.5)).frame(width: 14, height: 4) }
                            }.padding(.bottom, 8)
                        }
                    }
                Image(systemName: "cursorarrow").font(.system(size: 20, weight: .semibold)).foregroundStyle(page.tint)
                    .offset(x: 18, y: pulse ? -6 : 6)
            }
            .frame(height: 80, alignment: .top)
        } else {
            Image(systemName: page.symbol).font(.system(size: 44, weight: .medium)).foregroundStyle(page.tint)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private func go(_ index: Int) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) { page = index }
    }
}

enum WelcomeWindow {
    private static var window: NSWindow?
    private static let shownKey = "welcomeShown"

    /// New users see the tour once; people upgrading already went through the permission intro.
    static var isFirstRun: Bool {
        let d = UserDefaults.standard
        return !d.bool(forKey: shownKey) && !d.bool(forKey: "permissionsIntroShown")
    }

    static var isVisible: Bool { window?.isVisible ?? false }

    static func show(then finish: @escaping () -> Void) {
        UserDefaults.standard.set(true, forKey: shownKey)
        let view = WelcomeView {
            window?.orderOut(nil)
            finish()
        }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = String(localized: "Добро пожаловать")
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            window = w
        } else {
            window?.contentViewController = NSHostingController(rootView: view)
        }
        window?.setContentSize(NSSize(width: 480, height: 440))
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
