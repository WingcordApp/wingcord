import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The per-server Privacy Settings sheet, against the bytes Discord sent.
///
/// **Every fixture is a `PATCH /users/@me/settings-proto/1` body captured
/// 2026-09-22**, from `serveroptions + privacy.har`: the sheet's switches were
/// turned off top to bottom and back on bottom to top, one request each, with
/// the Network tab open. They are base64 exactly as they went on the wire.
///
/// The server being configured is `574217343635554305`; `1040876835899302306`
/// is a second one already restricted before the session began, and it is the
/// reason these are not one-element fixtures — a decoder that read the field as
/// a scalar would pass on a single id.
@Suite("Per-server privacy")
struct GuildPrivacyTests {

    private static let subject = GuildID(rawValue: 574_217_343_635_554_305)
    private static let other = GuildID(rawValue: 1_040_876_835_899_302_306)

    /// Direct Messages switched OFF: the subject joins `restricted_guild_ids`.
    private let dmsOff =
        "Qr0GCgASABoQouG1qvfvcQ4BAES3oQf4B0ICCAFKAggBUgIIAVoCCA5iAggGavgFouG1qvfvcQ4C"
            + "AIRJDAXzBaIQAiOwkYoTCwDEBk50AgSNM5tfFMNUA+Q9w/f1t0kTUADAlF1CvhRJAEBsSj/tEgCA"
            + "QuspARcN4ghQIcMNvwoVAALw4pmcBB4AjgMHRTELbwDEsq9gwxNkEIQ/lxZEEpkAgKT9bCMRCzCE"
            + "+Q/9ww8fQIIIlvJ0DB4AhCb0TqwRZBDC+b3wTBNUEIA+4GFqEyEgRE0WUoMPbgBELoZH6w8yEITd"
            + "VFVkEFqAgjZWe7YNeADCHcwDJBF5QES6fcYPEDwAREthP9kRHwBK2cZKlgqsAASQfICJEkZABGyp"
            + "mMEPbxAE2Sb1DhMqEATErxwNERRAhLyxQhoQHgCEXcyyKBE8UMSVwTB/DhQAwH8VfvwSRxBEBdPV"
            + "wA8gQMSBGlCrD6IARNG67uMQRgACFmZerBEKYAIdFqmqDWUQQKbmJvkReQBEjwBV8xABEAQvf30L"
            + "Dx8QwJKk72QRAAAALEjTowQAAACu3WQGB0YAkkGXiqULMwAMBMBlgQsBAATJKMLlBSAwRNWlVoEQ"
            + "KQDAMFP/RQlwEMTPvmIIEhQQRMcLGUIPcDAEKYmWZBAeAECU7Xy2EAoAApGsxfIKBgBI2KmM/wsf"
            + "UMRFtBUaD1AAAmAYVLYLAQCAKq0meAMKAAiF1S3nCzxAxPoK5cwPADCEusgiRxBHAAQE2lsyDjwA"
            + "DOaT6IwKCgAMHCAqsAtuMMTCG+vCDRQgRMrGJOYPCnDCApbp6gwKAIJ8aGmzBRUwBMDmNxYOCgAE"
            + "zoi0JggKAAQduyhCCwAAQNrJu2EIHjAExsv7cg4KMARA1BdUDj5ARG2rw08ORwAC9ytzUg0AQMAg"
            + "3IwxAQEARFo32TAJMkBCptH68wwLgIKL/SEHDQsARJkJo+wHi1W1xExZchV80Pyt5fpdFd4QAC03"
            + "LTUVHhDEwk7/5BQKAMBu0Pp5E2UAROztKEMTKACAihwESxNbEERRhF2iEFwAgADQdMoRiiBEGZ3e"
            + "3w0KAIKmlOKrCHoIouG1qvfvcQ6SAQCyAQIIAegBAYACAw=="

    /// Direct Messages switched back ON, the last write of the session. Every
    /// list is back to the one server it started with, which is the state the
    /// screenshot taken beside it shows: all four switches on.
    private let dmsOn =
        "QrUGCgASABoIouG1qvfvcQ5CAggBSgIIAVICCAFaAggOYgIIBmr4BaLhtar373EOAgCESQwF8wWi"
            + "EAIjsJGKEwsAxAZOdAIEjTObXxTDVAPkPcP39bdJE1AAwJRdQr4USQBAbEo/7RIAgELrKQEXDTIA"
            + "UiHDDb8KFQAC8OKZnAQeAI4DB0UxC28AxLKvYMMTZBCEP5cWRBKZAICk/WwjEQswhPkP/cMPH0CC"
            + "CJbydAweAIQm9E6sEWQQwvm98EwTVBCAPuBhahMhIERNFlKDD24ARC6GR+sPMhCE3VRVZBBagII2"
            + "Vnu2DXgAwh3MAyQReUBEun3GDxA8AERLYT/ZER8AStnGSpYKrAAEkHyAiRJGQARsqZjBD28QBNkm"
            + "9Q4TKhAExK8cDREUQIS8sUIaEB4AhF3MsigRPFDElcEwfw4UAMB/FX78EkcQRAXT1cAPIEDEgRpQ"
            + "qw+iAETRuu7jEEYAAhZmXqwRCmACHRapqg1lEECm5ib5EXkARI8AVfMQARAEL399Cw8fEMCSpO9k"
            + "EQAAACxI06MEAAAArt1kBgdGAJJBl4qlCzMADATAZYELAQAEySjC5QUgMETVpVaBECkAwDBT/0UJ"
            + "cBDEz75iCBIUEETHCxlCD3AwBCmJlmQQHgBAlO18thAKAAKRrMXyCgYASNipjP8LH1DERbQVGg9Q"
            + "AAJgGFS2CwEAgCqtJngDCgAIhdUt5ws8QMT6CuXMDwAwhLrIIkcQRwAEBNpbMg48AAzmk+iMCgoA"
            + "DBwgKrALbjDEwhvrwg0UIETKxiTmDwpwwgKW6eoMCgCCfGhpswUVMATA5jcWDgoABM6ItCYICgAE"
            + "HbsoQgsAAEDaybthCB4wBMbL+3IOCjAEQNQXVA4+QERtq8NPDkcAAvcrc1INAEDAINyMMQEBAERa"
            + "N9kwCTJAQqbR+vMMC4CCi/0hBw0LAESZCaPsB4tVtcRMWXIVfND8reX6XRXy0hQtNy01FR4QxMJO"
            + "/+QUCgDAbtD6eRNlAETs7ShDEygAgIocBEsTWxBEUYRdohBcAIAA0HTKEYogRBmd3t8NCgCCppTi"
            + "qwh6CKLhtar373EOkgEAsgECCAHoAQGAAgM="

