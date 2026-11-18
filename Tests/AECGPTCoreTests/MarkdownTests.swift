import XCTest
@testable import AECGPTCore

final class MarkdownTests: XCTestCase {

    func testTypicalArabicAnswer() {
        let md = """
        ## أركان أمن المعلومات

        هي **ثلاثة** أركان:

        1. السرية (Confidentiality)
        2. السلامة
           - تشمل التحقق من التعديل
        3. التوفر

        ---

        > ملاحظة: هذا تبسيط.

        ```python
            def hello():
                print("hi")
        ```

        | الركن | المعنى |
        |---|:---:|
        | السرية | منع الوصول |
        | التوفر | |

        $$
        M = C^d \\mod n
        $$

        والمعادلة \\(a^2\\) داخل السطر.
        """
        let blocks = Markdown.parse(md)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "أركان أمن المعلومات"),
            .paragraph("هي **ثلاثة** أركان:"),
            .list([
                MDListItem(level: 0, marker: "1.", text: "السرية (Confidentiality)"),
                MDListItem(level: 0, marker: "2.", text: "السلامة"),
                MDListItem(level: 1, marker: "•", text: "تشمل التحقق من التعديل"),
                MDListItem(level: 0, marker: "3.", text: "التوفر"),
            ]),
            .rule,
            .quote("ملاحظة: هذا تبسيط."),
            .code(language: "python", text: "def hello():\n    print(\"hi\")"),
            .table(header: ["الركن", "المعنى"], rows: [["السرية", "منع الوصول"], ["التوفر", ""]]),
            .math("M = C^d \\mod n"),
            .paragraph("والمعادلة a^2 داخل السطر."),
        ])
    }

    func testLooseListStaysOneList() {
        let blocks = Markdown.parse("- أ\n\n- ب\n\nفقرة")
        XCTAssertEqual(blocks, [
            .list([MDListItem(level: 0, marker: "•", text: "أ"), MDListItem(level: 0, marker: "•", text: "ب")]),
            .paragraph("فقرة"),
        ])
    }

    func testNotAListOrHeading() {
        XCTAssertEqual(Markdown.parse("#hashtag\n2026 كانت سنة"), [.paragraph("#hashtag\n2026 كانت سنة")])
        XCTAssertEqual(Markdown.parse("***"), [.rule])
    }

    func testUnclosedCodeFenceKeepsText() {
        XCTAssertEqual(Markdown.parse("```\nlet x = 1"), [.code(language: "", text: "let x = 1")])
    }

    func testChecklistAndContinuation() {
        let blocks = Markdown.parse("- [ ] مهمة\n- [x] تمت\n  سطر تابع")
        XCTAssertEqual(blocks, [.list([
            MDListItem(level: 0, marker: "•", text: "☐ مهمة"),
            MDListItem(level: 0, marker: "•", text: "☑ تمت\nسطر تابع"),
        ])])
    }
}
