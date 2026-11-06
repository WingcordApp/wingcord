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

    var body: some View {
        WindowShell()
            .opacity(model.showsWorkspace ? 1 : 0)
            // Invisible isn't absent: until it's shown, VoiceOver shouldn't find
            // a workspace under the sign-in screen.
            .accessibilityHidden(!model.showsWorkspace)
            .overlay {
                // Under a switch's veil there's nothing to sign in to. A sign-in's
                // veil keeps the sign-in screen's backdrop under it, so the ember
                // runs on until the app arrives (docs/LOGIN-ONBOARDING.md D11).
                if !model.showsWorkspace, model.accountSwitch.map({ $0.kind == .signingIn }) ?? true {
                    Group {
                        // A saved account coming back up at launch: nothing to
                        // sign in to, and no welcome to play under it. Not under a
                        // sign-in's veil, which connects too and keeps the ember.
                        if case .connecting = model.connectionState, model.accountSwitch == nil {
                            SignInConnectingView()
                        } else {
                            SignInScreen()
                        }
                    }
                    .transition(.opacity)
                }
            }
            .modifier(AccountSwitchVeilHost())
            .overlay(alignment: .top) {
                ConnectionBanner(state: model.connectionState)
            }
            .overlay(alignment: .top) {
                ActionNoticeView(notice: model.actionNotice) {
                    model.actionNotice = nil
                }
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
                // Watches for streaming software and covers the windows; no
                // network, so `--demo` runs it too.
                StreamerMode.shared.start()
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

    /// Opens the account used last, as Discord does. The picker's for when that one's
    /// session has died: see `AccountList.accountToResume`.
    func resumeStoredSessionIfAvailable() async {
        guard case .signedOut = connectionState else { return }
        reloadAccounts()
        DiagnosticLog.trace("app", "stored accounts: \(storedAccounts.count)")
        guard let account = AccountList(storedAccounts).accountToResume else { return }
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
    /// transcript while somebody carries on — and the clips call warning's
    /// six, Discord's own, for the one notice that is about the reader.
    private static func dwell(for kind: ActionNotice.Kind) -> Duration {
        kind == .clips ? .seconds(6) : .seconds(4)
    }

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
                    try? await Task.sleep(for: Self.dwell(for: notice.kind))
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
        case .clips: "record.circle"
        }
    }

    private static func tint(for kind: ActionNotice.Kind) -> AnyShapeStyle {
        switch kind {
        case .failure: AnyShapeStyle(Palette.destructive)
        case .scheduling: AnyShapeStyle(Ink.secondary)
        case .success: AnyShapeStyle(Palette.affirmative)
        case .clips: AnyShapeStyle(Palette.destructive)
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
