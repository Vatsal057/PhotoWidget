import WidgetKit
import SwiftUI
import AppIntents

let appGroupID = "PZA655S72B.com.kvaghasiya.photowidget"

/// AlbumEntity id meaning "every photo in the library".
let allAlbumID = "*all*"

func photosDir() -> URL? {
    FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
        .appendingPathComponent("photos", isDirectory: true)
}

/// Albums are subfolders of the photos dir (see the app target).
func listAlbumNames() -> [String] {
    guard let dir = photosDir(),
          let urls = try? FileManager.default.contentsOfDirectory(
              at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
    return urls
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .map(\.lastPathComponent)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

/// album == nil → every photo (root + all albums), else that album's folder.
func listPhotoFiles(album: String?) -> [URL] {
    guard let root = photosDir() else { return [] }
    let dirs = album.map { [root.appendingPathComponent($0, isDirectory: true)] }
        ?? [root] + listAlbumNames().map { root.appendingPathComponent($0, isDirectory: true) }
    return photoFiles(in: dirs)
}

func photoFiles(in dirs: [URL]) -> [URL] {
    dirs
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

/// Path relative to the photos dir: "Beach.jpg" or "Vacation/Beach.jpg".
/// Used as the PhotoEntity id — old configs stored bare filenames, which
/// still resolve (they're just root-relative paths).
func relativeID(_ url: URL) -> String {
    guard let root = photosDir() else { return url.lastPathComponent }
    return url.path.hasPrefix(root.path + "/")
        ? String(url.path.dropFirst(root.path.count + 1))
        : url.lastPathComponent
}

// MARK: - Photo entity (dynamic Edit Widget picker, shows real file names)

struct PhotoEntity: AppEntity {
    /// id == path relative to the photos dir, e.g. "Vacation/Beach sunset.jpg"
    var id: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Photo"
    static let defaultQuery = PhotoQuery()
    var displayRepresentation: DisplayRepresentation {
        let name = ((id as NSString).lastPathComponent as NSString).deletingPathExtension
        let album = (id as NSString).deletingLastPathComponent
        let subtitle: LocalizedStringResource? = album.isEmpty ? nil : "\(album)"
        // Thumbnail takes priority over the filename in the picker row — files
        // are already downscaled JPEGs, so no separate thumbnail pass needed.
        guard let url = photosDir()?.appendingPathComponent(id),
              let data = try? Data(contentsOf: url) else {
            return DisplayRepresentation(title: "\(name)", subtitle: subtitle)
        }
        return DisplayRepresentation(title: "\(name)", subtitle: subtitle, image: .init(data: data))
    }
}

struct PhotoQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PhotoEntity] {
        identifiers.map(PhotoEntity.init(id:))
    }
    /// Sectioned picker: unfiled photos first, then one titled group per album.
    func suggestedEntities() async throws -> ItemCollection<PhotoEntity> {
        var sections = [ItemSection<PhotoEntity>]()
        let root = photoFiles(in: [photosDir()].compactMap { $0 }).map { PhotoEntity(id: relativeID($0)) }
        if !root.isEmpty {
            sections.append(ItemSection("Photos", items: root.map { IntentItem($0) }))
        }
        for album in listAlbumNames() {
            let items = listPhotoFiles(album: album).map { PhotoEntity(id: relativeID($0)) }
            guard !items.isEmpty else { continue }
            sections.append(ItemSection("\(album)", items: items.map { IntentItem($0) }))
        }
        return ItemCollection(sections: sections)
    }
    func defaultResult() async -> PhotoEntity? {
        listPhotoFiles(album: nil).first.map { PhotoEntity(id: relativeID($0)) }
    }
}

// MARK: - Album entity (pick an album to shuffle through)

struct AlbumEntity: AppEntity {
    /// id == album folder name, or allAlbumID for the whole library.
    var id: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Album"
    static let defaultQuery = AlbumQuery()
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: id == allAlbumID ? "All Photos" : "\(id)")
    }
}

struct AlbumQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        identifiers.map(AlbumEntity.init(id:))
    }
    func suggestedEntities() async throws -> [AlbumEntity] {
        [AlbumEntity(id: allAlbumID)] + listAlbumNames().map(AlbumEntity.init(id:))
    }
}

// MARK: - Widget configuration (right-click widget → Edit Widget)

enum FitMode: Int, AppEnum {
    case fill = 0, fit = 1
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scaling"
    static let caseDisplayRepresentations: [FitMode: DisplayRepresentation] = [
        .fill: "Fill (crop to edges)", .fit: "Fit (show whole photo)",
    ]
}

