import SwiftUI
import WingcordCore

/// The window's root: signed out, connecting, or the workspace.
///
/// **The three states are one view type**, for the same reason the detail column
/// is: swapping the window's root between structurally different views makes the
/// split view rebuild from scratch on every connection blip, which loses column
/// widths and scroll positions. The workspace is always present once it has ever
/// been reached; the sign-in and the connecting state are overlays on top of it.
struct RootView: View {
    @Environment(AppModel.self) private var model

    /// Whether the window's toolbar is up. The comment on the modifier that
    /// reads it gives the three reasons it is not.
    private var showsToolbar: Bool {
        model.showsWorkspace && !model.isColumnTakenOver && !model.isFullProfileShown
    }

    var body: some View {
        MainWindow()
            .opacity(model.showsWorkspace ? 1 : 0)
            .overlay {
                if !model.showsWorkspace {
                    SignInView()
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                ConnectionBanner(state: model.connectionState)
            }
            .overlay(alignment: .top) {
                ActionNoticeView(notice: model.actionNotice) {
                    model.actionNotice = nil
                }
            }
            // No chrome before there is anything to be chrome FOR.
            //
            // The split view is always in the tree — it is held at opacity 0 so
            // its column widths and scroll positions survive a reconnect — and a
            // split view installs its own sidebar toggle whether or not anyone
            // can see the sidebar. Hiding the window's toolbar is what removes
            // it, because the item is the system's and there is nothing of ours
            // to take away.
            // **And hidden over a takeover, for the same reason.** The gate and
            // discovery both draw `ChannelChrome.none`, which empties every
            // control the bar builds — but the *search field* is the system's,
            // installed by `.searchable`, and an empty chrome value cannot
            // remove it. It sat over discovery offering to search a server
            // nobody could see. There is nothing else in the bar during a
            // takeover, so the bar goes.
            // **And hidden under the full profile, which is the third
            // reason and the only one that is not about what the bar contains.**
            // See `AppModel.isFullProfileShown`: that surface dims the window
            // and the toolbar is the one strip a layer in the content view
            // cannot dim.
            .toolbarVisibility(showsToolbar ? .automatic : .hidden, for: .windowToolbar)
            // **Every change is traced.** A toolbar that went missing in a long
            // session is what this came from; the line names which of the
            // three inputs moved, so the next report is a log read rather than
            // a guess.
            .onChange(of: showsToolbar) { _, shown in
                DiagnosticLog.trace(
                    "window",
                    "toolbar \(shown ? "shown" : "hidden"): workspace=\(model.showsWorkspace) "
                        + "takeover=\(model.isColumnTakenOver) fullProfile=\(model.isFullProfileShown) "
                        + "connection=\(model.connectionState)"
                )
            }
            .animation(.easeOut(duration: 0.2), value: model.showsWorkspace)
            .animation(.easeOut(duration: 0.2), value: model.isColumnTakenOver)
            .animation(.easeOut(duration: 0.2), value: model.isFullProfileShown)
            // A channel becoming the destination is what triggers its history
            // fetch and its roster subscription. Driven from `onChange` rather
            // than from the click handler, so a selection restored at launch,
            // one from a message link and one from a keyboard shortcut all take
            // the same path.
            .onChange(of: model.selectedChannelID, initial: true) { _, channelID in
                guard let channelID else { return }
                model.channelDidOpen(channelID)
            }
            // The server's own pages are gated on their routes having answered,
            // so a server has to be asked before its rows can exist. Settled and
            // cancellable inside the controller — see `guildDidOpen` — so
            // stepping through the rail asks about nothing.
            .onChange(of: model.selectedGuildID, initial: true) { _, guildID in
                guard let guildID else { return }
                model.sessionController.guildDidOpen(guildID)
            }
            // A previewed channel is a channel being read, so it takes the same
            // path a selected one does — the history fetch and the roster
            // subscription both live behind `openChannel`, and a preview that
            // skipped them would draw "Loading messages…" for ever.
            .onChange(of: model.previewedChannelID) { _, channelID in
                guard let channelID else { return }
                model.channelDidOpen(channelID)
            }
            // **Where SwiftUI's root actually starts.** Every popover raised
            // from a drawn canvas is anchored to a rect in *this* view's space,
            // and this view is laid out below the titlebar strip while the
            // hosting view under it spans the whole window. Publishing the
            // origin is what lets `anchorInHostingRoot` finish the conversion
            // instead of guessing at it — see `PresentationOrigin`.
            //
            // `onGeometryChange` rather than a `GeometryReader`: it reads the
            // value the layout already computed and fires only when it changes,
            // where a reader is an extra layout container and an extra pass.
            .onGeometryChange(for: CGPoint.self) { proxy in
                proxy.frame(in: .global).origin
            } action: { origin in
                PresentationOrigin.record(origin)
            }
            // **Installed once, at the root, and it is the only thing that can
            // navigate.** `MessageNotifier` owns the delegate callback and
            // nothing else; where a press *goes* is the window's business, and a
            // closure is what keeps the notifier free of the store.
            .task {
                // Captured strongly, deliberately: the store outlives this
                // view — it is the app's own `@State` — so a weak capture here
                // would be guarding against a lifetime that cannot end, and
                // the notifier is held by the store anyway. The cycle it
                // completes is store → notifier → store, which lasts exactly as
                // long as the process.
                model.notifier.open = { channelID, messageID in
                    model.openNotifiedMessage(channelID, messageID)
                }
            }
            .task {
                MemoryPressureWatcher.shared.start()
                Breadcrumbs.record("root appeared")
                await model.resumeStoredSessionIfAvailable()
            }
    }
}

extension AppModel {
    /// Whether the workspace is worth showing.
    ///
    /// A reconnect keeps it up — the data on screen is still true, and blanking
    /// the window every time a laptop's Wi-Fi hiccups is worse than a quiet
    /// banner.
    var showsWorkspace: Bool {
        switch connectionState {
        case .ready, .reconnecting: currentUserID != nil
        case .signedOut, .connecting, .failed: false
        }
    }

