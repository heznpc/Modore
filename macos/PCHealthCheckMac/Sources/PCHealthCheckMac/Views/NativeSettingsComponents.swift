import SwiftUI

struct NativeStatusGlyph: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct NativeSectionHeader: View {
    let title: String
    let subtitle: String
    var value: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            Spacer()
            if !value.isEmpty {
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textCase(nil)
            }
        }
    }
}

extension View {
    func macSettingsFormStyle() -> some View {
        self
            .formStyle(.grouped)
            .frame(maxWidth: 980)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
    }
}
