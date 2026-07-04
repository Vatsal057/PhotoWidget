import SwiftUI
import WidgetKit
import AppKit
import UniformTypeIdentifiers

let appGroupID = "PZA655S72B.com.kvaghasiya.photowidget"

/// All photos live as JPEGs in <group>/photos/. The filename (minus .jpg)
/// is the user-visible name shown in the widget's Edit Widget picker.
func photosDir() -> URL? {
    guard let base = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
    let dir = base.appendingPathComponent("photos", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func listPhotos() -> [URL] {
    guard let dir = photosDir(),
          let urls = try? FileManager.default.contentsOfDirectory(
              at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
    return urls.filter { $0.pathExtension == "jpg" }
        .sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return da < db
        }
}

/// Downscale + re-encode as JPEG. Widgets archive the full bitmap into the
/// timeline, so huge originals must be shrunk or rendering fails/stutters.
func encodeForWidget(_ image: NSImage, maxDim: CGFloat = 1600) -> Data? {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return nil }
    let scale = min(1, maxDim / max(size.width, size.height))
    let w = Int(size.width * scale), h = Int(size.height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()  // flatten transparency for JPEG
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
}

@main
struct PhotoWidgetApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 680, height: 560)
    }
}

struct ContentView: View {
    @State private var photos: [URL] = []
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("PhotoWidget").font(.largeTitle).bold()
                Text("Add photos, then right-click a desktop widget → **Edit Widget** to pick one by name.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(photos, id: \.self) { url in
                        PhotoTile(url: url, onDelete: { delete(url) })
                    }
                    AddTile(onPick: pickPhotos, onDropped: { add(images: $0) })
                }
                .padding(2)
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 440)
        .onAppear {
            migrateSlotsIfNeeded()
            photos = listPhotos()
            // Widgets cache timelines aggressively; refresh whenever the app opens.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// One-time migration from the old fixed-slot layout (slotN.jpg in the root).
    private func migrateSlotsIfNeeded() {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
            let dir = photosDir() else { return }
        for n in 1...6 {
            let old = base.appendingPathComponent("slot\(n).jpg")
            guard FileManager.default.fileExists(atPath: old.path) else { continue }
            try? FileManager.default.moveItem(at: old, to: uniqueURL(in: dir, baseName: "Photo \(n)"))
        }
    }

    private func pickPhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(images: panel.urls.compactMap { url in
            NSImage(contentsOf: url).map { (name: url.deletingPathExtension().lastPathComponent, image: $0) }
        })
    }

    private func add(images: [(name: String, image: NSImage)]) {
        guard let dir = photosDir() else {
            errorText = "App Group container unavailable — check entitlements."
            return
        }
        var failed: [String] = []
        for item in images {
            guard let data = encodeForWidget(item.image) else { failed.append(item.name); continue }
            do { try data.write(to: uniqueURL(in: dir, baseName: item.name), options: .atomic) }
            catch { failed.append(item.name) }
        }
        errorText = failed.isEmpty ? nil : "Couldn't add: \(failed.joined(separator: ", "))"
        photos = listPhotos()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        photos = listPhotos()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// "Beach.jpg", collision → "Beach 2.jpg", "Beach 3.jpg", …
    private func uniqueURL(in dir: URL, baseName: String) -> URL {
        let clean = baseName.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = clean.isEmpty ? "Photo" : clean
        var candidate = dir.appendingPathComponent("\(name).jpg")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(n).jpg")
            n += 1
        }
        return candidate
    }
}

struct PhotoTile: View {
    let url: URL
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                Group {
                    if let img = NSImage(contentsOf: url) {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: "questionmark.square.dashed")
                            .font(.title).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 100)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }

            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).padding(4)
                .help("Remove this photo")
            }
        }
        .onHover { hovering = $0 }
    }
}

struct AddTile: View {
    let onPick: () -> Void
    let onDropped: ([(name: String, image: NSImage)]) -> Void
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus.circle.dashed").font(.title)
            Text("Add photos").font(.caption)
            Text("click or drop").font(.caption2).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .frame(height: 100)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(dropTarget ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: dropTarget ? 2 : 1, dash: [5])))
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTarget) { providers in
            handleDrop(providers)
        }
        .padding(.bottom, 18)  // align with PhotoTile's caption row
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil),
                       let img = NSImage(contentsOf: url) {
                        let name = url.deletingPathExtension().lastPathComponent
                        DispatchQueue.main.async { onDropped([(name, img)]) }
                    }
                }
                handled = true
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage {
                        DispatchQueue.main.async { onDropped([("Photo", img)]) }
                    }
                }
                handled = true
            }
        }
        return handled
    }
}