    /// Signs in automatically when exactly one account is stored.
    ///
    /// With several, the picker is shown rather than one being chosen — an app
    /// that silently picks an account is one that opens the wrong one.
    func resumeStoredSessionIfAvailable() async {
        guard case .signedOut = connectionState else { return }
        let accounts = AccountLedger.accounts()
        DiagnosticLog.trace("app", "stored accounts: \(accounts.count)")
        guard accounts.count == 1, let account = accounts.first else { return }
        resumeSession(for: account)
    }
}

/// What an act that did not land says — or one that landed out of sight.
///
/// **Transient, and one at a time.** A refused pin, delete or block is a click
/// that visibly did something and then visibly undid it, which reads as the app
/// being broken rather than as the server saying no. It is not an alert: nothing
/// here needs a decision, and a modal for "that did not work" interrupts the
/// thing the reader was doing to tell them it failed. A message scheduled from
/// the composer is the other case: the composer empties and nothing appears, so
/// this says when it will go, with the clock Discord's own toast carries.
private struct ActionNoticeView: View {
    var notice: ActionNotice?
    var dismiss: () -> Void

    @Environment(\.motion) private var motion

    /// Long enough to read a sentence, short enough not to sit over the
    /// transcript while somebody carries on.
    private static let dwell = Duration.seconds(4)

    var body: some View {
        Group {
            if let notice {
                HStack(spacing: Spacing.base) {
                    Image(symbol: Self.symbol(for: notice.kind))
                        .font(.system(.caption))
                        .foregroundStyle(Self.tint(for: notice.kind))
                    Text(notice.text)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                }
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, Spacing.base)
                .frame(maxWidth: 420)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, Spacing.base)
                .transition(.materialize(from: .top))
                // Keyed on the notice's own token, so a second one while the
                // first is up restarts the clock rather than inheriting it.
                .task(id: notice.id) {
                    try? await Task.sleep(for: Self.dwell)
                    guard !Task.isCancelled else { return }
                    dismiss()
                }
            }
        }
        .animation(motion.panel, value: notice)
        .allowsHitTesting(false)
    }

    private static func symbol(for kind: ActionNotice.Kind) -> String {
        switch kind {
        case .failure: "exclamationmark.triangle.fill"
        case .scheduling: "clock.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    private static func tint(for kind: ActionNotice.Kind) -> AnyShapeStyle {
        switch kind {
        case .failure: AnyShapeStyle(Palette.destructive)
        case .scheduling: AnyShapeStyle(Ink.secondary)
        case .success: AnyShapeStyle(Palette.affirmative)
        }
    }
}

/// A quiet strip for the states that are not "fine".
///
/// It appears over the workspace rather than replacing it, and it says what is
/// happening rather than only that something is — "Reconnecting" with no reason
/// is the message that makes people quit and relaunch.
private struct ConnectionBanner: View {
    var state: AppModel.ConnectionState

    @Environment(\.motion) private var motion

    var body: some View {
        Group {
            if let description {
                HStack(spacing: Spacing.base) {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(isWorking ? 1 : 0)
                    Text(description)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(Ink.primary)
                }
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, Spacing.base)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, Spacing.base)
                .transition(.materialize(from: .top))
            }
        }
        .animation(motion.panel, value: description)
        .allowsHitTesting(false)
    }

    private var description: String? {
        switch state {
        case .reconnecting: "Reconnecting…"
        case .failed(let reason): reason
        case .ready, .connecting, .signedOut: nil
        }
    }

    private var isWorking: Bool {
        if case .reconnecting = state { return true }
        return false
    }
}
