import XCTest

/// How much the feed stutters while it's scrolled, as Apple measures it (WWDC20, "Eliminate animation hitches with
/// XCTest"): the hitch time ratio, in milliseconds of hitches a second of scrolling. Under 5 is good; from 10 people
/// notice. On made-up posts (FeedHarness), with nothing fetched, so it's the feed's own work. On the simulator the
/// numbers are only for comparing one build with the one before, not with a phone. A measurement: nothing fails.
final class FeedScrollUITests: XCTestCase {
    func testFeedScrollHitches() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-feed"]
        app.launch()
        // the feed itself by name: firstMatch once found another full-screen scroll view, and nothing scrolled (1.4.0)
        let feed = app.scrollViews["feedHarness"]
        XCTAssertTrue(feed.waitForExistence(timeout: 15), "no feed")
        Thread.sleep(forTimeInterval: 2)   // the photos made and laid out first
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTOSSignpostMetric.scrollDraggingMetric], options: options) {
            feed.swipeUp(velocity: .fast)
            feed.swipeUp(velocity: .fast)
            feed.swipeDown(velocity: .fast)
            feed.swipeDown(velocity: .fast)
        }
    }
}
