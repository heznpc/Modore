# iPhone cleanup

The iOS app is self-contained in `ios/Modore`; Taxi and a running Mac service are not required.

## User flow

- **Photos and videos:** grant Photo Library access, choose Videos, Screen recordings, or Photos, select individual items, review their thumbnails and dates, then confirm deletion. PhotoKit presents its own system confirmation. Favorites are labeled; assets that PhotoKit cannot delete are disabled.
- The browser displays up to 200 accessible items per filter: videos by duration and photos by creation date. Duration is not a file-size estimate. Thumbnails do not trigger iCloud downloads.
- **Files:** choose up to 100 individual files through the system file picker, then select and review the ones to delete. No directory traversal or cross-app cache scan occurs. Regular files only; folders, symbolic links and unavailable iCloud files are excluded.
- Photos move to Recently Deleted. Permanent removal remains in Photos, and iCloud Photos deletion propagates to other devices. File-provider deletion may also propagate to other devices and may be irreversible. Both confirmation screens explain the corresponding behavior.

## Execution and evidence

Before mutation, the app writes a local receipt and measures device capacity. If the receipt cannot be written, deletion does not start. The result records requested/deleted counts, status, timestamps and before/after capacity, with no media identifiers, file paths or filenames. The app retains the latest 20 receipts and displays the latest result. An interrupted operation remains visibly unresolved after restart.

PhotoKit re-fetches the exact confirmed identifiers and checks metadata and delete eligibility inside its change block. A missing, edited or inaccessible selection is not silently reduced to a subset.

File access uses security-scoped URLs and file coordination. The entire selection is checked before deletion, then each file is checked again within its coordinated write. URL resource-value caches are cleared before every metadata measurement; identity, modification time, size and resolved path must match the preview. Partial execution is reported with the actual successful count, and retries require a fresh selection.

Available-space change is a device-wide observation, not a guaranteed amount recovered by Modore. Recently Deleted, cloud placeholders, external volumes and unrelated activity can affect it. Negative and unavailable measurements remain visible.

## Validation

```sh
xcodebuild test \
  -project ios/Modore/Modore.xcodeproj \
  -scheme Modore \
  -destination 'platform=iOS Simulator,id=<existing-simulator-UDID>' \
  CODE_SIGNING_ALLOWED=NO
```

`CleanupTests` covers preview without deletion, exact confirmation scope, permission failure, stale confirmation, receipt persistence/failure, unchanged capacity, changed/replaced files, symlink/directory exclusion, and deletion replay. These tests create and remove only their own temporary files.

Device validation should additionally cover limited Photo Library access, iCloud Photos, third-party file providers and delayed capacity reclamation. Simulator capacity reflects the host volume and cannot establish the amount of storage recovered on a physical iPhone.

### Local verification, 2026-09-10

- Built the app and its test bundle with Xcode 26.6 / iOS Simulator SDK 26.5, with complete concurrency checking and warnings as errors.
- Ran all 30 XCTest cases on the existing iOS 26.3 simulator: 30 passed. The local Xcode scheme destination lookup rejected the installed runtime, so the test bundle was built by target and run in the installed app using Apple's XCTest bundle injector and simulator framework paths.
- In the running Korean UI, imported a disposable three-second video, confirmed that denying the PhotoKit deletion prompt retained it and recorded zero deletions, then approved deletion and observed the empty video list and a completed receipt.
- Chose a disposable file through the system Files picker, reviewed and deleted it, then checked both the actual file's absence and the completed receipt in the app.
- Installed and launched the development-signed app on a physical iPhone 16 running iOS 26.5.2. The running Modore process was confirmed with Apple's device tools.
- Ran all 30 XCTest cases on that physical iPhone: 30 passed. Target-based builds and Apple's XCTest bundle injector were used because scheme destination lookup failed locally. The test-only bundle included the signed XCTest runtime dependencies, including `lib_TestingInterop.dylib` and `_Testing_Foundation.framework`; the normal app was reinstalled afterward.
- Physical iPhone storage reclamation and cloud synchronization remain unverified.
