import XCTest
@testable import DevSweep

final class AutoCleanupScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    func testDisabledScheduleHasNoNextFireDate() {
        let schedule = AutoCleanupSchedule(isEnabled: false, mode: .interval, intervalHours: 6)
        XCTAssertNil(schedule.nextFireDate(
            after: date(2026, 5, 1, 12), lastRunAt: nil, calendar: calendar
        ))
    }

    func testIntervalUsesLastRunPlusInterval() {
        let schedule = AutoCleanupSchedule(isEnabled: true, mode: .interval, intervalHours: 6)
        let lastRun = date(2026, 5, 1, 8)
        XCTAssertEqual(
            schedule.nextFireDate(after: date(2026, 5, 1, 10), lastRunAt: lastRun, calendar: calendar),
            date(2026, 5, 1, 14)
        )
    }

    func testIntervalWithoutHistoryWaitsOneFullInterval() {
        let schedule = AutoCleanupSchedule(isEnabled: true, mode: .interval, intervalHours: 4)
        let now = date(2026, 5, 1, 12)
        XCTAssertEqual(
            schedule.nextFireDate(after: now, lastRunAt: nil, calendar: calendar),
            date(2026, 5, 1, 16)
        )
    }

    func testOverdueIntervalCatchesUpAfterShortDelay() {
        let schedule = AutoCleanupSchedule(isEnabled: true, mode: .interval, intervalHours: 2)
        let now = date(2026, 5, 1, 12)
        let next = schedule.nextFireDate(
            after: now, lastRunAt: date(2026, 5, 1, 8), calendar: calendar
        )
        XCTAssertEqual(next, now.addingTimeInterval(AutoCleanupSchedule.catchUpDelay))
    }

    func testDailyScheduleUsesNextOccurrenceToday() {
        let schedule = AutoCleanupSchedule(
            isEnabled: true, mode: .dailyTime, dailyHour: 3, dailyMinute: 0
        )
        XCTAssertEqual(
            schedule.nextFireDate(
                after: date(2026, 5, 1, 2), lastRunAt: nil, calendar: calendar
            ),
            date(2026, 5, 1, 3)
        )
    }

    func testDailyScheduleRollsToTomorrowAfterTodaysTime() {
        let schedule = AutoCleanupSchedule(
            isEnabled: true, mode: .dailyTime, dailyHour: 3, dailyMinute: 0
        )
        XCTAssertEqual(
            schedule.nextFireDate(
                after: date(2026, 5, 1, 12), lastRunAt: nil, calendar: calendar
            ),
            date(2026, 5, 2, 3)
        )
    }

    func testMissedDailyRunCatchesUpAfterShortDelay() {
        let schedule = AutoCleanupSchedule(
            isEnabled: true, mode: .dailyTime, dailyHour: 3, dailyMinute: 0
        )
        let now = date(2026, 5, 1, 12)
        let next = schedule.nextFireDate(
            after: now, lastRunAt: date(2026, 4, 30, 3), calendar: calendar
        )
        XCTAssertEqual(next, now.addingTimeInterval(AutoCleanupSchedule.catchUpDelay))
    }

    func testDailyScheduleDoesNotCatchUpAfterItAlreadyRan() {
        let schedule = AutoCleanupSchedule(
            isEnabled: true, mode: .dailyTime, dailyHour: 3, dailyMinute: 0
        )
        XCTAssertEqual(
            schedule.nextFireDate(
                after: date(2026, 5, 1, 12),
                lastRunAt: date(2026, 5, 1, 4),
                calendar: calendar
            ),
            date(2026, 5, 2, 3)
        )
    }

    @MainActor
    func testEmptyTrashSettingDefaultsOffAndPersists() {
        let name = "DevSweepAutoCleanupEmptyTrash-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        let store = DevSweepStore(defaults: defaults)
        let scheduler = AutoCleanupScheduler(store: store, defaults: defaults)
        XCTAssertFalse(scheduler.autoEmptyTrash)
        XCTAssertEqual(scheduler.autoEmptyTrashTiming, .afterCleanup)

        scheduler.setAutoEmptyTrash(true)
        scheduler.setAutoEmptyTrashTiming(.beforeScan)
        XCTAssertTrue(scheduler.autoEmptyTrash)
        XCTAssertEqual(scheduler.autoEmptyTrashTiming, .beforeScan)

        let reloaded = AutoCleanupScheduler(store: store, defaults: defaults)
        XCTAssertTrue(reloaded.autoEmptyTrash)
        XCTAssertEqual(reloaded.autoEmptyTrashTiming, .beforeScan)
    }
}

@MainActor
final class AppPresentationControllerTests: XCTestCase {
    private var suiteName: String?

    override func tearDown() {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
            self.suiteName = nil
        }
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "DevSweepPresentationTests-\(UUID().uuidString)"
        suiteName = name
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeController(
        defaults: UserDefaults,
        policies: @escaping (Bool) -> Void
    ) -> AppPresentationController {
        AppPresentationController(
            defaults: defaults,
            activationPolicyHandler: policies
        )
    }

    func testHidingDockIconForcesMenuBarEntryPoint() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppPresentationController.showDockIconKey)
        defaults.set(false, forKey: AppPresentationController.showMenuBarIconKey)

        var appliedPolicies: [Bool] = []
        let controller = makeController(defaults: defaults) { appliedPolicies.append($0) }
        XCTAssertTrue(controller.showDockIcon)
        XCTAssertFalse(controller.showMenuBarIcon)

        controller.setShowDockIcon(false)

        XCTAssertFalse(controller.showDockIcon)
        XCTAssertTrue(controller.showMenuBarIcon)
        XCTAssertEqual(appliedPolicies, [false])
        XCTAssertTrue(defaults.bool(forKey: AppPresentationController.showMenuBarIconKey))

        // Dock 已隐藏，菜单栏是唯一入口，不能再关闭。
        controller.setShowMenuBarIcon(false)
        XCTAssertTrue(controller.showMenuBarIcon)
    }

    func testMenuBarCanBeHiddenOnlyWhileDockIconIsVisible() {
        let defaults = makeDefaults()
        var appliedPolicies: [Bool] = []
        let controller = makeController(defaults: defaults) { appliedPolicies.append($0) }
        XCTAssertTrue(controller.showDockIcon)
        XCTAssertTrue(controller.showMenuBarIcon)

        controller.setShowMenuBarIcon(false)
        XCTAssertFalse(controller.showMenuBarIcon)

        controller.setShowDockIcon(false)
        XCTAssertTrue(controller.showMenuBarIcon)
        XCTAssertEqual(appliedPolicies, [false])
    }

    func testRepairsExistingConfigurationWithBothEntryPointsHidden() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppPresentationController.showDockIconKey)
        defaults.set(false, forKey: AppPresentationController.showMenuBarIconKey)

        let controller = makeController(defaults: defaults) { _ in }

        XCTAssertFalse(controller.showDockIcon)
        XCTAssertTrue(controller.showMenuBarIcon)
        XCTAssertTrue(defaults.bool(forKey: AppPresentationController.showMenuBarIconKey))
    }
}
