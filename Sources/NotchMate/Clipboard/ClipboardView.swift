import AppKit
import SwiftUI

struct ClipboardView: View {
    @EnvironmentObject var history: ClipboardHistory
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var vm: NotchViewModel
    @State private var query = ""
    @State private var copiedID: UUID?
    @FocusState private var searchFocused: Bool

    private var filtered: [ClipItem] {
        let base = history.items.sorted { history.pinned.contains($0.id) && !history.pinned.contains($1.id) }
        guard !query.isEmpty else { return base }
        return base.filter { $0.preview.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                GlassField(icon: "magnifyingglass", placeholder: "Поиск в истории буфера", text: $query, focus: $searchFocused) {
                    if let first = filtered.first { copy(first) }
                }
                IconButton(systemName: "trash", size: 11, frame: 30, tint: .red, help: "Очистить (кроме закреплённых)") {
                    withAnimation { history.clear() }
                }
            }
            .onChange(of: searchFocused) { _, f in vm.isTyping = f }

            if !settings.clipboardEnabled {
                placeholder(icon: "eye.slash", text: "История буфера выключена в настройках")
            } else if filtered.isEmpty {
                placeholder(icon: "doc.on.clipboard", text: query.isEmpty ? "Скопируйте что-нибудь — оно появится здесь" : "Ничего не найдено")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { item in row(item) }
                    }
                }
            }
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Theme.tertiary)
            Text(text).font(Theme.font(12)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 14)
    }

    private func copy(_ item: ClipItem) {
        history.copy(item)
        withAnimation(.spring(response: 0.3)) { copiedID = item.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { if copiedID == item.id { copiedID = nil } }
        }
    }

    private func row(_ item: ClipItem) -> some View {
        let pinned = history.pinned.contains(item.id)
        return HoverRow(radius: 10) {
            HStack(spacing: 10) {
                icon(for: item)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.preview).font(Theme.font(12)).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                    HStack(spacing: 4) {
                        if let app = item.sourceApp { Text(app) }
                        Text("·")
                        Text(item.date, format: .relative(presentation: .named))
                    }
                    .font(Theme.font(10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if copiedID == item.id {
                    Label("Скопировано", systemImage: "checkmark").font(Theme.font(11, .semibold)).foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
                IconButton(systemName: pinned ? "pin.fill" : "pin", size: 10, frame: 24, tint: pinned ? .orange : .white) {
                    history.togglePin(item)
                }
                .opacity(pinned ? 1 : 0.6)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .onTapGesture { copy(item) }
        .contextMenu {
            Button("Копировать") { copy(item) }
            if item.isLink, case .text(let s) = item.kind, let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Button("Открыть ссылку") { NSWorkspace.shared.open(url) }
            }
            if case .text(let s) = item.kind {
                Button("Отправить в Obsidian") { _ = AppEnvironment.shared.obsidian.capture(s) }
            }
            Button(pinned ? "Открепить" : "Закрепить") { history.togglePin(item) }
            Divider()
            Button("Удалить") { history.remove(item) }
        }
    }

    @ViewBuilder private func icon(for item: ClipItem) -> some View {
        switch item.kind {
        case .image(let img):
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .files(let urls):
            Image(nsImage: NSWorkspace.shared.icon(forFile: urls.first?.path ?? "")).resizable().frame(width: 22, height: 22)
        case .text:
            Image(systemName: item.isLink ? "link" : "text.alignleft").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.isLink ? .blue : Theme.secondary)
        }
    }
}
