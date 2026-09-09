import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore

/// The "Create your own" widget, being written.
///
/// **Every picture is a two-step upload and neither step happens here.** A file
/// picked in this view is held as bytes; the upload runs at Save, because the
/// route hands back a filename that is only meaningful inside the same `PUT`
/// that quotes it — uploading on selection would leave orphaned blobs in
/// Discord's bucket every time somebody changed their mind. See
/// `ProfileEditor.save` and `DiscordREST.uploadWidgetAsset`.
///
/// So the pictures on screen come from the reader's own disk, not the network:
/// a staged asset has no address anything can fetch. `PersonalAssetImage` covers
/// the other half.
struct PersonalWidgetEditor: View {
    var widget: PersonalWidget
    /// Bytes the reader has picked, by the slot they belong to. Held on the
    /// editor rather than here so they survive this view being rebuilt.
    var pending: [PersonalWidgetSlot: Data]
    var update: (PersonalWidget) -> Void
    var pick: (PersonalWidgetSlot) -> Void

    private static let coverHeight: CGFloat = 118
    private static let fieldSide: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            header
            cover
            fields
        }
    }

    private var header: some View {
        TextField(
            "Add Widget Name",
            text: Binding(
                get: { widget.header },
                set: { edited in
                    var next = widget
                    next.header = edited
                    update(next)
                }
            )
        )
        .textFieldStyle(.plain)
        .font(.system(.subheadline, weight: .semibold))
        .foregroundStyle(InkColor.primary)
    }

    // MARK: The cover

    private var cover: some View {
        ZStack(alignment: .bottomLeading) {
            picture(for: .cover)
                .frame(height: Self.coverHeight)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
                .overlay(alignment: .topLeading) {
                    pickButton(.cover).padding(Spacing.base)
                }

            VStack(alignment: .leading, spacing: 2) {
                slotField(
                    "Add Title",
                    text: Binding(
                        get: { widget.cover.title },
                        set: { edited in
                            var next = widget
                            next.cover.title = edited
                            update(next)
                        }
                    ),
                    font: .system(.title3, weight: .bold)
                )
                slotField(
                    "Add description",
                    text: Binding(
                        get: { widget.cover.subtitle },
                        set: { edited in
                            var next = widget
                            next.cover.subtitle = edited
                            update(next)
                        }
                    ),
                    font: .system(.subheadline)
                )
            }
            .padding(Spacing.snug)
        }
    }

    // MARK: The four slots

    /// **Blocks are added, not laid out empty.** Discord's editor starts with
    /// the cover alone and grows the grid one block at a time from an "Add
    /// Blocks" control — and the wire agrees: a captured widget with two filled
    /// slots sends exactly two, not four with two blanks. An editor that always
    /// drew four would send four, and the profile would grow two empty rows.
    @ViewBuilder
    private var fields: some View {
        if !widget.fields.isEmpty {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.snug), count: 2),
                spacing: Spacing.snug
            ) {
                ForEach(widget.fields.indices, id: \.self) { index in
                    fieldSlot(index)
                }
            }
        }
        if widget.fields.count < PersonalWidget.fieldLimit { addBlock }
    }

    /// The rule with a `+` on it, between the cover and whatever is under it.
    private var addBlock: some View {
        Button {
            var next = widget
            next.fields.append(PersonalWidget.Field())
            update(next)
        } label: {
            ZStack {
                Rectangle()
                    .fill(Palette.railHairline)
                    .frame(height: 1)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(InkColor.primary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.surfaceRaised))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Add Blocks")
        .accessibilityLabel(Text("Add a block"))
    }

    private func fieldSlot(_ index: Int) -> some View {
        let field = widget.fields.indices.contains(index)
            ? widget.fields[index]
            : PersonalWidget.Field()
        return HStack(spacing: Spacing.base) {
            picture(for: .field(index))
                .frame(width: Self.fieldSide, height: Self.fieldSide)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .overlay { pickButton(.field(index)) }

            VStack(alignment: .leading, spacing: 1) {
                slotField(
                    "Add title",
                    text: Binding(
                        get: { field.title },
                        set: { edited in write(index) { $0.title = edited } }
                    ),
                    font: .system(.subheadline, weight: .semibold)
                )
                slotField(
                    "Add description",
                    text: Binding(
                        get: { field.description },
                        set: { edited in write(index) { $0.description = edited } }
                    ),
                    font: .system(size: 11)
                )
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .topTrailing) { removeBlock(index) }
    }

    /// Takes one block off. **A block is removed whole**, picture and words
    /// together — there is no state where a slot exists with nothing in it once
    /// the reader has decided against it.
    private func removeBlock(_ index: Int) -> some View {
        Button {
            var next = widget
            guard next.fields.indices.contains(index) else { return }
            next.fields.remove(at: index)
            update(next)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.surfaceRaised))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Remove block \(index + 1)"))
    }

    /// Writes one slot that already exists.
    private func write(_ index: Int, _ edit: (inout PersonalWidget.Field) -> Void) {
        var next = widget
        guard next.fields.indices.contains(index) else { return }
        edit(&next.fields[index])
        update(next)
    }

    // MARK: Pieces

    /// - Parameter text: **a `Binding`, not a value and a setter.** Threading
    ///   the setter through as a closure makes it `@Sendable` — `Binding`
    ///   requires that — and every such closure here touches main-actor state,
    ///   so the isolation warning simply moves to the call sites. Built at the
    ///   call site instead, it is the same expression the header field already
    ///   uses and the compiler is content.
    private func slotField(_ prompt: String, text: Binding<String>, font: Font) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(InkColor.primary)
    }

    /// What is in a slot: the picked bytes, the stored plate, or nothing yet.
    @ViewBuilder
    private func picture(for slot: PersonalWidgetSlot) -> some View {
        if let data = pending[slot], let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let asset = slot.asset(in: widget) {
            PersonalAssetImage(asset: asset, side: 256)
        } else {
            Rectangle().fill(Palette.skeletonPlate)
        }
    }

    private func pickButton(_ slot: PersonalWidgetSlot) -> some View {
        Button { pick(slot) } label: {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(InkColor.secondary)
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.canvas.opacity(0.7))
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(slot.pickLabel))
    }
}

/// Which picture in a personal widget is being talked about.
///
/// A value rather than an index, because the cover and a field are two different
/// shapes and a bare `Int?` at a call site reads as neither.
enum PersonalWidgetSlot: Hashable, Sendable {
    case cover
    case field(Int)

    var pickLabel: String {
        switch self {
        case .cover: "Choose a cover picture"
        case .field(let index): "Choose a picture for slot \(index + 1)"
        }
    }

    func asset(in widget: PersonalWidget) -> PersonalWidget.Asset? {
        switch self {
        case .cover: widget.cover.image
        case .field(let index):
            widget.fields.indices.contains(index) ? widget.fields[index].image : nil
        }
    }
}

/// Asks for one picture off disk.
///
/// **PNG, JPEG, GIF and WebP**, which is what Discord's own upload accepts for
/// these — the captured uploads are PNG, and the widget reply carries
/// `is_animated`, so an animated GIF is in scope.
enum WidgetImagePicker {
    static func pick() -> (name: String, bytes: Data)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bytes = try? Data(contentsOf: url)
        else { return nil }
        return (url.lastPathComponent, bytes)
    }
}
