import SwiftUI
import WingcordCore

/// The activity the reader is in, on the call's stage: the frame itself, with a
/// thin bar over its top edge on hover (its name, Pop Out, Leave).
///
/// **Drawn only while the call is its host** (`AppModel.activityHost`): the web
/// view is one view, so while it's popped out or in the picture in picture this
/// says where it is and offers it back.
struct CallActivityStage: View {
    var activity: CallActivityPresentation

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Palette.surfaceRaised)
            if model.activityHost == .call, let runtime = model.activityRuntime {
                ActivityWebView(runtime: runtime)
                    .opacity(model.runningActivity?.isReady == true ? 1 : 0)
                if model.runningActivity?.isReady != true {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                elsewhere
            }
            ActivityControlBar(name: activity.name, iconURL: activity.iconURL, showsPopOut: true)
                .padding(Spacing.base)
                .opacity(isHovering ? 1 : 0)
        }
        .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
    }

    private var elsewhere: some View {
        VStack(spacing: Spacing.snug) {
            Image(systemName: model.isActivityPoppedOut ? "macwindow.on.rectangle" : "pip")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Ink.secondary)
            Text(model.isActivityPoppedOut ? "\(activity.name) is in its own window" : "\(activity.name) is in picture in picture")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Button("Bring It Back") { model.popInActivity() }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
