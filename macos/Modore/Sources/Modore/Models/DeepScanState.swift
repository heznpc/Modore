import Foundation

/// One coherent, completed collector pass. Live observations never overwrite
/// this value; they carry their own timestamps in `LiveState`.
typealias DeepScanSnapshot = ScanContent

struct DeepScanFailure: Equatable {
    let failedAt: Date
    let detail: String
}
