import SwiftUI
import WingcordCore

/// Discord's ✓ OFFICIAL tag on its own system account's row.
///
/// **The one tag Discord's DM list draws** (Alex, 2026-11-18: "add the
/// OFFICIAL tag or APP tag depending on the app like on discord"). Its row's
/// decorators are `isSystemDM() ? BotTag(SYSTEM_DM, verified) : null`, so an
/// app's conversation wears no APP tag there, and neither does this list's.
/// A server tag is a different thing and keeps its own chip
/// (`SidebarTagChip`), in whose measure this one is set.
struct SidebarOfficialTag: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .heavy))
            Text("OFFICIAL")
                .font(.system(.caption2, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .frame(height: 15)
        // Discord's blurple, as its tag and the Beta pill are.
        .background(Color(hex: 0x5865F2), in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AuthorTag.official.spokenLabel))
    }
}
