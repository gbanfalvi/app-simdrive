import Testing
@testable import SimDriveCore

struct JSONValueTests {
    @Test func argumentsDropTheFractionOfWholeNumbers() {
        #expect(JSONValue.number(100).argument == "100")
        #expect(JSONValue.number(0.5).argument == "0.5")
        #expect(JSONValue.number(1e300).argument == "1e+300")
        #expect(JSONValue.bool(true).argument == "true")
        #expect(JSONValue.null.argument == nil)
    }
}
