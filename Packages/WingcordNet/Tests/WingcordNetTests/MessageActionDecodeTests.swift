import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The three fields a message action added to the message payload, and the
/// report tree the flow is built from.
@Suite("Message action decoding")
struct MessageActionDecodeTests {

    private func message(_ json: String) throws -> Message {
        try JSONDecoder().decode(MessageDTO.self, from: Data(json.utf8)).domain
    }

    // MARK: The reply header

    @Test("A reply carries enough of its target to draw the header")
    func replyReference() throws {
        let decoded = try message(
            """
            {
              "id": "2", "channel_id": "9", "type": 19,
              "content": "hey",
              "author": {"id": "5", "username": "alex"},
              "message_reference": {"type": 0, "message_id": "1", "channel_id": "9"},
              "referenced_message": {
                "id": "1", "channel_id": "9",
                "content": "hey man",
                "author": {"id": "7", "username": "robin_harper1", "global_name": "robinresting"}
              }
            }
            """
        )
        let reference = try #require(decoded.reference)
        #expect(reference.messageID == MessageID(rawValue: 1))
        #expect(reference.authorID == UserID(rawValue: 7))
        #expect(reference.excerpt == "hey man")
        #expect(!reference.isUnavailable)
        #expect(!reference.hasAttachment)
    }

    @Test("A target sent as null is deleted")
    func deletedTarget() throws {
        let decoded = try message(
            """
            {
              "id": "2", "channel_id": "9", "type": 19, "content": "hey",
              "author": {"id": "5", "username": "alex"},
              "message_reference": {"message_id": "1", "channel_id": "9"},
              "referenced_message": null
            }
            """
        )
        let reference = try #require(decoded.reference)
        #expect(reference.isUnavailable)
        #expect(reference.isDeleted)
        #expect(reference.excerpt.isEmpty)
    }

    @Test("A target the payload left out is unknown, not deleted")
    func unloadedTarget() throws {
        // Discord's contract: an absent `referenced_message` is a server that
        // did not look the message up. Read as deleted, every unfetched quote
        // said "Original message was deleted" about a message still there.
        let decoded = try message(
            """
            {
              "id": "2", "channel_id": "9", "type": 19, "content": "hey",
              "author": {"id": "5", "username": "alex"},
              "message_reference": {"message_id": "1", "channel_id": "9"}
            }
            """
        )
        let reference = try #require(decoded.reference)
        #expect(reference.isUnavailable)
        #expect(!reference.isDeleted)
        #expect(reference.messageID == MessageID(rawValue: 1))
    }

    @Test("A quoted picture with no words is still quotable")
    func attachmentOnlyTarget() throws {
        let decoded = try message(
            """
            {
              "id": "2", "channel_id": "9", "type": 19, "content": "look",
              "author": {"id": "5", "username": "alex"},
              "message_reference": {"message_id": "1"},
              "referenced_message": {
                "id": "1", "channel_id": "9", "content": "",
                "author": {"id": "7", "username": "rowan"},
                "attachments": [{"id": "3", "filename": "a.png", "url": "u", "proxy_url": "p"}]
              }
            }
            """
        )
        let reference = try #require(decoded.reference)
        #expect(reference.hasAttachment)
        #expect(reference.excerpt.isEmpty)
    }

    // MARK: Forwards

    @Test("A forward is read from its snapshot, and is not a reply")
    func forwardSnapshot() throws {
        let decoded = try message(
            """
            {
              "id": "2", "channel_id": "9", "content": "",
              "author": {"id": "5", "username": "alex"},
              "message_reference": {"type": 1, "message_id": "1", "channel_id": "8"},
              "message_snapshots": [
                {"message": {"content": "the original", "attachments": [], "embeds": []}}
              ]
            }
            """
        )
        // A forward also carries a `message_reference`; reading one as a reply
        // would draw a quote header over a target the reader cannot reach.
        #expect(decoded.reference == nil)
        let forwarded = try #require(decoded.forwarded)
        #expect(forwarded.content == "the original")
        #expect(forwarded.channelID == ChannelID(rawValue: 8))
        #expect(forwarded.attachmentCount == 0)
    }

    // MARK: Pins

