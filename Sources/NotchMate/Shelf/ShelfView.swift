import AppKit
import SwiftUI

struct ShelfView: View {
    @EnvironmentObject var shelf: ShelfStore
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        Group {
            if shelf.items.isEmpty {
                dropZone
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Text("\(shelf.items.count) \(plural(shelf.items.count))")
                            .font(Theme.font(12, .semibold)).foregroundStyle(Theme.secondary)
                        Text("· перетащите наружу, чтобы использовать").font(Theme.font(11)).foregroundStyle(Theme.tertiary)
                        Spacer()
                        IconButton(systemName: "airplayaudio", size: 11, frame: 26, help: "AirDrop всё") { shelf.airDrop(shelf.items) }
                        IconButton(systemName: "doc.on.doc", size: 11, frame: 26, help: "Копировать всё") { shelf.copy(shelf.items) }
                        IconButton(systemName: "trash", size: 11, frame: 26, tint: .red, help: "Очистить полку") {
                            withAnimation(.spring(response: 0.35)) { shelf.clear() }
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(shelf.items) { item in
                                ShelfTile(item: item)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(10)
                .card(radius: 16, fill: vm.isDropTargeted ? Color.white.opacity(0.1) : Theme.surface)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: shelf.items)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: vm.isDropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(vm.isDropTargeted ? .white : Theme.secondary)
                .symbolEffect(.bounce, value: vm.isDropTargeted)
            Text(vm.isDropTargeted ? "Отпустите — сохраню на полке" : "Перетащите файлы, картинки или текст на вырез")
                .font(Theme.font(13, .semibold)).foregroundStyle(vm.isDropTargeted ? .white : Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(vm.isDropTargeted ? Color.white.opacity(0.6) : Theme.tertiary)
        )
        .scaleEffect(vm.isDropTargeted ? 1.02 : 1)
        .animation(.spring(response: 0.3), value: vm.isDropTargeted)
    }

    private func plural(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "объект" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "объекта" }
        return "объектов"
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @EnvironmentObject var shelf: ShelfStore
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: item.icon).resizable().interpolation(.high).frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            Text(item.name).font(Theme.font(10, .medium)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(2).multilineTextAlignment(.center).frame(width: 76)
        }
        .padding(6)
        .frame(width: 88, height: 96)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.surfaceHover : .clear))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                        .foregroundStyle(.white, Color(white: 0.3))
                }
                .buttonStyle(.plain).offset(x: 2, y: -2)
                .transition(.scale)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { shelf.open(item) }
        .contextMenu {
            Button("Открыть") { shelf.open(item) }
            Button("Показать в Finder") { shelf.reveal(item) }
            Button("Копировать") { shelf.copy([item]) }
            Button("Отправить через AirDrop") { shelf.airDrop([item]) }
            Divider()
            Button("Убрать с полки") { shelf.remove(item) }
        }
        .help(item.url.path)
    }
}
