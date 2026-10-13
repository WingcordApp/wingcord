import SwiftUI
import WingcordCore

// MARK: - The channel as the window's title
//
// The HIG: "Provide a useful title for each window." The channel's name is the
// window title, its topic (or a thread's parent) is the subtitle, and the
// channel's own acts are in the title's menu — where the bar used to carry a
// custom pill that opened the topic as a popover.

extension ChannelChrome {
    /// The window's subtitle: a thread's parent, or the channel's topic on one
    /// line.
    ///
    /// **Plain words.** A topic carries mention and custom-emoji markup, which a
    /// title would draw as raw angle-bracketed tokens; it is dropped here, and
    /// the topic sheet draws the whole thing properly.
    var titleSubtitle: String {
        if let parent { return parent.name }
        guard let topic, !topic.isEmpty else { return "" }
        let plain = topic.replacingOccurrences(
            of: #"<a?:[A-Za-z0-9_~]+:\d+>|<[@#&!/][^>]*>"#,
            with: "",
            options: .regularExpression
        )
        let firstLine = plain.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.trimmingCharacters(in: .whitespaces)
    }
}

/// The menu under the window's title: the channel's own acts.
struct ChannelTitleMenu: View {
    var chrome: ChannelChrome
    var model: AppModel

    var body: some View {
        if chrome.topic?.isEmpty == false {
            Button("Show Details") { AppShortcut.channelTopic.perform(in: model) }
        }
        if let parent = chrome.parent {
            Button("Go to \(parent.name)") { model.selectChannel(parent.channelID) }
        }
        if chrome.channelID != nil {
            Divider()
            Button(AppShortcut.copyChannelLink.menuTitle) { AppShortcut.copyChannelLink.perform(in: model) }
            Button("Mark Channel Read") {
                if let channelID = chrome.channelID { model.markRead(channelID) }
            }
        }
    }
}

/// The channel's topic, drawn whole — Channel › Show Details and the title
/// menu's first item.
///
/// **A sheet, because a menu item cannot anchor a popover**: the topic used to
/// hang off the channel pill, and the pill is now the window's own title.
struct ChannelTopicSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            if let channelID = model.openTopicChannelID,
               let channel = model.channelIndex[channelID],
               let topic = channel.topic, !topic.isEmpty {
                ChannelTopicPane(
                    name: model.displayName(of: channel),
                    symbolName: channel.kind.symbolName,
                    topic: topic,
                    mentions: model.mentionContext(),
                    openLink: { model.openLink($0) },
                    openEmoji: { model.openExpressionInfo(.emoji($0), anchor: .zero) }
                )
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(Spacing.group)
        .frame(width: 460)
    }
}
