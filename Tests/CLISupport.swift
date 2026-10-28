#if CORE_CLI_TESTS
import Foundation

final class CLITestState {
    static var assertions = 0
    static var failures: [String] = []
    static func fail(_ text: String, file: StaticString, line: UInt) { failures.append("\(file):\(line): \(text)"); print("  FAIL \(failures.last!)") }
}
class XCTestCase {
    private var cleanup: [() -> Void] = []
    func addTeardownBlock(_ block: @escaping () -> Void) { cleanup.append(block) }
    func finish() { cleanup.reversed().forEach { $0() }; cleanup = [] }
}
func XCTFail(_ message: String = "Failed", file: StaticString = #filePath, line: UInt = #line) { CLITestState.fail(message, file: file, line: line) }
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    CLITestState.assertions += 1
    do { if try !value() { CLITestState.fail("Expected true. \(message)", file: file, line: line) } } catch { CLITestState.fail("\(error)", file: file, line: line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(try !value(), message, file: file, line: line) }
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    CLITestState.assertions += 1
    do { let lhs = try a(), rhs = try b(); if lhs != rhs { CLITestState.fail("\(lhs) != \(rhs). \(message)", file: file, line: line) } } catch { CLITestState.fail("\(error)", file: file, line: line) }
}
func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(try a() != b(), file: file, line: line) }
func XCTAssertNotNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(try value() != nil, file: file, line: line) }
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(try value() == nil, file: file, line: line) }
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(try a() <= b(), file: file, line: line) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    CLITestState.assertions += 1
    do { _ = try expression(); CLITestState.fail("Expected error. \(message)", file: file, line: line) } catch { }
}
func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    CLITestState.assertions += 1
    do { _ = try expression() } catch { CLITestState.fail("Unexpected error: \(error). \(message)", file: file, line: line) }
}
extension Bundle { static var module: Bundle { Bundle(path: ProcessInfo.processInfo.environment["QUIETCAST_TEST_RESOURCES"]!)! } }
#endif
