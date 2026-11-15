import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Vencord's SilentTyping (decisions 16–19): on, a keystroke reports nothing;
/// the chat input's menu carries the plugin's checkbox, and only there.
@Suite("Silent Typing", .serialized)
@MainActor
struct SilentTypingTests {

    private let channel = ChannelID(rawValue: 4242)

    /// Runs `body` with the plugin's settings as given, putting them back after.
    private func with(plugin: Bool, isOn: Bool, menu: Bool = true, _ body: () -> Void) async {
        await withAppSettings(\.silentTyping, \.silentTypingIsOn, \.silentTypingInContextMenu) { settings in
            settings.silentTyping = plugin
            settings.silentTypingIsOn = isOn
            settings.silentTypingInContextMenu = menu
            body()
        }
    }

    @Test("Hidden, a keystroke sends no typing request")
    func sendsNothing() async {
        await with(plugin: true, isOn: true) {
            let model = AppModel()
            model.sessionController.reportTyping(in: channel)
            #expect(model.sessionController.lastTypingSent[channel] == nil)
        }
    }

    @Test("Hiding needs the plugin and its functionality both on")
    func hides() async {
        await with(plugin: true, isOn: true) { #expect(AppSettings.shared.hidesTyping) }
        await with(plugin: true, isOn: false) { #expect(!AppSettings.shared.hidesTyping) }
        await with(plugin: false, isOn: true) { #expect(!AppSettings.shared.hidesTyping) }
    }

    private func menuTitles(isChatInput: Bool) -> [String: NSControl.StateValue] {
        let view = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        view.isChatInput = isChatInput
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ), let menu = view.menu(for: event) else { return [:] }
        return Dictionary(menu.items.map { ($0.title, $0.state) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("The chat input's menu ends with the plugin's checkbox, ticked while typing is hidden")
    func contextMenu() async {
        await with(plugin: true, isOn: true) {
            #expect(menuTitles(isChatInput: true)["Enable Silent Typing"] == .on)
            #expect(menuTitles(isChatInput: false)["Enable Silent Typing"] == nil)
        }
        await with(plugin: true, isOn: false) {
            #expect(menuTitles(isChatInput: true)["Enable Silent Typing"] == .off)
        }
        await with(plugin: true, isOn: true, menu: false) {
            #expect(menuTitles(isChatInput: true)["Enable Silent Typing"] == nil)
        }
        await with(plugin: false, isOn: true) {
            #expect(menuTitles(isChatInput: true)["Enable Silent Typing"] == nil)
        }
    }
}
