import SwiftUI

struct RetirementReviewSheet: View {
    @EnvironmentObject private var model: ScanModel
    let projectID: String

    var body: some View {
        AssetRetirementView(initialPath: model.workProjects.first { $0.id == projectID }?.path)
    }
}
