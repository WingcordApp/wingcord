import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Forms an application raises — `INTERACTION_MODAL_CREATE` in, `type: 5`
/// back out — on the fields Discord's own client reads and writes.
@Suite("Interaction modals")
struct InteractionModalTests {

    /// A classic form (rows of text inputs) and the newer one (a label around
    /// a select, text, a checkbox) in one payload.
    private static let frame = #"""
    {"op":0,"s":12,"t":"INTERACTION_MODAL_CREATE","d":{
      "id":"1300000000000000001","channel_id":"200","custom_id":"report_form","title":"Report a bug",
      "nonce":"1300000000000000002",
      "application":{"id":"300","name":"Sapphire","icon":"abc"},
      "components":[
        {"type":1,"components":[{"type":4,"custom_id":"summary","style":1,"label":"Summary",
          "required":true,"min_length":3,"max_length":60,"placeholder":"One line"}]},
        {"type":1,"components":[{"type":4,"custom_id":"details","style":2,"label":"Details",
          "value":"It broke when"}]},
        {"type":10,"content":"**Thanks** for helping."},
        {"type":18,"label":"Severity","description":"How bad is it?","component":
          {"type":3,"custom_id":"severity","options":[
            {"label":"Low","value":"low"},{"label":"High","value":"high","default":true}]}},
        {"type":18,"label":"Contact me","component":{"type":23,"custom_id":"contact","default":false}},
        {"type":18,"label":"Logs","component":{"type":19,"custom_id":"logs"}}
      ]}}
    """#

    private func modal() throws -> InteractionModal {
        let decoded = try JSONDecoder().decode(GatewayFrame.self, from: Data(Self.frame.utf8))
        guard case .interactionModalCreated(let modal)? = GatewayUpdate(decoded.payload) else {
            Issue.record("the form should have been read")
            throw CancellationError()
        }
        return modal
    }

    @Test("A form is read field by field, as Discord's client reads it")
    func decode() throws {
        let modal = try modal()
        #expect(modal.title == "Report a bug")
        #expect(modal.applicationName == "Sapphire")
        #expect(modal.nonce == "1300000000000000002")
        #expect(modal.inputs.count == 5)
        guard case .row(let first) = modal.fields[0], case .textInput(let summary) = first.first else {
            Issue.record("the first row should hold the summary input")
            return
        }
        #expect(summary.isRequired && summary.minLength == 3 && summary.maxLength == 60 && !summary.isParagraph)
        #expect(modal.initialAnswers["details"] == .text("It broke when"))
        #expect(modal.initialAnswers["severity"] == .values(["high"]))
        #expect(modal.initialAnswers["contact"] == .flag(false))
    }

    @Test("A required input empty or too short keeps the form from being sent")
    func completeness() throws {
        let modal = try modal()
        var answers = modal.initialAnswers
        #expect(!modal.isComplete(answers))
        answers["summary"] = .text("ab")
        #expect(!modal.isComplete(answers))
        answers["summary"] = .text("Crash on paste")
        #expect(modal.isComplete(answers))
    }

    /// **Discord's walk, case by case**: a row's components, a label's one
    /// component, text as its type alone, an input's `value`, a select's
    /// `values`, a checkbox's boolean, and a field this client cannot fill
    /// going back with its values null.
    @Test("A form goes back as Discord's client sends it")
    func submission() throws {
        let modal = try modal()
        var answers = modal.initialAnswers
        answers["summary"] = .text("Crash on paste")
        answers["contact"] = .flag(true)
        let body = ModalSubmission(modal: modal, answers: answers, guildID: nil, sessionID: "s", nonce: "n")
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        #expect(object["type"] as? Int == 5)
        #expect(object["application_id"] as? String == "300")
        #expect(object["guild_id"] is NSNull)
        let data = try #require(object["data"] as? [String: Any])
        #expect(data["id"] as? String == "1300000000000000001")
        #expect(data["custom_id"] as? String == "report_form")
        let components = try #require(data["components"] as? [[String: Any]])
        #expect(components.count == 6)
        let row = try #require((components[0]["components"] as? [[String: Any]])?.first)
        #expect(row["type"] as? Int == 4 && row["custom_id"] as? String == "summary" && row["value"] as? String == "Crash on paste")
        #expect(components[2]["type"] as? Int == 10 && components[2].count == 1)
        let severity = try #require(components[3]["component"] as? [String: Any])
        #expect(components[3]["type"] as? Int == 18)
        #expect(severity["type"] as? Int == 3 && severity["values"] as? [String] == ["high"])
        let contact = try #require(components[4]["component"] as? [String: Any])
        #expect(contact["type"] as? Int == 23 && contact["value"] as? Bool == true)
        let logs = try #require(components[5]["component"] as? [String: Any])
        #expect(logs["type"] as? Int == 19 && logs["values"] is NSNull)
    }
}
