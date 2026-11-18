import XCTest
@testable import AECGPTCore

final class ConversationParserTests: XCTestCase {

    /// محادثة واقعية: سؤال معدّل (فرعين)، رسالة نظام مخفية، بحث، تفكير، صورة مولدة، رسم بياني، ومصادر
    let conversation = """
    {
      "title": "خطة سفر",
      "update_time": 1763478000.5,
      "conversation_id": "conv-1",
      "current_node": "a3",
      "mapping": {
        "root": {"id": "root", "message": null, "parent": null, "children": ["sys"]},
        "sys": {"id": "sys", "parent": "root", "children": ["u1old", "u1"],
          "message": {"id": "sys", "author": {"role": "system"}, "content": {"content_type": "text", "parts": [""]},
                      "metadata": {"is_visually_hidden_from_conversation": true}}},
        "u1old": {"id": "u1old", "parent": "sys", "children": [],
          "message": {"id": "u1old", "author": {"role": "user"}, "content": {"content_type": "text", "parts": ["السؤال القديم قبل التعديل"]}}},
        "u1": {"id": "u1", "parent": "sys", "children": ["t1"],
          "message": {"id": "u1", "author": {"role": "user"}, "content": {"content_type": "multimodal_text", "parts": [
            {"content_type": "image_asset_pointer", "asset_pointer": "file-service://file-UPLOAD1", "width": 800},
            "وش أفضل وقت لزيارة الرياض؟"]}}},
        "t1": {"id": "t1", "parent": "u1", "children": ["s1"],
          "message": {"id": "t1", "author": {"role": "assistant"}, "content": {"content_type": "thoughts", "thoughts": []}, "recipient": "all"}},
        "s1": {"id": "s1", "parent": "t1", "children": ["s1r"],
          "message": {"id": "s1", "author": {"role": "assistant"}, "content": {"content_type": "text", "parts": ["search(\\"riyadh weather\\")"]}, "recipient": "web.run"}},
        "s1r": {"id": "s1r", "parent": "s1", "children": ["a1"],
          "message": {"id": "s1r", "author": {"role": "tool", "name": "web.run"}, "content": {"content_type": "text", "parts": ["raw search results"]}}},
        "a1": {"id": "a1", "parent": "s1r", "children": ["g1"],
          "message": {"id": "a1", "author": {"role": "assistant"}, "recipient": "all", "weight": 1.0,
            "content": {"content_type": "text", "parts": ["## أفضل وقت\\n\\nمن **نوفمبر** إلى فبراير \\ue200cite\\ue202turn0search1\\ue201.\\n\\n- الجو معتدل【4†source】\\n- فعاليات موسم الرياض"]}}},
        "g1": {"id": "g1", "parent": "a1", "children": ["a2"],
          "message": {"id": "g1", "author": {"role": "tool", "name": "t2uay3k.sj1i4kz"}, "content": {"content_type": "multimodal_text", "parts": [
            {"content_type": "image_asset_pointer", "asset_pointer": "sediment://file_GEN1"}]}}},
        "a2": {"id": "a2", "parent": "g1", "children": ["u2"],
          "message": {"id": "a2", "author": {"role": "assistant"}, "recipient": "all", "content": {"content_type": "text", "parts": ["هذي صورة للرياض."]}}},
        "u2": {"id": "u2", "parent": "a2", "children": ["c1"],
          "message": {"id": "u2", "author": {"role": "user"}, "content": {"content_type": "text", "parts": ["ارسم لي درجات الحرارة"]}}},
        "c1": {"id": "c1", "parent": "u2", "children": ["c1r"],
          "message": {"id": "c1", "author": {"role": "assistant"}, "recipient": "python", "content": {"content_type": "code", "text": "plt.plot(x)"}}},
        "c1r": {"id": "c1r", "parent": "c1", "children": ["a3"],
          "message": {"id": "c1r", "author": {"role": "tool", "name": "python"}, "content": {"content_type": "execution_output", "text": ""},
            "metadata": {"aggregate_result": {"messages": [{"message_type": "image", "image_url": "file-service://file-CHART1"}]}}}},
        "a3": {"id": "a3", "parent": "c1r", "children": [],
          "message": {"id": "a3", "author": {"role": "assistant"}, "recipient": "all", "content": {"content_type": "text", "parts": ["هذا الرسم."]}}}
      }
    }
    """

    func testFollowsCurrentBranchAndCleans() throws {
        let c = try ConversationParser.parseConversation(Data(conversation.utf8))
        XCTAssertEqual(c.id, "conv-1")
        XCTAssertEqual(c.title, "خطة سفر")
        XCTAssertEqual(c.updated, 1763478000500, accuracy: 1)

        let roles = c.messages.map(\.role)
        XCTAssertEqual(roles, ["user", "assistant", "user", "assistant"], "\(c.messages)")

        // الفرع المعدّل فقط، والصورة المرفوعة معه
        XCTAssertEqual(c.messages[0].text, "وش أفضل وقت لزيارة الرياض؟")
        XCTAssertEqual(c.messages[0].imageKeys, ["file-UPLOAD1"])
        XCTAssertFalse(c.messages.contains { $0.text.contains("القديم") })

        // الرد: بدون بحث ولا تفكير ولا علامات مصادر، مع الصورة المولدة مدموجة
        let reply = c.messages[1].text
        XCTAssertTrue(reply.hasPrefix("## أفضل وقت"), reply)
        XCTAssertTrue(reply.contains("من **نوفمبر** إلى فبراير."), reply)
        XCTAssertTrue(reply.contains("- الجو معتدل\n"), reply)
        XCTAssertTrue(reply.contains("هذي صورة للرياض."), reply)
        XCTAssertFalse(reply.contains("search("), reply)
        XCTAssertFalse(reply.contains("cite"), reply)
        XCTAssertFalse(reply.contains("【"), reply)
        XCTAssertFalse(reply.unicodeScalars.contains { (0xE200...0xE2FF).contains($0.value) }, reply)
        XCTAssertEqual(c.messages[1].imageKeys, ["file_GEN1"])

        // رسم بياني من تحليل البيانات، بدون كود الأداة
        XCTAssertEqual(c.messages[3].text, "هذا الرسم.")
        XCTAssertEqual(c.messages[3].imageKeys, ["file-CHART1"])
        XCTAssertFalse(c.messages.contains { $0.text.contains("plt.plot") })
    }