enum RotationInterval: Int, AppEnum {
    case min15 = 15, min30 = 30, hour1 = 60, hour6 = 360, day = 1440
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Interval"
    static let caseDisplayRepresentations: [RotationInterval: DisplayRepresentation] = [
        .min15: "15 Minutes", .min30: "30 Minutes", .hour1: "1 Hour",
        .hour6: "6 Hours", .day: "1 Day",
    ]
    var seconds: TimeInterval { TimeInterval(rawValue) * 60 }
}

struct SelectPhotoIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Photo"
    static let description = IntentDescription("Pick one photo, or shuffle through an album.")
    @Parameter(title: "Photo") var photo: PhotoEntity?
    @Parameter(title: "Shuffle Album (overrides Photo)") var album: AlbumEntity?
    @Parameter(title: "Change Photo Every", default: .hour1) var interval: RotationInterval
    @Parameter(title: "Scaling", default: .fill) var fit: FitMode
    @Parameter(title: "Always display in full color", default: false) var fullColor: Bool
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    let date: Date
    let image: NSImage?
    let fit: FitMode
    let fullColor: Bool
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, image: nil, fit: .fill, fullColor: false) }
    func snapshot(for configuration: SelectPhotoIntent, in context: Context) async -> Entry {
        entry(for: configuration)
    }
    func timeline(for configuration: SelectPhotoIntent, in context: Context) async -> Timeline<Entry> {
        guard let album = configuration.album else {
            // Static photo mode. .never: the app pushes updates via
            // WidgetCenter.reloadAllTimelines().
            return Timeline(entries: [entry(for: configuration)], policy: .never)
        }

        // Shuffle mode: one entry per interval, reshuffled when the timeline
        // ends. A missing album folder (renamed/deleted) falls back to all.
        var name: String? = album.id == allAlbumID ? nil : album.id
        if let n = name, let dir = photosDir()?.appendingPathComponent(n, isDirectory: true),
           !FileManager.default.fileExists(atPath: dir.path) {
            name = nil
        }
        // ponytail: cap 8 entries — each embeds a full bitmap in the archived
        // timeline; more risks the extension's memory limit. .atEnd reshuffles.
        let photos = listPhotoFiles(album: name).shuffled().prefix(8)
        guard !photos.isEmpty else {
            let retry = Date.now.addingTimeInterval(configuration.interval.seconds)
            return Timeline(entries: [Entry(date: .now, image: nil, fit: configuration.fit,
                                            fullColor: configuration.fullColor)],
                            policy: .after(retry))
        }
        let entries = photos.enumerated().map { i, url in
            Entry(date: Date.now.addingTimeInterval(Double(i) * configuration.interval.seconds),
                  image: loadImage(url), fit: configuration.fit, fullColor: configuration.fullColor)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private func entry(for config: SelectPhotoIntent) -> Entry {
        // No explicit choice (or the chosen file was deleted) → first photo.
        let name = config.photo?.id
        let url = name.flatMap { photosDir()?.appendingPathComponent($0) }
        let resolved = (url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            ?? listPhotoFiles(album: nil).first
        return Entry(date: .now, image: loadImage(resolved), fit: config.fit, fullColor: config.fullColor)
    }

    private func loadImage(_ url: URL?) -> NSImage? {
        // Decode fully into memory: a file-backed NSImage(contentsOf:) archives as
        // a file reference that chronod can't read (no App Group entitlement),
        // rendering a blank box. NSImage(data:) embeds the bitmap.
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }
}

// MARK: - View

struct PhotoWidgetEntryView: View {
    var entry: Entry

    // Desktop widgets default to the "Monochrome" accented style, which turns
    // plain Images into solid tint blocks. fullColor keeps the actual pixels;
    // accentedDesaturated shows the photo desaturated + tinted with the
    // system's widget style / accent color.
    private func photo(_ ns: NSImage) -> some View {
        let img = Image(nsImage: ns)
        if #available(macOS 15.0, *) {
            let mode: WidgetAccentedRenderingMode =
                entry.fullColor ? .fullColor : .accentedDesaturated
            return AnyView(img.resizable().widgetAccentedRenderingMode(mode))
        }
        return AnyView(img.resizable())
    }

    var body: some View {
        Group {
            if let image = entry.image {
                if entry.fit == .fill {
                    Color.clear.overlay(
                        photo(image).scaledToFill()
                    ).clipped()
                } else {
                    photo(image).scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus").font(.title2)
                    Text("Open PhotoWidget\nand add a photo")
                        .font(.caption2).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct PhotoWidget: Widget {
    let kind = "PhotoWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectPhotoIntent.self, provider: Provider()) { entry in
            PhotoWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Photo Widget")
        .description("Shows a photo or shuffles an album. Right-click → Edit Widget to configure.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

@main
struct PhotoWidgetBundle: WidgetBundle {
    var body: some Widget { PhotoWidget() }
}
