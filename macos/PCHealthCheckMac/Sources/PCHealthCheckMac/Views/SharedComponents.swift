import AppKit
import SwiftUI

struct InspectorSplitLayout<Master: View, Detail: View>: View {
    let minimumInspectorWidth: CGFloat
    let maximumInspectorWidth: CGFloat
    let inspectorFraction: CGFloat
    @ViewBuilder let master: Master
    @ViewBuilder let detail: Detail

    init(
        minimumInspectorWidth: CGFloat = 320,
        maximumInspectorWidth: CGFloat = 440,
        inspectorFraction: CGFloat = 0.36,
        @ViewBuilder master: () -> Master,
        @ViewBuilder detail: () -> Detail
    ) {
        self.minimumInspectorWidth = minimumInspectorWidth
        self.maximumInspectorWidth = maximumInspectorWidth
        self.inspectorFraction = inspectorFraction
        self.master = master()
        self.detail = detail()
    }

    var body: some View {
        GeometryReader { proxy in
            let proposedWidth = proxy.size.width * inspectorFraction
            let inspectorWidth = min(maximumInspectorWidth, max(minimumInspectorWidth, proposedWidth))
            let masterWidth = max(0, proxy.size.width - inspectorWidth - 1)

            HStack(spacing: 0) {
                master
                    .frame(width: masterWidth)
                    .frame(maxHeight: .infinity)
                    .clipped()

                Divider()

                detail
                    .frame(width: inspectorWidth)
                    .frame(maxHeight: .infinity)
                    .clipped()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct InspectorListHeader: View {
    let title: String
    let subtitle: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .textCase(nil)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
            Spacer(minLength: 8)
            if !value.isEmpty {
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textCase(nil)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

struct InspectorTextSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ModernEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
