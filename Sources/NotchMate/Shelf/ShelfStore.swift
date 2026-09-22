import AppKit
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

/// Temporary drop zone for files — drag in, drag out later.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published var selection: Set<UUID> = []

    private let storeDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchMate/Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "shelfItems") ?? []
        items = saved.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ShelfItem(url: $0) }
    }

    func add(urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(ShelfItem(url: url))
        }
        persist()
    }

    /// Plain text / images dropped from apps become files in the cache.
    func add(text: String) {
        let url = storeDir.appendingPathComponent(String(localized: "Текст \(Self.stamp()).txt"))
        try? text.write(to: url, atomically: true, encoding: .utf8)
        add(urls: [url])
    }

    func add(imageData: Data) {
        let url = storeDir.appendingPathComponent(String(localized: "Изображение \(Self.stamp()).png"))
        if let img = NSImage(data: imageData), let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            add(urls: [url])
        }
    }

    func handle(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.add(urls: [url]) } }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.add(imageData: data) } }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                accepted = true
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    guard let s else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.add(text: s) } }
                }
            }
        }
        return accepted
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
        persist()
    }

    func clear() {
        items.removeAll()
        selection.removeAll()
        persist()
    }

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: ShelfItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func airDrop(_ targets: [ShelfItem]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: targets.map(\.url))
    }

    func copy(_ targets: [ShelfItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(targets.map { $0.url as NSURL })
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: "shelfItems")
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH-mm-ss"
        return f.string(from: Date())
    }
}