    func testListSortsAndSkipsArchived() throws {
        let json = """
        {"items": [
          {"id": "old", "title": "قديمة", "update_time": "2026-11-01T10:00:00.000000Z"},
          {"id": "arch", "title": "مؤرشفة", "update_time": "2026-11-18T12:00:00Z", "is_archived": true},
          {"id": "new", "title": "", "update_time": 1795014000}
        ], "total": 3}
        """
        let items = try ConversationParser.parseList(Data(json.utf8))
        XCTAssertEqual(items.map(\.id), ["new", "old"])
        XCTAssertEqual(items[0].title, "محادثة بدون عنوان")
        XCTAssertGreaterThan(items[1].updated, 1_700_000_000_000)
    }

    func testMissingCurrentNodeUsesLatestLeaf() throws {
        let json = """
        {"title": "x", "mapping": {
          "r": {"id": "r", "message": null, "parent": null, "children": ["u"]},
          "u": {"id": "u", "parent": "r", "children": ["a"], "message": {"id": "u", "author": {"role": "user"}, "create_time": 1, "content": {"content_type": "text", "parts": ["hi"]}}},
          "a": {"id": "a", "parent": "u", "children": [], "message": {"id": "a", "author": {"role": "assistant"}, "create_time": 2, "content": {"content_type": "text", "parts": ["hello"]}}}
        }}
        """
        let c = try ConversationParser.parseConversation(Data(json.utf8), fallbackId: "fb")
        XCTAssertEqual(c.id, "fb")
        XCTAssertEqual(c.messages.map(\.text), ["hi", "hello"])
    }

    func testWebImagesFromSearchAndMarkdown() throws {
        let json = """
        {"title": "صور", "conversation_id": "c2", "current_node": "a", "mapping": {
          "u": {"id": "u", "parent": null, "children": ["a"], "message": {"id": "u", "author": {"role": "user"}, "content": {"content_type": "text", "parts": ["وريني برج المملكة"]}}},
          "a": {"id": "a", "parent": "u", "children": [], "message": {"id": "a", "author": {"role": "assistant"}, "recipient": "all",
            "content": {"content_type": "text", "parts": ["\\ue200i\\ue202turn0image0\\ue201هذا البرج.\\n\\n![برج](https://img.example.com/tower.jpg)\\n\\nانتهى"]},
            "metadata": {"content_references": [
              {"type": "image_v2", "images": [
                {"url": "https://site.com/page", "thumbnail_url": "https://img.example.com/t1.jpg"},
                {"content_url": "https://img.example.com/t2.jpg"}]},
              {"type": "grouped_webpages", "items": [{"url": "https://site.com"}]},
              {"type": "image_inline", "image_url": "https://img.example.com/tower.jpg"}
            ]}}}
        }}
        """
        let c = try ConversationParser.parseConversation(Data(json.utf8))
        let reply = c.messages[1]
        XCTAssertEqual(reply.text, "هذا البرج.\n\nانتهى", reply.text)
        let urls = reply.imageKeys.compactMap { c.webImages[$0] }
        XCTAssertEqual(urls, ["https://img.example.com/tower.jpg",
                              "https://img.example.com/t1.jpg",
                              "https://img.example.com/t2.jpg"])
        XCTAssertTrue(reply.imageKeys.allSatisfy { $0.hasPrefix("web-") && !$0.contains("/") })
        // بديل لصورة البحث: لو المصغّرة رفضت، نجرب رابط الصفحة/الصورة الأصلية
        XCTAssertEqual(c.webImageFallbacks[ConversationParser.webKey("https://img.example.com/t1.jpg")],
                       ["https://site.com/page"])
        XCTAssertEqual(ConversationParser.webKey("https://a.com/x"), ConversationParser.webKey("https://a.com/x"))
        XCTAssertNotEqual(ConversationParser.webKey("https://a.com/x"), ConversationParser.webKey("https://a.com/y"))
    }

    func testFileKeys() {
        XCTAssertEqual(ConversationParser.fileKey("file-service://file-abc"), "file-abc")
        XCTAssertEqual(ConversationParser.fileKey("sediment://file_00000000abc"), "file_00000000abc")
        XCTAssertNil(ConversationParser.fileKey("https://example.com/a.png"))
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try ConversationParser.parseConversation(Data("{\"detail\":\"Unauthorized\"}".utf8)))
    }
}
