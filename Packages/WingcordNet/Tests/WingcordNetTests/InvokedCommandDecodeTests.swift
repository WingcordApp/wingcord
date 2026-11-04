import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// `GET /channels/{c}/messages/{m}/interaction-data` — the line Discord's popout
/// draws over a "used" chip (`Y` in `217424`).
@Suite("Invoked command decode")
struct InvokedCommandDecodeTests {
    private func decode(_ json: String) throws -> InvokedCommand {
        try #require(try InvokedCommand.decode(Data(json.utf8)))
    }

    @Test("A command with no options is its name")
    func bare() throws {
        let command = try decode(#"""
        { "id": "1", "type": 1, "name": "count",
          "application_command": { "id": "2", "name": "count", "type": 1, "version": "3" } }
        """#)
        #expect(command.name == "count")
        #expect(command.pieces == [.command("/count")])
    }

    @Test("Typed values come as they were typed, booleans and numbers included")
    func scalars() throws {
        let command = try decode(#"""
        { "name": "meme",
          "application_command": { "name": "meme", "options": [] },
          "options": [
            { "type": 3, "name": "text", "value": "hi" },
            { "type": 4, "name": "count", "value": 3 },
            { "type": 10, "name": "scale", "value": 1.5 },
            { "type": 5, "name": "nsfw", "value": false } ] }
        """#)
        #expect(command.pieces == [
            .command("/meme"),
            .label(" text: "), .value(.text("hi")),
            .label(" count: "), .value(.text("3")),
            .label(" scale: "), .value(.text("1.5")),
            .label(" nsfw: "), .value(.text("false")),
        ])
    }

    @Test("A choice is drawn by its label, a number's as well as a string's")
    func choices() throws {
        let command = try decode(#"""
        { "name": "fwkgenre",
          "application_command": { "name": "fwkgenre", "options": [
            { "type": 4, "name": "genre", "choices": [
                { "name": "Action", "value": 1 }, { "name": "Horror", "value": 2 } ] },
            { "type": 3, "name": "mode", "choices": [
                { "name": "Reversed", "value": "r", "name_localized": "Umgekehrt" } ] } ] },
          "options": [
            { "type": 4, "name": "genre", "value": 2 },
            { "type": 3, "name": "mode", "value": "r" },
            { "type": 3, "name": "other", "value": "free" } ] }
        """#)
        #expect(command.options.map(\.value) == [.text("Horror"), .text("Umgekehrt"), .text("free")])
    }

    @Test("A subcommand reads as words, with its own options under it, once")
    func subcommands() throws {
        let command = try decode(#"""
        { "name": "base64 decode",
          "application_command": { "name": "base64", "options": [
            { "type": 1, "name": "decode", "options": [ { "type": 3, "name": "text" } ] } ] },
          "options": [
            { "type": 1, "name": "decode", "options": [
                { "type": 3, "name": "text", "value": "aGk=" } ] } ] }
        """#)
        #expect(command.pieces == [
            .command("/base64"), .command(" decode"), .label(" text: "), .value(.text("aGk=")),
        ])
    }

    @Test("People, channels, roles and files are ids, kept for the app to name")
    func references() throws {
        let command = try decode(#"""
        { "name": "x", "application_command": { "name": "x" },
          "options": [
            { "type": 6, "name": "who", "value": "11" },
            { "type": 7, "name": "where", "value": "12" },
            { "type": 8, "name": "role", "value": "13" },
            { "type": 9, "name": "any", "value": "14" },
            { "type": 11, "name": "file", "value": "15" },
            { "type": 6, "name": "bad", "value": "not-an-id" } ] }
        """#)
        #expect(command.options.map(\.value) == [
            .user(UserID(rawValue: 11)), .channel(ChannelID(rawValue: 12)), .role(RoleID(rawValue: 13)),
            .mentionable(14), .attachment, .text("not-an-id"),
        ])
    }

    /// A deleted command comes back with no declaration. `name` still has its
    /// subcommands in it and so do the options — "/base64 decode decode" would
    /// be the result of taking it whole.
    @Test("With no declaration, the name is the name's first word")
    func deletedCommand() throws {
        let command = try decode(#"""
        { "name": "base64 decode",
          "options": [ { "type": 1, "name": "decode", "options": [] } ] }
        """#)
        #expect(command.pieces == [.command("/base64"), .command(" decode")])
    }

    @Test("An answer that names no command is nothing, not a blank line")
    func namesNothing() throws {
        #expect(try InvokedCommand.decode(Data(#"{ "id": "1", "type": 3 }"#.utf8)) == nil)
    }
}
