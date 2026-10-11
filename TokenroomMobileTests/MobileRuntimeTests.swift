import Security
import XCTest
@testable import TokenroomMobile

/// App-owned runtime isolation regressions.
@MainActor final class MobileRuntimeTests: XCTestCase {
    private var suites: [String] = []
    private var launchArguments: [String: Any] = [:]
    override func setUp() {
        super.setUp()
        // NSArgumentDomain belongs to the process, including across named suites.
        launchArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }
    override func tearDown() {
        UserDefaults.standard.setVolatileDomain(launchArguments, forName: UserDefaults.argumentDomain)
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suites.removeAll()
        super.tearDown()
    }
    private func defaults() -> UserDefaults {
        let name = "tokenroom.tests.mobile-runtime." + UUID().uuidString
        suites.append(name); return UserDefaults(suiteName: name)!
    }
    func testXCTestRootWithoutFixtureUsesInertDependenciesAndIsolatedPreferences() async {
        let launch = defaults(), isolated = defaults()
        let store = MobileRuntime.store(launchDefaults: launch, isUnitTestHost: true, inertDefaults: isolated)
        XCTAssertFalse(store.allowsExternalEffects)
        XCTAssertFalse(store.hasPersistentStorage)
        XCTAssertFalse(store.connectOnIPhone)
        XCTAssertNil(store.keys.accessGroup)
        XCTAssertEqual(isolated.string(forKey: MobileStore.Keys.sourceID), store.sourceID)
        XCTAssertNil(launch.object(forKey: MobileStore.Keys.sourceID))
        let status = store.keys.keychain.copy([:]).status
        XCTAssertEqual(status, errSecItemNotFound)
        XCTAssertEqual(store.keys.keychain.add([:]), errSecInteractionNotAllowed)
        await store.refresh(force: true)
        XCTAssertTrue(store.readings.isEmpty)
    }
    func testXCTestSampleRootPresentsSamplesWithoutPersistentStorage() async {
        let launch = defaults(), isolated = defaults()
        launch.setVolatileDomain(["sampleMode": "YES", "onboarded": "YES"], forName: UserDefaults.argumentDomain)
        let store = MobileRuntime.store(launchDefaults: launch, isUnitTestHost: true, inertDefaults: isolated)
        XCTAssertTrue(store.sampleMode); XCTAssertTrue(store.hasOnboarded)
        XCTAssertFalse(store.readings.isEmpty); XCTAssertFalse(store.hasPersistentStorage)
        let ids = store.readings.map(\.id)
        await store.refresh(force: true); await store.backgroundRefresh()
        XCTAssertEqual(store.readings.map(\.id), ids)
        XCTAssertNil(launch.object(forKey: MobileStore.Keys.sourceID))
    }
    func testExplicitSnapshotWithoutXCTestAlsoIsolatesMobileRoot() {
        for key in ["TokenroomSnapshotNews", "TokenroomSnapshots", "TokenroomGallery"] {
            let launch = defaults()
            launch.set("/tmp/owned-fixture/news.json", forKey: key)
            let store = MobileRuntime.store(launchDefaults: launch, isUnitTestHost: false, inertDefaults: defaults())
            XCTAssertFalse(store.allowsExternalEffects, key)
            XCTAssertFalse(store.hasPersistentStorage, key)
            XCTAssertFalse(store.connectOnIPhone, key)
        }
    }
    func testInertRootDirectDeliveryPushAndBackgroundRemainSilent() async {
        let store = MobileRuntime.store(launchDefaults: defaults(), isUnitTestHost: true, inertDefaults: defaults())
        let alert = UsageAlert(id: "inert", provider: "openrouter", kind: .threshold, level: 80,
            title: "Usage", body: "Limit", resetsAt: nil, isUrgent: false)
        let delivered = await store.deliverAlerts([alert], now: .now)
        XCTAssertTrue(delivered.isEmpty)
        let changed = await store.refreshForPush(); XCTAssertFalse(changed)
        await store.scheduleBackgroundRefresh(); await store.prepareNotifications()
        XCTAssertTrue(store.readings.isEmpty)
    }
    func testOrdinarySampleModeDoesNotSelectInertComposition() {
        let launch = defaults()
        launch.setVolatileDomain(["sampleMode": "YES"], forName: UserDefaults.argumentDomain)
        XCTAssertFalse(NewsRuntime.isInert(launchDefaults: launch, isUnitTestHost: false))
        XCTAssertTrue(NewsRuntime.isInert(launchDefaults: launch, isUnitTestHost: true))
    }
}
