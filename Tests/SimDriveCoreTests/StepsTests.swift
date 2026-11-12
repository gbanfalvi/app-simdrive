import Foundation
import Testing
@testable import SimDriveCore

struct StepsTests {
    @Test func tokenizeKeepsQuotedText() throws {
        #expect(try Steps.tokenize(#"type "hello world"  'a b' c"#) == ["type", "hello world", "a b", "c"])
        #expect(try Steps.tokenize(#"type """#) == ["type", ""])
        expectUsageError { try Steps.tokenize(#"type "open"#) }
    }

    @Test func stepsMustBeAnArrayOfStringsOrScalarArrays() {
        expectUsageError { try Steps.parse(Data(#"{"tap": 1}"#.utf8)) }
        expectUsageError { try Steps.parse(Data(#"[1]"#.utf8)) }
        expectUsageError { try Steps.parse(Data(#"[["tap", [1]]]"#.utf8)) }
    }
}
