import Foundation
import Testing
@testable import OpenCaptionsKit

@MainActor @Suite struct BackgroundJobTests {
    @Test func whereTheSystemHasNoBackgroundJobsAJobIsInertAndHarmless() {
        // On the Mac these tests run on, and on an iPhone before iOS 26, there is nothing to submit to.
        #if !os(iOS)
            #expect(!BackgroundJob.isSupported)
        #endif
        var stopped = 0
        let job = BackgroundJob.begin(title: "Saving", subtitle: "OpenCaptions", onStop: { stopped += 1 })
        job.update(fraction: 0.4, subtitle: "40%")
        job.update(fraction: 7)  // out of range is held to 0...1, not an error
        job.end(success: true)
        job.end(success: false)  // a second end is nothing
        job.update(fraction: 0.9)  // and so is an update after it
        #expect(stopped == 0, "ending a job ourselves is not the system stopping it")
        #expect(!job.continuesInBackground)
    }
}
