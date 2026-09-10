import SwiftUI

/// Task choices stay visible while technical categories are grouped in the workspace.
struct RetirementIntentRail: View {
    @Binding var selection: String
    let freeBytes: Int64?

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("지금 할 일").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom,8)
            destination("space", "공간 비우기", "기기 · OS · 캐시", "sparkles")
            destination("finish", "작업 마치기", "서버 · 가상머신", "moon")
            destination("eject", "SSD 가져가기", "연결 해제 준비", "externaldrive")
            Spacer()
            VStack(alignment:.leading,spacing:5) {
                Text("이 Mac의 여유 공간").font(.caption).foregroundStyle(.secondary)
                Text(freeBytes.map { ByteCountFormatter.string(fromByteCount:$0,countStyle:.file) } ?? "측정 중")
                    .font(.system(size:25,weight:.semibold,design:.rounded)).monospacedDigit()
            }.padding(.bottom,8)
        }.padding(22).frame(width:210).frame(maxHeight:.infinity)
    }
    private func destination(_ id:String,_ title:String,_ detail:String,_ icon:String) -> some View {
        Button { selection=id } label: {
            HStack(spacing:12) {
                Image(systemName:icon).font(.title3).frame(width:24)
                VStack(alignment:.leading,spacing:5) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength:0)
            }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
                .background(selection == id ? Color.teal.opacity(0.13) : Color.clear,in:RoundedRectangle(cornerRadius:14))
                .foregroundStyle(selection == id ? Color.teal : Color.primary)
                .contentShape(RoundedRectangle(cornerRadius:14))
        }.buttonStyle(.plain).accessibilityAddTraits(selection == id ? .isSelected : [])
    }
}
