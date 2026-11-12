import SimDriveNative
import Testing
@testable import SimDriveCore

func expectError<Result>(_ code: ErrorCode, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Result) {
    let error = #expect(throws: SimDriveError.self, sourceLocation: sourceLocation) { try body() }
    #expect(error?.code == code, sourceLocation: sourceLocation)
}

func expectUsageError<Result>(sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Result) {
    expectError(.usage, sourceLocation: sourceLocation, body)
}
