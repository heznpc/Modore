import SwiftUI

/// Native controls use the system material on current macOS and remain usable on macOS 13.
extension View {
    /// A table beneath a fixed summary must not blur that summary as a scroll edge.
    @ViewBuilder func modoreStaticScrollEdges() -> some View {
        if #available(macOS 26.0, *) { self.scrollEdgeEffectHidden() }
        else { self }
    }

    @ViewBuilder func modoreGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) }
            else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) }
            else { self.buttonStyle(.bordered) }
        }
    }

    func modoreInspector<Detail: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Detail) -> some View {
        HSplitView {
            self.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            if isPresented.wrappedValue {
                content()
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
                    .background(.background)
            }
        }
    }
}

struct ModoreGlassGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12, content: content)
        } else { content() }
    }
}

struct ModoreBuildInfo: View {
    @Environment(\.dismiss) private var dismiss
    private func value(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "—" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Modore", systemImage: "macwindow").font(.title2.weight(.semibold))
            LabeledContent(L10n.text("버전"), value: value("CFBundleShortVersionString"))
            LabeledContent(L10n.text("빌드 시각"), value: value("ModoreBuildDate"))
            LabeledContent(L10n.text("소스 식별값"), value: value("ModoreSourceDigest")).font(.system(.caption, design: .monospaced))
            Text(Bundle.main.bundleURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack { Spacer(); Button(L10n.text("확인")) { dismiss() }.modoreGlassButton(prominent: true).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 500)
    }
}
