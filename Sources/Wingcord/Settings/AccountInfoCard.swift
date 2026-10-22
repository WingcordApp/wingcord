import SwiftUI
import WingcordCore

/// Username, e-mail and phone — the three lines that identify the account.
///
/// **Each secret is masked until it is asked for, and it goes back.** An e-mail
/// address and a phone number are exactly the two things somebody standing
/// behind this reader can read off a settings window, and a client that printed
/// them for the life of the pane would be handing them over every time the page
/// is opened for some other reason. Revealed on a click, and the same control
/// puts it back — Discord's does the same thing and calls it Reveal.
///
/// **The domain and the last four digits stay visible**, which is what makes
/// masking useful rather than merely private: the reader has to be able to tell
/// *which* account this is, and `•••@gmail.com` answers that where a row of dots
/// does not.
struct AccountInfoCard: View {
    var handle: String
    var details: AccountDetails?

    /// Which secrets are uncovered right now.
    ///
    /// **`@State` here and nowhere else.** It is the reader's own glance at
    /// their own screen — closing the window, switching panes or coming back
    /// later covers them again, which is what a secret revealed by a click
    /// should do. Putting it on the store would keep an address on screen
    /// across a whole session.
    @State private var revealed: Set<Field> = []

    private enum Field: Hashable { case email, phone }

    var body: some View {
        SettingsCard {
            SettingsValueRow(
                title: "Username",
                value: handle,
                help: "How people add you. It is not a secret and is never covered."
            )
            CardDivider()
            secret(
                .email,
                title: "Email",
                plain: details?.email,
                masked: details?.maskedEmail,
                absent: "None"
            )
            CardDivider()
            secret(
                .phone,
                title: "Phone",
                plain: details?.phone,
                masked: details?.maskedPhone,
                absent: "Not added"
            )
        }
        if let details, details.email != nil, !details.isEmailVerified {
            SettingsFootnote(
                "This address has not been confirmed. Discord sends the link; "
                    + "Wingcord never sees it.",
                symbolName: "exclamationmark.triangle"
            )
        }
    }

    @ViewBuilder
    private func secret(
        _ field: Field,
        title: String,
        plain: String?,
        masked: String?,
        absent: String
    ) -> some View {
        // **Nothing to reveal is a row, not a control.** An account with no
        // phone number gets "Not added" and no Reveal, rather than a button
        // that uncovers an empty string — §5.5.
        //
        // Streamer Mode withholds both whole, and takes Reveal away with them:
        // a button that prints an address onto a stream is the one thing the
        // mode exists to stop.
        if let plain, StreamerMode.shared.hidesPersonalInformation {
            SettingsValueRow(
                title: title,
                value: field == .email ? StreamerModeMask.email(plain) : StreamerModeMask.phone(plain),
                help: "Hidden while Streamer Mode is on."
            )
        } else if let plain, let masked {
            let isShown = revealed.contains(field)
            SettingsControlRow(title) {
                HStack(spacing: Spacing.snug) {
                    Text(isShown ? plain : masked)
                        .font(SettingsType.rowLabel)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // **A monospaced digit run, so the row does not jump.**
                        // Dots and digits are different widths in the body face,
                        // and the label beside them would slide on every reveal.
                        .monospacedDigit()
                    Button(isShown ? "Hide" : "Reveal") {
                        if isShown { revealed.remove(field) } else { revealed.insert(field) }
                    }
                    .buttonStyle(.link)
                    .font(SettingsType.rowLabel)
                }
            }
            .accessibilityElement(children: .combine)
            // Spoken as covered unless it is uncovered: VoiceOver reading an
            // address aloud in a room is the same exposure the mask exists to
            // prevent.
            .accessibilityValue(Text(isShown ? plain : "hidden"))
        } else {
            SettingsValueRow(title: title, value: details == nil ? "—" : absent)
        }
    }
}

/// Password, two-factor and where the account is signed in.
///
/// **It reports and does not change.** Every write on this surface — setting a
/// password, enrolling a second factor, signing a session out — needs the
/// account's current password and, on some accounts, a captcha, and not one of
/// them has been watched on the wire in this tree. Shipping a guess into
/// somebody's security settings is the one place a wrong field name is not a
/// cheap mistake, so the page says what is true and sends the reader somewhere
/// that can make the change.
struct AccountSecurityCard: View {
    var details: AccountDetails?

    var body: some View {
        SettingsCard {
            SettingsValueRow(
                title: "Two-factor authentication",
                value: value { $0.hasMFA ? "On" : "Off" },
                help: details?.hasMFA == true
                    ? "A code from your authenticator app is required to sign in."
                    : "Without it, your password is the only thing between somebody "
                        + "and your account."
            )
            CardDivider()
            SettingsActionRow(
                "Password and two-factor",
                help: "Changing either needs your current password, and Wingcord "
                    + "does not ask for it. Discord's own settings do.",
                actionTitle: "Open"
            ) {
                guard let url = URL(string: "https://discord.com/channels/@me") else { return }
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// The value, or a dash while the answer has not arrived.
    ///
    /// **A dash rather than "Off".** "Two-factor: Off" for an account that has
    /// it on is a lie told by a loading state, and it is the reassuring
    /// direction that is dangerous here.
    private func value(_ body: (AccountDetails) -> String) -> String {
        details.map(body) ?? "—"
    }
}

/// Everywhere the account is signed in.
struct AuthSessionsCard: View {
    var sessions: [AuthSession]?

    var body: some View {
        SettingsCard {
            if let sessions {
                if sessions.isEmpty {
                    SettingsValueRow(
                        title: "Other devices",
                        value: "None",
                        help: "This Mac is the only place this account is signed in."
                    )
                } else {
                    CardHeaderRow(
                        title: "Devices",
                        help: "\(sessions.count) "
                            + (sessions.count == 1 ? "session" : "sessions")
                    )
                    ForEach(sessions) { session in
                        CardDivider()
                        SettingsNavigationRow(
                            title: session.title.isEmpty ? "Unknown device" : session.title,
                            subtitle: subtitle(for: session),
                            symbolName: session.symbolName,
                            tint: Color(hex: 0x5E5CE6),
                            action: {}
                        )
                        .allowsHitTesting(false)
                    }
                }
            } else {
                // **Absent is not empty.** A refused request must not read as
                // "you are signed in nowhere", which on a security page is the
                // wrong direction to be wrong in.
                SettingsValueRow(
                    title: "Devices",
                    value: "—",
                    help: "Wingcord could not read this. It is not a claim that "
                        + "there are none."
                )
            }
        }
        SettingsFootnote(
            "Signing a session out needs your password, which Wingcord does not ask "
                + "for. This list is what the account says, not something it can change.",
            symbolName: "lock"
        )
    }

    private func subtitle(for session: AuthSession) -> String {
        var parts: [String] = []
        if let location = session.location, !location.isEmpty { parts.append(location) }
        if let used = session.lastUsed {
            parts.append(
                used.formatted(.relative(presentation: .named))
            )
        }
        return parts.isEmpty ? "No details" : parts.joined(separator: " · ")
    }
}
