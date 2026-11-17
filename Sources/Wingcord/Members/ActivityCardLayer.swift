import SwiftUI
import WingcordCore

/// An Activity card's popout, beside the card — Discord's (`420018`): who
/// did what over the artwork's colours, the markers, the store, the voice
/// bar, five emoji and a reply (docs/ACTIVITY-CARDS.md decisions 7 to 10).
///
/// **A layer in the window**, the role members' reason: the card is in the
/// member list's drawn canvas, which reports it in the window root's space,
/// and a profile opened from here must come up above it.
///
/// **No click-catcher while hover opened it**, so the list under the pointer
/// keeps tracking it: leaving card and popout closes it (Discord's 100 ms),
/// and a click on the card pins it. Pinned, a click anywhere else closes it.
struct ActivityCardLayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    static let width: CGFloat = 348

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let request = model.activityCardRequest,
                   let entry = model.activityEntry(request.entryID)
                {
                    if !request.opensOnHover {
                        Button { model.activityCardRequest = nil } label: {
                            Color.clear.contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .cancelAction(unless: model.isCovered(.activityCard))
                        .accessibilityLabel(Text("Close activity"))
                        .ignoresSafeArea()
                    }

                    let placement = ProfileCardPlacement(
                        anchor: request.anchor,
                        cardWidth: Self.width,
                        overhang: EdgeInsets(),
                        container: proxy.size
                    )
                    ActivityCardPopout(entry: entry, guildID: model.selectedGuildID)
                        .id(request.entryID)
                        .frame(width: Self.width)
                        .fixedSize(horizontal: false, vertical: true)
                        .onHover { model.setActivityPopoutHovered($0) }
                        .alignmentGuide(.leading) { _ in -placement.cardX }
                        .alignmentGuide(.top) { dimensions in -placement.cardY(forHeight: dimensions.height) }
                        .transition(.materialize(from: placement.growthAnchor))
                }
            }
            .animation(motion.panel, value: model.activityCardRequest?.entryID)
        }
    }
}

// MARK: - The heading's menu

/// Discord's two choices behind the gear (`38055`): about the section, and
/// hiding its cards.
struct ActivitySectionMenu: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            FlyoutRow(title: "About Recent Activity", symbolName: "info.circle") {
                model.activityMenuAnchor = nil
                model.isActivityAboutShown = true
            }
            FlyoutRow(
                title: "Hide Activity Cards",
                symbolName: "eye.slash",
                accessory: .checkbox(settings.hidesActivityCards)
            ) {
                model.setActivityCardsHidden(!settings.hidesActivityCards)
                model.activityMenuAnchor = nil
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: 240)
    }
}

/// "About Recent Activity" — Discord's words (`643460`).
struct ActivityAboutSheet: View {
    @ModalDismiss private var dismiss

    var body: some View {
        ModalAlert(
            hero: .symbol("sparkles", tint: Palette.accent),
            title: "About Recent Activity",
            message: Text("Keep up with what your friends are doing and easily start a conversation or join them!"),
            points: [
                .feature("See the activity of people you talk to most", symbol: "person.2.fill"),
                .feature("Spark a conversation with a reply or emoji", symbol: "bubble.left.fill"),
                .feature("View and delete your past activity from your profile", symbol: "clock.arrow.circlepath"),
            ],
            link: ModalLink(title: "Manage your Activity Privacy") {
                dismiss()
                SettingsWindow.open(.activity)
            },
            actions: [.okay("Done")]
        )
    }
}

/// Where the section's surfaces are presented — at the window root, beside the
/// message actions' own.
struct ActivitySectionPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .overlay { ActivityCardLayer() }
            // A flyout, as every settings choice here is.
            .popover(
                isPresented: Binding(
                    get: { model.activityMenuAnchor != nil },
                    set: { if !$0 { model.activityMenuAnchor = nil } }
                ),
                attachmentAnchor: .rect(.rect(model.activityMenuAnchor ?? .zero)),
                arrowEdge: .bottom
            ) {
                ActivitySectionMenu()
                    .environment(model)
            }
            .modal(isPresented: $model.isActivityAboutShown, style: .alert) {
                ActivityAboutSheet()
            }
    }
}
