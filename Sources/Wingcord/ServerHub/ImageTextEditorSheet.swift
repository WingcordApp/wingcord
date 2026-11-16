import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore

/// An Image + Text widget's words and picture — Discord's own form: a title of
/// up to 100 characters, a picture up to 10 MB, text of up to 500.
struct ImageTextEditorSheet: View {
    var widgetID: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var image: ImageChoice = .unchanged
    @State private var isPicking = false
    @State private var problem: String?

    /// The picture, as this form has it.
    private enum ImageChoice: Equatable {
        case unchanged
        case replaced(dataURL: String, preview: Data)
        case removed
    }

    private static let titleLimit = 100
    private static let textLimit = 500

    private var config: GuildSpaceWidgetConfig? {
        model.serverHub.draft?.widgets.first { $0.id == widgetID }?.config
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            Text("Image + Text")
                .font(.system(.title2, weight: .bold))
            Form {
                Section {
                    TextField("Title", text: $title, prompt: Text("Something to call it"))
                        .onChange(of: title) { _, new in
                            if new.count > Self.titleLimit { title = String(new.prefix(Self.titleLimit)) }
                        }
                } footer: {
                    ImageTextLimitLabel(count: title.count, limit: Self.titleLimit)
                }
                Section("Image") {
                    ImageTextImageField(
                        preview: previewData,
                        currentURL: currentImageURL,
                        pick: pick,
                        remove: removeImage
                    )
                }
                Section {
                    TextField("Text", text: $text, prompt: Text("What everyone should know"), axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: text) { _, new in
                            if new.count > Self.textLimit { text = String(new.prefix(Self.textLimit)) }
                        }
                } footer: {
                    ImageTextLimitLabel(count: text.count, limit: Self.textLimit)
                }
            }
            .formStyle(.grouped)
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Palette.destructive)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.group)
        .frame(width: 520)
        .task(id: widgetID) { load() }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.png, .jpeg, .gif, .webP], onCompletion: picked)
    }

    // MARK: The picture

    private var previewData: Data? {
        if case .replaced(_, let preview) = image { return preview }
        return nil
    }

    private var currentImageURL: URL? {
        guard image == .unchanged, let config, let guildID = model.selectedGuildID else { return nil }
        if case .replaced(let dataURL) = config.imageChange { return URL(string: dataURL) }
        guard config.imageChange != .removed else { return nil }
        return model.serverHub.demoImageURLs[widgetID] ?? config.imageHash.flatMap {
            CDN.guildSpaceWidgetImage(guildID: guildID, widgetID: widgetID, hash: $0, width: 480)
        }
    }

    private func pick() {
        problem = nil
        isPicking = true
    }

    private func picked(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let picture = AppModel.serverHubImage(at: url) else {
            problem = "Pick a picture up to 10 MB."
            return
        }
        image = .replaced(dataURL: picture.dataURL, preview: picture.data)
    }

    private func removeImage() {
        image = .removed
    }

    // MARK: Opening and closing

    private func load() {
        guard let config else { return }
        title = config.title ?? ""
        text = config.text ?? ""
        switch config.imageChange {
        case .replaced(let dataURL):
            image = AppModel.decodeDataURL(dataURL).map { .replaced(dataURL: dataURL, preview: $0) } ?? .unchanged
        case .removed:
            image = .removed
        case .unchanged:
            image = .unchanged
        }
    }

    private func save() {
        guard var next = config else { return dismiss() }
        next.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
        next.text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        switch image {
        case .unchanged: break
        case .replaced(let dataURL, _): next.imageChange = .replaced(dataURL: dataURL)
        case .removed: next.imageChange = .removed
        }
        // Discord's rule (`zleX9q`): words or a picture, or nothing to save.
        guard next.hasContent else {
            problem = "Add text or an image."
            return
        }
        model.updateServerHubWidget(widgetID, config: next)
        dismiss()
    }

    private func cancel() {
        // A widget added a moment ago and given nothing goes again, rather than
        // waiting on the page as an empty card.
        if let config, !config.hasContent, model.serverHub.draft?.widgets.first(where: { $0.id == widgetID })?.isDraft == true {
            model.removeServerHubWidget(widgetID)
        }
        dismiss()
    }
}
