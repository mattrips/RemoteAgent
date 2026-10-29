import Testing
@testable import RemoteAgentService

struct LiveDecodeRateTests {
    @Test func excludesPromptTimeAndWaitsForMeasurement() {
        var rate = LiveDecodeRate()
        #expect(rate.speed(at: 1000) == nil)
        rate.record(count: 1, at: 1000)
        #expect(rate.speed(at: 1000.25) == nil)
        rate.record(count: 41, at: 1001)
        #expect(rate.speed(at: 1001) == 40)
        #expect(rate.speed(at: 1002) == 20) // A pause lowers the live average.
    }
    @Test func repeatedCountsDoNotResetTimingAndNewRequestStartsFresh() {
        var rate = LiveDecodeRate()
        rate.record(count: 1, at: 5)
        rate.record(count: 21, at: 6)
        rate.record(count: 21, at: 7)
        #expect(rate.speed(at: 7) == 10)
        rate = LiveDecodeRate()
        #expect(rate.speed(at: 100) == nil)
        rate.record(count: 1, at: 100)
        rate.record(count: 31, at: 101)
        #expect(rate.speed(at: 101) == 30)
    }
}
