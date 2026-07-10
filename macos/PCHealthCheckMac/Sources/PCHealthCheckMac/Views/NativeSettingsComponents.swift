import AppKit
import SwiftUI

struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: max(6, size * 0.22)))
    }
}

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

struct NativeSettingsNavigationRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: icon, tint: tint, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 14)
                Text(value)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

struct NativeSettingsChangeRow: View {
    let item: StorageItemChange

    var body: some View {
        HStack(spacing: 12) {
            NativeStatusGlyph(
                symbol: item.deltaGB > 0 ? "arrow.up" : "arrow.down",
                tint: item.deltaGB > 0 ? .orange : .green
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.body.weight(.medium))
                Text("\(item.beforeGB, specifier: "%.1f") → \(item.afterGB, specifier: "%.1f")GB · 논리 크기")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%+.1fGB", item.deltaGB))
                .font(.callout.weight(.medium))
                .foregroundStyle(item.deltaGB > 0 ? .orange : .green)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

struct NativeCurrentSizeRow: View {
    let item: StorageItem

    var body: some View {
        HStack(spacing: 12) {
            NativeStatusGlyph(symbol: "folder", tint: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.body.weight(.medium))
                Text(item.action).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.sizeText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

struct NativeSettingsMessageRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NativeStatusGlyph(symbol: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
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
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 980)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
