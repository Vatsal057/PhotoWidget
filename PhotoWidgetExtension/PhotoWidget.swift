import WidgetKit
import SwiftUI
import AppIntents

let appGroupID = "PZA655S72B.com.kvaghasiya.photowidget"

func photosDir() -> URL? {
    FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
        .appendingPathComponent("photos", isDirectory: true)
}

func listPhotoFiles() -> [URL] {
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

// MARK: - Photo entity (dynamic Edit Widget picker, shows real file names)

struct PhotoEntity: AppEntity {
    /// id == filename in the photos dir, e.g. "Beach sunset.jpg"
    var id: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Photo"
    static let defaultQuery = PhotoQuery()
    var displayRepresentation: DisplayRepresentation {
        let name = (id as NSString).deletingPathExtension
        // Thumbnail takes priority over the filename in the picker row — files
        // are already downscaled JPEGs, so no separate thumbnail pass needed.
        guard let url = photosDir()?.appendingPathComponent(id),
              let data = try? Data(contentsOf: url) else {
            return DisplayRepresentation(title: "\(name)")
        }
        return DisplayRepresentation(title: "\(name)", image: .init(data: data))
    }
}

struct PhotoQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PhotoEntity] {
        identifiers.map(PhotoEntity.init(id:))
    }
    func suggestedEntities() async throws -> [PhotoEntity] {
        listPhotoFiles().map { PhotoEntity(id: $0.lastPathComponent) }
    }
    func defaultResult() async -> PhotoEntity? {
        try? await suggestedEntities().first
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

struct SelectPhotoIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Photo"
    static let description = IntentDescription("Pick which photo this widget shows.")
    @Parameter(title: "Photo") var photo: PhotoEntity?
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
        // .never: the app pushes updates via WidgetCenter.reloadAllTimelines().
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for config: SelectPhotoIntent) -> Entry {
        // No explicit choice (or the chosen file was deleted) → first photo.
        let name = config.photo?.id
        let url = name.flatMap { photosDir()?.appendingPathComponent($0) }
        let resolved = (url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            ?? listPhotoFiles().first
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
        .description("Shows a photo you picked in the PhotoWidget app. Right-click → Edit Widget to choose which one.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

@main
struct PhotoWidgetBundle: WidgetBundle {
    var body: some Widget { PhotoWidget() }
}
