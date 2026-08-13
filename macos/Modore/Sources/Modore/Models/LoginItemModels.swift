import Foundation

/// An approval token issued by `login_items.sh --preview`, waiting for the
/// owner's explicit confirmation before `--execute` consumes it. Mirrors
/// cleanup.sh's own preview-then-approve shape, scaled down for a single
/// named target instead of a file-path manifest.
struct PendingLoginItemRemoval: Identifiable {
    var id: String { name }
    let name: String
    let approvalToken: String
}
