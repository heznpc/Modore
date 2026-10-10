import XCTest
@testable import Modore

final class AutomaticCacheConsentTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "modore-consent-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testLegacyOptInRequiresReviewAndNeverGrantsCurrentScope() {
        withDefaults { defaults in
            defaults.set(true, forKey: AutomaticCacheConsentStore.enabledKey)
            XCTAssertEqual(AutomaticCacheConsentStore.status(in: defaults), .reviewRequired)
            XCTAssertFalse(AutomaticCacheConsentStore.isAuthorized(in: defaults))
            XCTAssertNil(defaults.data(forKey: AutomaticCacheConsentStore.consentKey))
        }
    }

    func testExplicitConsentPersistsItsScopeAndRevocationIsImmediate() throws {
        try withDefaults { defaults in
            let acceptedAt = Date(timeIntervalSince1970: 1_700_000_000)
            try AutomaticCacheConsentStore.grant(in: defaults, now: acceptedAt)
            let data = try XCTUnwrap(defaults.data(forKey: AutomaticCacheConsentStore.consentKey))
            let consent = try JSONDecoder().decode(AutomaticCacheConsent.self, from: data)
            XCTAssertEqual(consent.acceptedAt, acceptedAt)
            XCTAssertEqual(consent.recipeVersions, AutomaticCachePolicy.consentScope)
            XCTAssertTrue(AutomaticCacheConsentStore.isAuthorized(in: defaults))
            AutomaticCacheConsentStore.revoke(in: defaults)
            XCTAssertEqual(AutomaticCacheConsentStore.status(in: defaults), .disabled)
            XCTAssertFalse(AutomaticCacheConsentStore.isAuthorized(in: defaults))
        }
    }

    func testNewRecipeOrExpandedRecipeScopeRequiresNewConsent() throws {
        try withDefaults { defaults in
            try AutomaticCacheConsentStore.grant(in: defaults)
            var expanded = AutomaticCachePolicy.consentScope
            expanded["new-recipe"] = 1
            XCTAssertEqual(AutomaticCacheConsentStore.status(in: defaults, scope: expanded), .reviewRequired)
            expanded = AutomaticCachePolicy.consentScope
            expanded[AutomaticCachePolicy.recipes[0]] = 2
            XCTAssertEqual(AutomaticCacheConsentStore.status(in: defaults, scope: expanded), .reviewRequired)
            XCTAssertEqual(AutomaticCacheConsentStore.status(in: defaults,
                scope: [AutomaticCachePolicy.recipes[0]: 1]), .authorized)
        }
    }

    func testMalformedOrFutureConsentDoesNotAuthorizeExecution() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: AutomaticCacheConsentStore.enabledKey)
            defaults.set(Data("invalid".utf8), forKey: AutomaticCacheConsentStore.consentKey)
            XCTAssertEqual(AutomaticCacheConsentStore.status(in: defaults), .reviewRequired)
            var consent = AutomaticCacheConsent(acceptedAt: Date(), recipeVersions: AutomaticCachePolicy.consentScope)
            consent.schemaVersion = 2
            defaults.set(try JSONEncoder().encode(consent), forKey: AutomaticCacheConsentStore.consentKey)
            XCTAssertFalse(AutomaticCacheConsentStore.isAuthorized(in: defaults))
        }
    }

    @MainActor func testLoadingLegacyOptInDoesNotRenewIt() {
        withDefaults { defaults in
            defaults.set(true, forKey: AutomaticCacheConsentStore.enabledKey)
            let recovery = AutomaticCacheRecovery(defaults: defaults)
            XCTAssertFalse(recovery.enabled)
            XCTAssertTrue(recovery.requiresConsentReview)
            XCTAssertFalse(recovery.isDue)
            XCTAssertNil(defaults.data(forKey: AutomaticCacheConsentStore.consentKey))
            recovery.setEnabled(true)
            XCTAssertTrue(recovery.enabled)
            XCTAssertFalse(recovery.requiresConsentReview)
            recovery.setEnabled(false)
            XCTAssertFalse(AutomaticCacheConsentStore.isAuthorized(in: defaults))
        }
    }
}
