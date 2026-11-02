import Testing
@testable import Morph

private func battery(_ percentage: Int, external: Bool = false, charging: Bool = false, charged: Bool = false) -> BatterySnapshot {
    BatterySnapshot(percentage: percentage, isCharging: charging, isOnExternalPower: external, isCharged: charged)
}

private struct FixedReader: PowerSourceReading {
    let snapshot: BatterySnapshot?
    func read() -> BatterySnapshot? { snapshot }
}

@Suite("Battery")
struct BatteryTests {
    @Test func firstReadingAnnouncesNothing() {
        var detector = BatteryTransitionDetector()
        #expect(detector.process(battery(80, external: true, charging: true)).isEmpty)
    }

    @Test func launchingAtLowBatteryStillWarns() {
        var detector = BatteryTransitionDetector()
        #expect(detector.process(battery(12)) == [.low(percentage: 12)])
    }

    @Test func connectingAndDisconnectingPower() {
        var detector = BatteryTransitionDetector()
        _ = detector.process(battery(50))
        #expect(detector.process(battery(50, external: true, charging: true)) == [.powerConnected(percentage: 50, charging: true)])
        #expect(detector.process(battery(52)) == [.powerDisconnected(percentage: 52)])
    }

    @Test func connectedButNotCharging() {
        var detector = BatteryTransitionDetector()
        _ = detector.process(battery(90))
        #expect(detector.process(battery(90, external: true)) == [.powerConnected(percentage: 90, charging: false)])
    }

    @Test func chargeCompletion() {
        var detector = BatteryTransitionDetector()
        _ = detector.process(battery(99, external: true, charging: true))
        #expect(detector.process(battery(100, external: true, charged: true)) == [.fullyCharged])
        #expect(detector.process(battery(100, external: true, charged: true)).isEmpty)
    }

    @Test func eachAlertFiresOncePerDischarge() {
        var detector = BatteryTransitionDetector(lowThreshold: 20)
        _ = detector.process(battery(21))
        #expect(detector.process(battery(20)) == [.low(percentage: 20)])
        #expect(detector.process(battery(19)).isEmpty)
        #expect(detector.process(battery(5)) == [.critical(percentage: 5)])
        #expect(detector.process(battery(4)).isEmpty)
    }

    @Test func alertsRearmAfterCharging() {
        var detector = BatteryTransitionDetector(lowThreshold: 20)
        _ = detector.process(battery(20))
        _ = detector.process(battery(25, external: true, charging: true))
        _ = detector.process(battery(24))
        #expect(detector.process(battery(20)) == [.low(percentage: 20)])
    }

    @Test func noLowAlertWhileCharging() {
        var detector = BatteryTransitionDetector(lowThreshold: 20)
        _ = detector.process(battery(30, external: true, charging: true))
        #expect(detector.process(battery(10, external: true, charging: true)).isEmpty)
    }

    @Test func statusText() {
        var value = battery(50, external: true, charging: true)
        value.minutesToFull = 95
        #expect(value.statusText == "1h 35m until full")
        #expect(battery(50, external: true).statusText == "Not charging")
        #expect(battery(100, external: true, charged: true).statusText == "Charged")
        var discharging = battery(50)
        discharging.minutesToEmpty = 40
        #expect(discharging.statusText == "40m left")
    }

    @Test @MainActor func macsWithoutABatteryReportNothing() {
        let service = BatteryService(reader: FixedReader(snapshot: nil))
        var events = 0
        service.onEvent = { _ in events += 1 }
        service.refresh()
        #expect(service.snapshot == nil)
        #expect(events == 0)
    }

    @Test func realPowerSourceReadsOnThisMac() {
        // Passes on desktops too: this asserts sanity, not the presence of a battery.
        if let snapshot = IOKitPowerSourceReader().read() {
            print("Power source: \(snapshot.percentage)%, charging \(snapshot.isCharging), external \(snapshot.isOnExternalPower)")
            #expect((0...100).contains(snapshot.percentage))
        }
    }
}
