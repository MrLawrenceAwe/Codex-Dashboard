import XCTest
@testable import CodexDashboard

final class ProjectSourceAnalyzerTests: XCTestCase {
    func testPhysicalLinesDoNotInventTrailingLine() {
        XCTAssertEqual(ProjectSourceAnalyzer.lineCount(""), 0)
        XCTAssertEqual(ProjectSourceAnalyzer.lineCount("hello\n"), 1)
        XCTAssertEqual(ProjectSourceAnalyzer.lineCount("hello\nworld"), 2)
        XCTAssertEqual(ProjectSourceAnalyzer.lineCount("\n\n"), 2)
    }

    func testSwiftMasksStringsCommentsAndNestedBraces() {
        let code = #"""
        // func fake() { }
        func real() {
            let value = "} func fake() {"
            /* } /* nested */ } */
            if true { print(value) }
        }
        func short() { }
        """#
        let functions = ProjectSourceAnalyzer.functions(in: code, extension: "swift")
        XCTAssertEqual(functions.map(\.name), ["real", "short"])
        XCTAssertEqual(functions.map(\.lineCount), [5, 1])
    }

    func testJavaScriptNamedArrowAndMethodDeclarations() {
        let code = """
        export async function fetchItems() {
          return [];
        }
        const calculate = (x) => {
          return x + 1;
        };
        class Client {
          async send(item) {
            if (item) { return item; }
          }
        }
        """
        let functions = ProjectSourceAnalyzer.functions(in: code, extension: "ts")
        XCTAssertEqual(functions.map(\.name), ["fetchItems", "calculate", "send"])
        XCTAssertEqual(functions.map(\.lineCount), [3, 3, 3])
    }

    func testPythonNestedAndMultilineFunctions() {
        let code = #"""
        async def outer(
            value,
        ):
            text = """def fake():
        literal content"""
            def inner():
                return value
            return inner()

        def other():
            pass
        """#
        let functions = ProjectSourceAnalyzer.functions(in: code, extension: "py")
        XCTAssertEqual(functions.map(\.name), ["outer", "inner", "other"])
        XCTAssertEqual(functions.map(\.lineCount), [8, 2, 2])
        XCTAssertEqual(functions[1].id, "outer.inner#0")
    }

    func testGoReceiverAndRustLifetime() {
        XCTAssertEqual(ProjectSourceAnalyzer.functions(in: "func (s *Server) Serve() {\n return\n}", extension: "go").first?.lineCount, 3)
        XCTAssertEqual(ProjectSourceAnalyzer.functions(in: "fn borrow<'a>(x: &'a str) {\n println!(\"{}\", x);\n}", extension: "rs").first?.lineCount, 3)
    }

    func testDuplicateNamesHaveDistinctStableIDsAndIncompleteBodyIsOmitted() {
        let functions = ProjectSourceAnalyzer.functions(in: "func first() {}\nfunc first(x: Int) {}\nfunc unfinished() {", extension: "swift")
        XCTAssertEqual(functions.map(\.id), ["first#0", "first#1"])
        XCTAssertTrue(ProjectSourceAnalyzer.functions(in: "func fake() {}", extension: "txt").isEmpty)
    }
}

extension ProjectSourceAnalyzerTests {
    func testSingleQuotedJavaScriptAndTripleQuotedSwiftDoNotAffectBodies() {
        let js = "function real() {\n const text = 'fake } function nope() {';\n return text;\n}"
        XCTAssertEqual(ProjectSourceAnalyzer.functions(in: js, extension: "js").map(\.name), ["real"])
        XCTAssertEqual(ProjectSourceAnalyzer.functions(in: js, extension: "js").first?.lineCount, 4)
        let swift = #"""
        func actual() {
            let text = """
        } func fake() {}
        """
            print(text)
        }
        """#
        XCTAssertEqual(ProjectSourceAnalyzer.functions(in: swift, extension: "swift").map(\.name), ["actual"])
        XCTAssertEqual(ProjectSourceAnalyzer.functions(in: swift, extension: "swift").first?.lineCount, 6)
    }
}