    private func privacy(_ base64: String) -> ActivityPrivacy {
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
        return ActivityPrivacyProto.decode(data).privacy
    }

    // MARK: The polarity

    @Test("A switch is ON exactly when the server is NOT in the list")
    func absenceIsOn() {
        let off = privacy(dmsOff).privacy(in: Self.subject)
        #expect(off.allowsDirectMessages == false)
        // The other three were untouched by that request and stay on.
        #expect(off.filtersMessageRequests)
        #expect(off.sharesActivity)
        #expect(off.allowsActivityJoining)

        let on = privacy(dmsOn).privacy(in: Self.subject)
        #expect(on.allowsDirectMessages)
        #expect(on.filtersMessageRequests)
        #expect(on.sharesActivity)
        #expect(on.allowsActivityJoining)
    }

    @Test("A server nobody has ever configured has every switch on")
    func untouchedServerIsAllOn() {
        let never = GuildID(rawValue: 1)
        let resolved = privacy(dmsOff).privacy(in: never)
        #expect(resolved.allowsDirectMessages)
        #expect(resolved.filtersMessageRequests)
        #expect(resolved.sharesActivity)
        #expect(resolved.allowsActivityJoining)
    }

    // MARK: The four lists are four different fields

    @Test("Field 3 is DMs and field 13 is activity, however alike their names")
    func dmListIsNotTheActivityList() {
        let decoded = privacy(dmsOff)
        #expect(decoded.dmRestrictedGuildIDs == [Self.other, Self.subject])
        // The capture's activity list holds 95 servers and the subject is not
        // one of them: that request was about DMs alone.
        #expect(decoded.activityRestrictedGuildIDs.contains(Self.subject) == false)
        #expect(decoded.activityRestrictedGuildIDs.count == 95)
        #expect(decoded.activityJoiningRestrictedGuildIDs == [Self.other])
    }

    @Test("Every toggle writes its own field and leaves the other three alone")
    func togglesDoNotCollide() {
        // A `privacy` message carrying all four lists, each with a different
        // marker id, so a write that landed on the wrong field is visible as a
        // list that changed when it should not have.
        var raw = ProtobufWriter()
        for (field, id) in [(3, 11), (13, 22), (15, 33), (16, 44)] {
            raw.message(
                field: field, ActivityPrivacyProto.packed([GuildID(rawValue: UInt64(id))])
            )
        }

        for toggle in GuildPrivacyToggle.allCases {
            let written: Set<GuildID> = [GuildID(rawValue: 99)]
            let patch = ActivityPrivacyProto.privacyPatch(
                applying: .guildList(toggle, written), to: raw.data
            )
            let decoded = ActivityPrivacyProto.decode(
                Data(base64Encoded: patch) ?? Data()
            ).privacy
            #expect(decoded.guildIDs(for: toggle) == written)
            for other in GuildPrivacyToggle.allCases where other != toggle {
                #expect(decoded.guildIDs(for: other).count == 1)
                #expect(decoded.guildIDs(for: other) != written)
            }
        }
    }

    @Test("A write preserves every byte it does not understand")
    func unknownFieldsSurvive() {
        // Field 23 is `inappropriate_conversation_warnings`, which this client
        // does not read. A writer that re-serialised the message rather than
        // splicing it would silently delete it — §5.6.
        var raw = ProtobufWriter()
        raw.message(field: 3, ActivityPrivacyProto.packed([Self.other]))
        raw.message(field: 23, ActivityPrivacyProto.boolValue(true))
        let patch = ActivityPrivacyProto.privacyPatch(
            applying: .guildList(.directMessages, [Self.subject]), to: raw.data
        )
        let data = Data(base64Encoded: patch) ?? Data()

        var outer = ProtobufReader(data)
        var inner: Data?
        while let field = outer.next() {
            guard field.number == 8, inner == nil else { continue }
            inner = outer.data(for: field)
        }
        var reader = ProtobufReader(inner ?? Data())
        var sawUnknown = false
        while let field = reader.next() {
            if field.number == 23 { sawUnknown = true }
        }
        #expect(sawUnknown)
    }
}
