#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests --package-path macos/Modore \
  -Xswiftc -warnings-as-errors \
  -Xswiftc -strict-concurrency=complete
modore_test_bundle="$(swift build --package-path macos/Modore --show-bin-path)/ModorePackageTests.xctest"

# Existing model contracts assert Korean user-facing copy. Set preferences
# only in the test process; never change the runner or developer's defaults.
xcrun xctest -XCTest All -AppleLanguages '(ko)' -AppleLocale ko_KR "$modore_test_bundle"

# Keep language negotiation and shipped catalogs covered on non-Korean hosts.
for modore_test_language in en ja; do
  xcrun xctest -AppleLanguages "($modore_test_language)" \
    -XCTest ModoreTests.LocalizationTests "$modore_test_bundle"
done
