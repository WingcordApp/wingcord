import Foundation
import WingcordCore
import WingcordNet

// MARK: - Topics
//
// The fetches behind `AppModel+Topics`. Which to make, and when, is the store's
// `TopicFetchPolicy`; this only makes them and lands the answers.

extension SessionController {

    func loadTopics(in channelID: ChannelID, _ request: TopicRequest) {
        Task { [weak self] in
            guard let self else { return }
            switch request {
            case .list(let page):
                do {
                    let topics = try await rest.conversationTopics(in: channelID, page)
                    Self.trace("topics \(channelID) \(page): \(topics.count)")
                    model.applyTopics(topics, for: page, in: channelID)
                } catch {
                    Self.trace("topics \(channelID) \(page) FAILED: \(Self.describe(error))")
                    model.failTopics(in: channelID, refused: !Self.isWorthRetrying(error))
                }
            case .preview(let topicID), .whole(let topicID):
                let whole = request == .whole(topicID)
                defer { model.topicFetchesInFlight.remove(topicID) }
                do {
                    let page = try await rest.conversationTopicMessages(
                        in: channelID,
                        topic: topicID,
                        // Discord's preview is four messages (module `247933`).
                        previewLimit: whole ? nil : 4
                    )
                    absorb(page)
                    model.storeTopicMessages(page.messages, for: topicID, whole: whole)
                    // The rows draw role colours and faces, and a topic is
                    // mostly people the roster has never listed.
                    resolveMessageMembers(in: page.messages, channelID: channelID)
                } catch {
                    Self.trace("topic \(topicID) messages FAILED: \(Self.describe(error))")
                }
            }
        }
    }
}
