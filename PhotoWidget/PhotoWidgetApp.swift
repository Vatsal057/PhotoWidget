import SwiftUI
import WidgetKit
import AppKit
import UniformTypeIdentifiers

let appGroupID = "PZA655S72B.com.kvaghasiya.photowidget"

/// Sidebar tag / album value meaning "no album" (photos in the root dir).
let allPhotosID = ""

/// Photos live as JPEGs in <group>/photos/. An album is a subfolder of
/// photos/; a photo belongs to exactly one album (or the root = unfiled).
/// The filesystem is the database — Finder edits are picked up on refresh.
func photosDir() -> URL? {
    guard let base = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
    let dir = base.appendingPathComponent("photos", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func albumDir(_ album: String) -> URL? {
    guard let root = photosDir() else { return nil }
    return album == allPhotosID ? root : root.appendingPathComponent(album, isDirectory: true)
}

func listAlbums() -> [String] {
    guard let dir = photosDir(),
          let urls = try? FileManager.default.contentsOfDirectory(
              at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
    return urls
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .map(\.lastPathComponent)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

/// album == allPhotosID → every photo (root + all albums), else that album only.
func listPhotos(album: String) -> [URL] {
    guard let root = photosDir() else { return [] }
    let dirs = album == allPhotosID
        ? [root] + listAlbums().map { root.appendingPathComponent($0, isDirectory: true) }
        : [root.appendingPathComponent(album, isDirectory: true)]
    return dirs
        .flatMap {
            (try? FileManager.default.contentsOfDirectory(
                at: $0, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])) ?? []
        }
        .filter {
            $0.pathExtension == "jpg" &&
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
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

/// Crop to a unit-space rect (0…1, origin top-left, matching both SwiftUI
/// overlay coordinates and CGImage row order).
func crop(_ image: NSImage, to unit: CGRect) -> NSImage {
    guard unit != CGRect(x: 0, y: 0, width: 1, height: 1),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    let px = CGRect(x: unit.minX * w, y: unit.minY * h,
                    width: unit.width * w, height: unit.height * h).integral
    guard let cut = cg.cropping(to: px) else { return image }
    return NSImage(cgImage: cut, size: NSSize(width: px.width, height: px.height))
}

/// "Beach.jpg", collision → "Beach 2.jpg", "Beach 3.jpg", …
func uniqueURL(in dir: URL, baseName: String) -> URL {
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

@main
struct PhotoWidgetApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 860, height: 560)
    }
}

struct ContentView: View {
    @State private var albums: [String] = []
    @State private var photos: [URL] = []
    @State private var selectedAlbum: String? = allPhotosID
    @State private var errorText: String?

    // Import queue: each pending image gets a crop sheet in turn.
    @State private var importQueue: [(name: String, image: NSImage)] = []
    @State private var importTotal = 0
    @State private var importAlbum = allPhotosID

    // Album create/rename dialogs.
    @State private var creatingAlbum = false
    @State private var renamingAlbum: String?
    @State private var albumNameField = ""

    private var currentAlbum: String { selectedAlbum ?? allPhotosID }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear {
            migrateSlotsIfNeeded()
            refresh()
            // Widgets cache timelines aggressively; refresh whenever the app opens.
            WidgetCenter.shared.reloadAllTimelines()
        }
        // Pick up Finder-level edits of the photos folder on re-activation.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onChange(of: selectedAlbum) { refresh() }
        .sheet(isPresented: Binding(
            get: { !importQueue.isEmpty },
            set: { if !$0 { importQueue = [] } }
        )) {
            if let item = importQueue.first {
                CropSheet(
                    image: item.image,
                    title: "\(importTotal - importQueue.count + 1) of \(importTotal) — \(item.name)",
                    onAdd: { finishImport(cropRect: $0) },
                    onCancel: { importQueue = [] }
                )
                .id(importQueue.count)  // fresh crop rect per queued photo
            }
        }
        .alert("New Album", isPresented: $creatingAlbum) {
            TextField("Name", text: $albumNameField)
            Button("Create") { createAlbum() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Album", isPresented: Binding(
            get: { renamingAlbum != nil },
            set: { if !$0 { renamingAlbum = nil } }
        )) {
            TextField("Name", text: $albumNameField)
            Button("Rename") { renameAlbum() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var sidebar: some View {
        List(selection: $selectedAlbum) {
            Label("All Photos", systemImage: "photo.on.rectangle.angled")
                .tag(allPhotosID)
                .dropDestination(for: URL.self) { urls, _ in drop(urls, into: allPhotosID) }
            Section("Albums") {
                ForEach(albums, id: \.self) { album in
                    Label(album, systemImage: "folder")
                        .tag(album)
                        .dropDestination(for: URL.self) { urls, _ in drop(urls, into: album) }
                        .contextMenu {
                            Button("Rename…") {
                                albumNameField = album
                                renamingAlbum = album
                            }
                            Button("Delete Album", role: .destructive) { deleteAlbum(album) }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                albumNameField = ""
                creatingAlbum = true
            } label: {
                Label("New Album", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationSplitViewColumnWidth(min: 160, ideal: 190)
    }

    private var detail: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(currentAlbum == allPhotosID ? "All Photos" : currentAlbum)
                    .font(.largeTitle).bold()
                Text("Add photos, then right-click a desktop widget → **Edit Widget** to pick a photo or shuffle an album. Drag photos onto a sidebar album to move them.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(photos, id: \.self) { url in
                        PhotoTile(url: url, onDelete: { delete(url) })
                            .draggable(url)
                            .contextMenu {
                                Menu("Move to") {
                                    Button("All Photos") { move(url, to: allPhotosID) }
                                    ForEach(albums, id: \.self) { album in
                                        Button(album) { move(url, to: album) }
                                    }
                                }
                                Button("Remove", role: .destructive) { delete(url) }
                            }
                    }
                    AddTile(onPick: pickPhotos,
                            onDropped: { startImport($0, into: currentAlbum) })
                }
                .padding(2)
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 440)
    }

    // MARK: - State

    private func refresh() {
        albums = listAlbums()
        photos = listPhotos(album: currentAlbum)
    }

    private func photosChanged() {
        refresh()
        WidgetCenter.shared.reloadAllTimelines()
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

    // MARK: - Import (picker / drop → crop sheet queue)

    private func pickPhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        startImport(panel.urls.compactMap { url in
            NSImage(contentsOf: url).map { (name: url.deletingPathExtension().lastPathComponent, image: $0) }
        }, into: currentAlbum)
    }

    private func startImport(_ items: [(name: String, image: NSImage)], into album: String) {
        guard !items.isEmpty else { return }
        guard photosDir() != nil else {
            errorText = "App Group container unavailable — check entitlements."
            return
        }
        importAlbum = album
        importTotal = items.count
        importQueue = items
    }

    private func finishImport(cropRect: CGRect) {
        guard let item = importQueue.first else { return }
        importQueue.removeFirst()
        let image = crop(item.image, to: cropRect)
        if let dir = albumDir(importAlbum), let data = encodeForWidget(image) {
            do { try data.write(to: uniqueURL(in: dir, baseName: item.name), options: .atomic) }
            catch { errorText = "Couldn't add: \(item.name)" }
        } else {
            errorText = "Couldn't add: \(item.name)"
        }
        if importQueue.isEmpty { photosChanged() }
    }

    // MARK: - Move / delete / albums

    /// Sidebar drop: files already in the library move; external files import
    /// (with crop), so Finder drags onto an album work too.
    private func drop(_ urls: [URL], into album: String) -> Bool {
        guard let root = photosDir() else { return false }
        var external: [(name: String, image: NSImage)] = []
        var movedAny = false
        for url in urls {
            if url.path.hasPrefix(root.path + "/") {
                move(url, to: album, refreshing: false)
                movedAny = true
            } else if let img = NSImage(contentsOf: url) {
                external.append((url.deletingPathExtension().lastPathComponent, img))
            }
        }
        if movedAny { photosChanged() }
        if !external.isEmpty { startImport(external, into: album) }
        return movedAny || !external.isEmpty
    }

    private func move(_ url: URL, to album: String, refreshing: Bool = true) {
        guard let dest = albumDir(album),
              url.deletingLastPathComponent().standardizedFileURL != dest.standardizedFileURL else { return }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(
            at: url, to: uniqueURL(in: dest, baseName: url.deletingPathExtension().lastPathComponent))
        if refreshing { photosChanged() }
    }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        photosChanged()
    }

    private func cleanAlbumName(_ raw: String) -> String? {
        let name = raw.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), name.lowercased() != "all photos" else { return nil }
        return name
    }

    private func createAlbum() {
        guard let name = cleanAlbumName(albumNameField), let dir = albumDir(name),
              !FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        refresh()
        selectedAlbum = name
    }

    private func renameAlbum() {
        guard let old = renamingAlbum, let name = cleanAlbumName(albumNameField), name != old,
              let oldDir = albumDir(old), let newDir = albumDir(name),
              !FileManager.default.fileExists(atPath: newDir.path) else { return }
        try? FileManager.default.moveItem(at: oldDir, to: newDir)
        if selectedAlbum == old { selectedAlbum = name }
        photosChanged()
    }

    /// Delete the album folder; its photos move to All Photos, not the trash.
    private func deleteAlbum(_ album: String) {
        guard let root = photosDir(), let dir = albumDir(album) else { return }
        for url in listPhotos(album: album) {
            try? FileManager.default.moveItem(
                at: url, to: uniqueURL(in: root, baseName: url.deletingPathExtension().lastPathComponent))
        }
        try? FileManager.default.removeItem(at: dir)
        if selectedAlbum == album { selectedAlbum = allPhotosID }
        photosChanged()
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

// MARK: - Crop sheet

struct CropSheet: View {
    let image: NSImage
    let title: String
    let onAdd: (CGRect) -> Void
    let onCancel: () -> Void
    @State private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.headline).lineLimit(1).truncationMode(.middle)

            GeometryReader { geo in
                let frame = fitRect(imageSize: image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    CropOverlay(rect: $rect, frame: frame)
                }
            }
            .frame(width: 540, height: 380)

            Text("Drag the box to reposition, corners to resize.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Cancel Import", role: .cancel, action: onCancel)
                Spacer()
                Button("Use Full Image") { onAdd(CGRect(x: 0, y: 0, width: 1, height: 1)) }
                Button("Add") { onAdd(rect) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func fitRect(imageSize: NSSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}

/// Crop rect editor. `rect` is in unit coordinates (0…1) of the image;
/// `frame` is where the image is displayed in the container.
struct CropOverlay: View {
    @Binding var rect: CGRect
    let frame: CGRect
    @State private var startRect: CGRect?

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    private let minSide: CGFloat = 0.05

    private var cropFrame: CGRect {
        CGRect(x: frame.minX + rect.minX * frame.width,
               y: frame.minY + rect.minY * frame.height,
               width: rect.width * frame.width,
               height: rect.height * frame.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Dim everything outside the crop box.
            Path { p in
                p.addRect(frame)
                p.addRect(cropFrame)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

            Rectangle()
                .stroke(.white, lineWidth: 1.5)
                .frame(width: cropFrame.width, height: cropFrame.height)
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .contentShape(Rectangle())
                .gesture(moveGesture)

            ForEach(Corner.allCases, id: \.self) { corner in
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                    .frame(width: 12, height: 12)
                    .position(point(corner))
                    .gesture(resizeGesture(corner))
            }
        }
    }

    private func point(_ c: Corner) -> CGPoint {
        switch c {
        case .topLeft: CGPoint(x: cropFrame.minX, y: cropFrame.minY)
        case .topRight: CGPoint(x: cropFrame.maxX, y: cropFrame.minY)
        case .bottomLeft: CGPoint(x: cropFrame.minX, y: cropFrame.maxY)
        case .bottomRight: CGPoint(x: cropFrame.maxX, y: cropFrame.maxY)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                let base = startRect ?? rect
                startRect = base
                var r = base
                r.origin.x = min(max(0, base.minX + v.translation.width / frame.width), 1 - r.width)
                r.origin.y = min(max(0, base.minY + v.translation.height / frame.height), 1 - r.height)
                rect = r
            }
            .onEnded { _ in startRect = nil }
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let base = startRect ?? rect
                startRect = base
                let dx = v.translation.width / frame.width
                let dy = v.translation.height / frame.height
                var minX = base.minX, minY = base.minY, maxX = base.maxX, maxY = base.maxY
                switch corner {
                case .topLeft: minX += dx; minY += dy
                case .topRight: maxX += dx; minY += dy
                case .bottomLeft: minX += dx; maxY += dy
                case .bottomRight: maxX += dx; maxY += dy
                }
                minX = max(0, min(minX, maxX - minSide))
                minY = max(0, min(minY, maxY - minSide))
                maxX = min(1, max(maxX, minX + minSide))
                maxY = min(1, max(maxY, minY + minSide))
                rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in startRect = nil }
    }
}
