import Foundation
import Testing
@testable import SimDriveCore

struct CrashReportsTests {
    private let udid = "6895D822-C48C-4919-92D3-12C9C8474EF1"

    private func report(coalition: String? = nil, extra: String = "") -> String {
        let header = #"{"app_name":"AXProbe","timestamp":"2026-11-12 13:55:16.00 +0000","bug_type":"309","name":"AXProbe"}"#
        let body = """
            {"procName":"AXProbe","pid":4242,"captureTime":"2026-11-12 13:54:50.9488 +0000",
             "coalitionName":"com.apple.CoreSimulator.SimDevice.\(coalition ?? udid)",
             "exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP","codes":"0x1"},
             "asi":{"libswiftCore.dylib":["AXProbe/main.swift:10: Fatal error: probe crash"]},
             "faultingThread":1,
             "threads":[{"frames":[{"imageOffset":1,"imageIndex":0}]},
                        {"triggered":true,"frames":[{"imageOffset":96,"symbol":"_assertionFailure","symbolLocation":160,"imageIndex":1},
                                                    {"imageOffset":4096,"imageIndex":0},
                                                    {"imageOffset":8,"imageIndex":9}]}],
             "usedImages":[{"name":"AXProbe"},{"name":"libswiftCore.dylib"}]\(extra)}
            """
        return header + "\n" + body
    }

    @Test func summarizesTheCrashingThread() throws {
        let summary = try #require(CrashReports.summary(ofReport: report(), path: "/r.ips", udid: udid))
        #expect(summary == CrashSummary(process: "AXProbe", pid: 4242, time: "2026-11-12 13:54:50.9488 +0000",
                                        exception: "EXC_BREAKPOINT (SIGTRAP)", reason: "AXProbe/main.swift:10: Fatal error: probe crash",
                                        frames: ["libswiftCore.dylib _assertionFailure + 160", "AXProbe + 4096", "??? + 8"],
                                        path: "/r.ips"))
    }

    @Test func readsTheCaptureTime() throws {
        let summary = try #require(CrashReports.summary(ofReport: report(), path: "/r.ips", udid: udid))
        let date = try #require(CrashReports.capturedAt(summary))
        #expect(abs(date.timeIntervalSince1970 - 1_794_491_690.9488) < 0.000_1)
    }

    @Test func prefersTheUncaughtExceptionsBacktrace() throws {
        let extra = #","lastExceptionBacktrace":[{"imageOffset":12,"symbol":"objc_exception_throw","symbolLocation":4,"imageIndex":0}]"#
        let summary = try #require(CrashReports.summary(ofReport: report(extra: extra), path: "/r.ips", udid: udid))
        #expect(summary.frames == ["AXProbe objc_exception_throw + 4"])
    }

    @Test func ignoresOtherDevicesAndMalformedReports() {
        #expect(CrashReports.summary(ofReport: report(coalition: "OTHER"), path: "/r.ips", udid: udid) == nil)
        #expect(CrashReports.summary(ofReport: "{}", path: "/r.ips", udid: udid) == nil)
        #expect(CrashReports.summary(ofReport: "{}\nnot json", path: "/r.ips", udid: udid) == nil)
    }

    @Test func summaryJSONListsEveryField() throws {
        let summary = try #require(CrashReports.summary(ofReport: report(), path: "/r.ips", udid: udid))
        guard case .object(let fields) = summary.json else {
            Issue.record("not an object")
            return
        }
        #expect(Set(fields.keys) == ["process", "pid", "time", "exception", "reason", "frames", "path"])
    }

    private static func exitEvent(_ message: String, subsystem: String = "com.apple.FrontBoard") -> LogEvent {
        LogEvent(date: Date(timeIntervalSince1970: 1_795_624_114.672), level: .default, message: message, subsystem: subsystem,
                 category: "Process", process: "SpringBoard", pid: 94154)
    }

    /// As SpringBoard logged the probe's `-probeCrash` on iOS 27.2 (F32).
    @Test func anAppEndingOnASignalIsACrash() throws {
        let line = "[app<com.simdrive.axprobe>:95205] Process exited: <RBSProcessExitContext| specific, status:<RBSProcessExitStatus| "
            + "domain:signal(2) code:SIGTRAP(5)>>."
        let exit = try #require(CrashReports.appExit(Self.exitEvent(line)))
        #expect(exit.bundleID == "com.simdrive.axprobe" && exit.pid == 95205 && exit.signal == "SIGTRAP")
    }

    @Test func quitsKillsAndExtensionsAreNot() {
        let ended = "[app<com.simdrive.axprobe>:95205] Process exited: <RBSProcessExitContext| specific, status:<RBSProcessExitStatus| "
        #expect(CrashReports.appExit(Self.exitEvent(ended + "domain:runningboard(15) code:0>>.")) == nil)
        #expect(CrashReports.appExit(Self.exitEvent(ended + "domain:signal(2) code:SIGKILL(9)>>.")) == nil)
        #expect(CrashReports.appExit(Self.exitEvent("[extension<com.apple.Poster:95459] Process exited: <RBSProcessExitContext| "
            + "specific, status:<RBSProcessExitStatus| domain:signal(2) code:SIGTRAP(5)>>.")) == nil)
        #expect(CrashReports.appExit(Self.exitEvent(ended + "domain:signal(2) code:SIGTRAP(5)>>.", subsystem: "simdrive.probe")) == nil)
    }

    /// A crash that wrote a report is listed once, from the report; SpringBoard logs each exit twice.
    @Test func logCrashesSkipReportedPidsAndRepeats() throws {
        let exit = AppExit(bundleID: "com.simdrive.axprobe", pid: 95205, signal: "SIGTRAP", date: Date(timeIntervalSince1970: 0))
        let other = AppExit(bundleID: "com.simdrive.axprobe", pid: 4242, signal: "SIGABRT", date: Date(timeIntervalSince1970: 0))
        let reported = try #require(CrashReports.summary(ofReport: report(), path: "/r.ips", udid: udid))
        let found = CrashReports.summaries(of: [exit, exit, other], process: { _ in "AXProbe" }, reported: [reported])
        #expect(found.map(\.pid) == [95205])
        #expect(found.first?.path == nil && found.first?.exception == "SIGTRAP" && found.first?.time == "1970-01-01 00:00:00.0000 +0000")
    }
}
