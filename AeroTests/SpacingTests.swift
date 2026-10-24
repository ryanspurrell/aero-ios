import XCTest

/// Every padding, spacing and inset in a view file is a name from `Look.Space` (Aero/Native/Tokens.swift), never a number written in place.
/// Why: "not enough padding in places, and lots of inconsistent padding, especially in aero" (Aryn, 2026-10-23); the cause was raw numbers
/// (6, 7, 10, 14, 18, 120 ...) beside the named steps, so two screens meant the same gap with different values.
///
/// What is checked: the argument of `.padding(...)`, the value after `spacing:`, and the arguments of `EdgeInsets(` / `UIEdgeInsets(`, in every
/// Swift file under Aero/ and Field/ except Tokens.swift (where the steps are defined). A number there fails the test. The one number allowed is
/// 0, because "no gap" is the absence of a step, not a size (`VStack(spacing: 0)` is how a stack is told to add nothing between its rows, its
/// default being a system amount). A bare `.padding()` also fails: it adds a system amount that is not one of the steps.
/// Frame sizes, offsets and font sizes are not spacing and are not checked here.
final class SpacingTests: XCTestCase {
    /// The repository root, found from this file's own path (AeroTests/SpacingTests.swift), so it works wherever the project is checked out.
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    static func offences(in source: String) -> [String] {
        // comments out, so a number in a note does not count
        let code = source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let r = line.range(of: "//") { return String(line[..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
        let chars = Array(code)
        var found: [String] = []

        func balanced(from open: Int) -> String? {      // the text inside the bracket at `open`
            var depth = 0
            var i = open
            while i < chars.count {
                if chars[i] == "(" { depth += 1 } else if chars[i] == ")" { depth -= 1; if depth == 0 { return String(chars[(open + 1)..<i]) } }
                i += 1
            }
            return nil
        }
        func untilEnd(from start: Int) -> String {        // an expression up to the , or ) that ends it
            var depth = 0
            var i = start
            while i < chars.count {
                let c = chars[i]
                if c == "(" || c == "[" { depth += 1 } else if c == ")" || c == "]" { if depth == 0 { break }; depth -= 1 } else if (c == "," || c == "\n" || c == "{") && depth == 0 { break }
                i += 1
            }
            return String(chars[start..<i])
        }
        func numbers(_ text: String) -> [String] {
            let re = try! NSRegularExpression(pattern: #"(?<![\w.])\d+(\.\d+)?"#)
            let ns = text as NSString
            return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }.filter { Double($0) != 0 }
        }
        func line(of index: Int) -> Int { chars[..<index].filter { $0 == "\n" }.count + 1 }

        var i = 0
        while i < chars.count {
            func has(_ s: String) -> Bool { let a = Array(s); return i + a.count <= chars.count && Array(chars[i..<(i + a.count)]) == a }
            if has(".padding(") {
                let open = i + ".padding".count
                if let inner = balanced(from: open) {
                    if inner.trimmingCharacters(in: .whitespaces).isEmpty { found.append("line \(line(of: i)): .padding() is a system amount") }
                    else if !numbers(inner).isEmpty { found.append("line \(line(of: i)): .padding(\(inner))") }
                }
            } else if has("spacing:") {
                let value = untilEnd(from: i + "spacing:".count)
                if !numbers(value).isEmpty { found.append("line \(line(of: i)): spacing:\(value)") }
            } else if has("EdgeInsets(") {
                if let inner = balanced(from: i + "EdgeInsets".count), !numbers(inner).isEmpty { found.append("line \(line(of: i)): EdgeInsets(\(inner))") }
            }
            i += 1
        }
        return found
    }

    private func swiftFiles(_ folder: String) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Tokens.swift" }
    }

    func testNoNumberWrittenInPlaceForPaddingSpacingOrInsets() throws {
        let files = swiftFiles("Aero") + swiftFiles("Field")
        try XCTSkipIf(files.isEmpty, "the source folders are not beside the tests here")
        var all: [String] = []
        for f in files {
            let source = try String(contentsOf: f, encoding: .utf8)
            all += Self.offences(in: source).map { "\(f.lastPathComponent) \($0)" }
        }
        XCTAssertEqual(all, [], "use a name from Look.Space (Tokens.swift) instead of a number:\n" + all.joined(separator: "\n"))
    }

    /// The check itself finds what it should and lets through what it should.
    func testTheCheckFindsNumbersAndLetsNamesAndZeroThrough() {
        XCTAssertEqual(Self.offences(in: ".padding(.horizontal, 14)").count, 1)
        XCTAssertEqual(Self.offences(in: ".padding(Look.Space.pad - 4)").count, 1)
        XCTAssertEqual(Self.offences(in: "VStack(spacing: 18) {").count, 1)
        XCTAssertEqual(Self.offences(in: "UIEdgeInsets(top: 60, left: 0, bottom: 0, right: 0)").count, 1)
        XCTAssertEqual(Self.offences(in: ".padding()").count, 1)
        XCTAssertEqual(Self.offences(in: ".padding(.top, Look.Space.gutter)").count, 0)
        XCTAssertEqual(Self.offences(in: "VStack(spacing: 0) {").count, 0)
        XCTAssertEqual(Self.offences(in: "GridItem(.flexible(), spacing: Look.Space.hairline), count: 7)").count, 0)
        XCTAssertEqual(Self.offences(in: "// .padding(12) in a note").count, 0)
        XCTAssertEqual(Self.offences(in: "x.padding(.leading, metrics.blockX - Look.Space.nowLead)").count, 0)
    }
}