    @Test("A message says whether it is pinned, and defaults to not")
    func pinnedFlag() throws {
        let pinned = try message(
            """
            {"id": "1", "channel_id": "9", "content": "x", "pinned": true,
             "author": {"id": "5", "username": "alex"}}
            """
        )
        #expect(pinned.isPinned)
        let plain = try message(
            """
            {"id": "1", "channel_id": "9", "content": "x",
             "author": {"id": "5", "username": "alex"}}
            """
        )
        #expect(!plain.isPinned)
    }

    @Test("The pins route wraps each message and forces the flag")
    func pinnedPage() throws {
        let page = try JSONDecoder().decode(
            PinnedPageDTO.self,
            data: """
            {"items": [
              {"pinned_at": "2026-01-01T00:00:00+00:00",
               "message": {"id": "1", "channel_id": "9", "content": "kept", "pinned": false,
                           "author": {"id": "5", "username": "alex"}}}
            ], "has_more": false}
            """
        )
        #expect(page.items?.count == 1)
        // The route describes the message and sometimes answers `pinned: false`
        // for one on the pin list. A message on that list is pinned.
        #expect(page.items?.first?.message?.domain.isPinned == false)
    }

    // MARK: The report tree

    @Test("The report menu decodes its heterogeneous children and typed elements")
    func reportMenu() throws {
        let menu = try JSONDecoder().decode(
            ReportMenuDTO.self,
            data: """
            {
              "name": "message", "variant": "8", "version": "1.0", "root_node_id": 7,
              "nodes": {
                "7": {
                  "id": 7, "header": "Report Message", "subheader": "Pick one.",
                  "button": {"type": "cancel", "target": null},
                  "elements": [
                    {"name": "message_preview", "type": "message_preview", "data": null},
                    {"name": "external_link", "type": "external_link",
                     "data": {"link_text": "Report illegal content", "url": "https://discord.com/report"}}
                  ],
                  "children": [["Spam", 98], ["Something else", 80]],
                  "is_auto_submit": false
                },
                "79": {
                  "id": 79, "header": "What was posted?",
                  "button": {"type": "next", "target": 17},
                  "elements": [
                    {"name": "pii_select", "type": "checkbox",
                     "data": [["face_pic", "Face pic"], ["ip_address", "IP address"]]}
                  ],
                  "children": []
                },
                "97": {
                  "id": 97, "header": "Thank you",
                  "button": {"type": "done", "target": null},
                  "elements": [
                    {"name": "block_users", "type": "block_users", "data": null},
                    {"name": "mute_users", "type": "mute_users", "data": null}
                  ],
                  "report_type": "sub_dont_like", "children": [], "is_auto_submit": true
                }
              }
            }
            """
        ).domain

        #expect(menu.rootNodeID == 7)
        #expect(menu.variant == "8")

        let root = try #require(menu.root)
        #expect(root.children.map(\.label) == ["Spam", "Something else"])
        #expect(root.children.map(\.nodeID) == [98, 80])
        #expect(root.button == .cancel)
        #expect(root.elements.contains(.subjectPreview))
        #expect(
            root.elements.contains(
                .externalLink(text: "Report illegal content", url: URL(string: "https://discord.com/report")!)
            )
        )

        let pii = try #require(menu[79])
        #expect(pii.button == .next(17))
        guard case .checkbox(let name, let options)? = pii.elements.first else {
            Issue.record("expected a checkbox")
            return
        }
        #expect(name == "pii_select")
        #expect(options.map(\.value) == ["face_pic", "ip_address"])

        let thanks = try #require(menu[97])
        #expect(thanks.isAutoSubmit)
        #expect(thanks.submits)
        // Block is honoured; mute is a route this client does not have, so it
        // draws nothing rather than becoming a control that answers nothing.
        #expect(thanks.elements.contains(.followUp(.block)))
        #expect(thanks.elements.contains(.decoration))
    }

    @Test("A link that is not https is dropped rather than opened")
    func reportLinksAreCheckedForScheme() throws {
        let menu = try JSONDecoder().decode(
            ReportMenuDTO.self,
            data: """
            {"name": "message", "root_node_id": 1, "nodes": {"1": {"id": 1, "header": "x",
              "elements": [{"name": "l", "type": "external_link",
                            "data": {"link_text": "go", "url": "javascript:alert(1)"}}]}}}
            """
        ).domain
        #expect(menu[1]?.elements == [.decoration])
    }
}

private extension JSONDecoder {
    func decode<T: Decodable>(_ type: T.Type, data: String) throws -> T {
        try decode(type, from: Data(data.utf8))
    }
}
