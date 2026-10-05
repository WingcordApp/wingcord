import Foundation
import WingcordCore
import WingcordNet

// MARK: - Applying to join
//
// Discord's `fetchVerificationForm` and `submitVerificationForm` (`408213`),
// behind the application form. The form asks `with_guild` when the reader is
// outside the server, and a submit answers with the join request.

extension SessionController {

    /// The server's form, as Discord asks for it.
    func joinApplicationForm(_ guildID: GuildID, inviteCode: String?) async throws -> MemberVerification {
        try await rest.memberVerification(
            of: guildID,
            inviteCode: inviteCode,
            withGuild: model.guilds[guildID] == nil
        )
    }

    /// Sends the application, and returns what to say if it did not land.
    ///
    /// **A pending request is the success.** It is filed as the reader's own
    /// request — what the rail's folder, the card's footer and the profile
    /// read — the way Discord files the `PUT`'s answer
    /// (`USER_GUILD_JOIN_REQUEST_UPDATE`). An approval clears a member's
    /// pending flag the way the rules gate's does.
    func submitJoinApplication(_ application: JoinApplication) async -> String? {
        let guildID = application.form.guildID
        do {
            switch try await rest.submitJoinApplication(application) {
            // **Not filed here.** An approval's request is the socket's to
            // describe: whether it has been seen decides Discord's "You are now
            // a member of", and an answer read as an outcome cannot say.
            case .approved:
                if let userID = model.currentUserID, model.members[guildID]?[userID] != nil {
                    model.members[guildID]?[userID]?.isPending = false
                    model.permissionGate.invalidate()
                    model.memberRevision &+= 1
                }
                return nil
            case .pending, .unknown:
                model.fileOwnJoinRequest(OwnJoinRequest(guildID: guildID, status: .submitted))
                announceSubmittedApplication(application)
                return nil
            case .rejected(let reason):
                model.fileOwnJoinRequest(
                    OwnJoinRequest(guildID: guildID, status: .rejected, rejectionReason: reason)
                )
                return "Your application has been rejected."
            }
        } catch {
            Self.trace("application \(guildID) failed: \(Self.describe(error))")
            return Self.applicationFailure(error)
        }
    }

    /// Says the application went in — Discord's coachmark (`0YV0YE` over
    /// `0UQVDL`), which it raises only for a form that asked questions and
    /// hangs on the Pending Applications folder.
    ///
    /// **The folder holds only servers the reader is not in**, so a pending
    /// member's application has nowhere for the coachmark to point; there the
    /// same two sentences arrive as a notice instead.
    private func announceSubmittedApplication(_ application: JoinApplication) {
        guard application.form.asksQuestions else { return }
        if model.guilds[application.form.guildID] == nil {
            model.isApplicationCoachmarkQueued = true
        } else {
            model.reportSuccess("Your application is pending! The server admin will get back to you soon.")
        }
    }

    /// Sends the confirmation e-mail again, for an application form whose
    /// server asks for one. Discord swallows a failure here; this says so in
    /// the trace and leaves the button as it was.
    func resendVerificationEmail() async -> Bool {
        do {
            try await rest.resendVerificationEmail()
            return true
        } catch {
            Self.trace("verify resend failed: \(Self.describe(error))")
            return false
        }
    }

    /// Discord's words for a refused application (`408213` and the modal's
    /// own catch): the form changed under the reader, too many applications,
    /// no permission, or the server's own sentence.
    static func applicationFailure(_ error: any Error) -> String {
        switch error as? DiscordREST.Failure {
        case .api(429, _, _):
            "You've been sending too many Guild applications."
        // `errors.version` or `errors.form_fields` — the form was edited after
        // it was fetched, which is what a stale version answers with.
        case .api(_, _, let message?) where message.contains("version:") || message.contains("form_fields"):
            "This server's requirements have changed. Please close this and try again."
        case .api(_, _, let message?) where !message.isEmpty:
            message
        case .forbidden:
            "You don't have permission to join this server"
        default:
            "Oops, something went wrong..."
        }
    }
}
