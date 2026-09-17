import SwiftUI

struct SpaceGoalCandidateRow: View {
    let item: StorageItem
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) {
            HStack(spacing: 12) {
                NativeSourceIcon(item: item, fallbackSymbol: "folder.badge.gearshape")
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(item.label)).font(.body.weight(.medium)).lineLimit(1)
                    Text((item.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 16)
                Text(item.measureStatus == "timed_out"
                    ? L10n.text("크기 확인 필요")
                    : StorageBytes.text(StorageBytes.fromLegacyGiB(item.sizeGB)))
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .help(item.path)
        .contextMenu { StorageItemContextMenu(item: item) }
    }
}
