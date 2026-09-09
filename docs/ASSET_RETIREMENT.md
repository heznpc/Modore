# Asset retirement

Modore owns this domain transaction: GitHub archive, local deletion, approval,
revalidation, retry, cancellation, verification, free-space sampling and receipt.
There is no Taxi dependency, shared database or shared execution authority.

## User flow

Open **저장공간 → 레포 아카이브·로컬 정리** without running a full scan, or open
retirement from a project in **작업**. Add repository folders, independently select
GitHub archive and local deletion, and review the exact keep/delete manifest.
Git ignored data stays in its original location by default. Generated ignored
outputs (`node_modules`, `build`, `.build`, `dist`, caches) have a separate size and
an opt-in deletion selection. This classification is a naming heuristic, not a
claim that every such file is disposable. No quarantine or external-disk move is
performed. An empty repository root may remain after its Git metadata is removed.

Risk warnings are optional exclusion conditions. Unchecked warnings do not
prevent approval. Dirty files, unpushed work, stash and worktree references are
warnings, not executor invariants. Root directory references reported by lsof
are evidence only; session/process/symlink reference coverage is explicitly
incomplete. Git remote-tracking refs are not silently fetched.

Identity invariants cannot be waived: the approved root device/inode must match,
path traversal must not follow directory symlinks, descendants must stay on the
approved volume, and each selected entry's identity must match immediately before
removal. Unknown/replaced targets are shown for renewed confirmation. GitHub
archive uses the approved stable node ID with the official
[archiveRepository mutation](https://docs.github.com/en/graphql/reference/repos#archiverepository),
not a mutable repository name as the mutation authority. github.com and existing
GitHub CLI authentication are currently supported; no visibility changes occur.

## Transactions and retries

Private transaction JSON and append-only operation journals live under Modore's
Application Support `asset-retirement` directory. They contain paths and Git
metadata, not file bodies, and are not uploaded. Before each unlink, the journal
records the attempted entry; a retry reconciles an interrupted unlink against
the remaining inventory. Journal writes are proportional to the operation count,
not repeated full copies of the file manifest. Insufficient space for a durable
journal is reported as an execution failure before the next unlink.

Unchanged approved items continue without another approval. Changed items lose
approval and must be refreshed and confirmed; other items continue. After partial
local deletion, newly discovered files default to preservation during refresh.
The refresh checkpoints progress before replacing its remaining manifest. A
cancellation stops future entries and leaves successful mutations in the receipt.
App termination waits for the active transaction; abrupt interruption is recovered
from the journal. Concurrent use of one transaction is rejected by its file lock.

Mutation status, post-verification status, and before/after volume free space are
separate. A successful GitHub request with a failed follow-up read remains a
successful mutation with failed verification. Free-space deltas are observations,
not attributable savings, and manifest byte totals are never promised recovery.

The screen shows up to 200 file entries per repository; the JSON receipt contains
the full manifest. **이전 거래 불러오기** resumes the latest saved transaction.

## Validation

- `python3 -m unittest discover -s tests -p test_asset_retirement.py -v`
- `swift test --package-path macos/Modore --filter AssetRetirementServiceTests`
- Signed app build: `scripts/build_macos_swift_app.sh`

The tests delete real disposable Git checkouts and verify ignored bytes, generated
selection, symlink containment, changed targets, cancellation, journal recovery,
and retries. GitHub failure/success responses are injected; running the suite does
not archive a real GitHub repository. The Swift integration test drives the actual
Modore subprocess service through preview, approval, execution and verification.
