import Foundation
@testable import SwiftmailCore
import Synchronization
import Testing

final class BoundarySequence: Sendable {
    private let next = Mutex(0)
    func make() -> String {
        next.withLock { value in
            value += 1
            return "BOUNDARY\(value)"
        }
    }
}

func deterministicBuilder() -> MIMEBuilder {
    let sequence = BoundarySequence()
    return MIMEBuilder(makeBoundary: { sequence.make() }, makeMessageID: { _ in "<fixed@example.com>" })
}

/// Removes the Date header, which follows the local time zone.
func withoutDate(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.hasPrefix("Date: ") }.joined(separator: "\r\n")
}

struct MIMEBuilderTests {
    let me = EmailAddress(name: "Me", email: "me@example.com")

    @Test func plainOnlyGolden() {
        var message = OutgoingMessage(from: me)
        message.to = [EmailAddress(name: "Alex", email: "alex@example.com")]
        message.subject = "Hello"
        message.plain = "Hi Alex"
        let expected = [
            "From: Me <me@example.com>",
            "To: Alex <alex@example.com>",
            "Subject: Hello",
            "Message-ID: <fixed@example.com>",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=\"UTF-8\"",
            "Content-Transfer-Encoding: base64",
            "",
            "SGkgQWxleA==",
        ].joined(separator: "\r\n")
        #expect(withoutDate(deterministicBuilder().build(message)) == expected)
    }

    @Test func htmlGolden() {
        var message = OutgoingMessage(from: me)
        message.to = [EmailAddress(email: "alex@example.com")]
        message.subject = "Hi"
        message.html = "<p>Hi <b>there</b></p>"
        let expected = [
            "From: Me <me@example.com>",
            "To: alex@example.com",
            "Subject: Hi",
            "Message-ID: <fixed@example.com>",
            "MIME-Version: 1.0",
            "Content-Type: multipart/alternative; boundary=\"BOUNDARY1\"",
            "",
            "--BOUNDARY1",
            "Content-Type: text/plain; charset=\"UTF-8\"",
            "Content-Transfer-Encoding: base64",
            "",
            Data("Hi there".utf8).base64EncodedString(),
            "--BOUNDARY1",
            "Content-Type: text/html; charset=\"UTF-8\"",
            "Content-Transfer-Encoding: base64",
            "",
            Data("<p>Hi <b>there</b></p>".utf8).base64EncodedString(),
            "--BOUNDARY1--",
            "",
        ].joined(separator: "\r\n")
        #expect(withoutDate(deterministicBuilder().build(message)) == expected)
    }

    @Test func fullStructureRoundTrips() {
        var message = OutgoingMessage(from: EmailAddress(name: "Zoë Ångström", email: "zoe@example.com"))
        message.to = [EmailAddress(name: "Doe, Jane", email: "jane@example.com")]
        message.cc = [EmailAddress(email: "cc@example.com")]
        message.bcc = [EmailAddress(email: "secret@example.com")]
        message.subject = "Réunion 🎉 — a long subject line that needs folding because it goes on and on and on"
        message.html = "<p>Chart: <img src=\"cid:chart1\"></p>"
        message.inlineImages = [OutgoingPart(filename: "chart.png", mimeType: "image/png", data: Data([1, 2, 3]), contentID: "chart1")]
        message.attachments = [OutgoingPart(filename: "résumé – 2026.pdf", mimeType: "application/pdf", data: Data(repeating: 7, count: 5000))]
        message.inReplyTo = "<orig@example.com>"
        message.references = "<root@example.com> <orig@example.com>"
        let raw = deterministicBuilder().build(message)
        let text = String(decoding: raw, as: UTF8.self)

        #expect(!text.split(separator: "\r\n", omittingEmptySubsequences: false).contains { $0.count > 998 })
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(text.contains("Bcc: secret@example.com"))
        #expect(text.contains("In-Reply-To: <orig@example.com>"))
        #expect(text.contains("References: <root@example.com> <orig@example.com>"))
        #expect(text.contains("filename*=UTF-8''r%C3%A9sum%C3%A9%20%E2%80%93%202026.pdf"))
        #expect(text.contains("Content-Type: multipart/mixed"))
        #expect(text.contains("Content-Type: multipart/related"))
        #expect(text.contains("Content-Type: multipart/alternative"))

        let payload = EMLParser.parse(raw)
        let decoded = MessageDecoder.decode(payload)
        #expect(decoded.headers.subject == message.subject)
        #expect(decoded.headers.from?.name == "Zoë Ångström")
        #expect(decoded.headers.to.first?.name == "Doe, Jane")
        #expect(decoded.html == message.html)
        #expect(decoded.plain == "Chart:")
        #expect(decoded.attachments.map(\.filename).sorted() == ["chart.png", "résumé – 2026.pdf"])
        #expect(decoded.attachments.first { $0.contentID == "chart1" }?.isInline == true)
        #expect(decoded.attachments.first { $0.filename.hasPrefix("résumé") }?.data?.count == 5000)
    }

    @Test func singleChildWrappersAreLeftOut() {
        var message = OutgoingMessage(from: me)
        message.to = [EmailAddress(email: "a@example.com")]
        message.plain = "text"
        message.attachments = [OutgoingPart(filename: "a.txt", mimeType: "text/plain", data: Data("a".utf8))]
        let text = String(decoding: deterministicBuilder().build(message), as: UTF8.self)
        #expect(text.contains("multipart/mixed"))
        #expect(!text.contains("multipart/related"))
        #expect(!text.contains("multipart/alternative"))
    }

    @Test func headerEncoding() {
        #expect(MIMEBuilder.encodeWord("plain") == "plain")
        #expect(MIMEBuilder.encodeWord("café") == "=?UTF-8?B?Y2Fmw6k=?=")
        let long = MIMEBuilder.encodeWord(String(repeating: "é", count: 60))
        #expect(long.split(separator: " ").allSatisfy { $0.count <= 75 })
        #expect(HeaderDecoding.decode(long) == String(repeating: "é", count: 60))
        #expect(MIMEBuilder.encodeAddress(EmailAddress(name: "Doe, Jane", email: "j@x.com")) == "\"Doe, Jane\" <j@x.com>")
    }

    @Test func plainTextFromHTML() {
        let html = """
        <div>Hello <b>world</b><br>second line</div><p>Para</p><ul><li>one</li><li>two</li></ul>
        <ol><li>first</li><li>second</li></ol><a href="https://example.com">site</a> <a href="https://x.com">https://x.com</a>
        <blockquote>quoted<br>text</blockquote>
        """
        let text = PlainTextConverter.convert(html)
        #expect(text.contains("Hello world\nsecond line"))
        #expect(text.contains("• one\n• two"))
        #expect(text.contains("1. first\n2. second"))
        #expect(text.contains("site (https://example.com)"))
        #expect(text.contains("https://x.com") && !text.contains("https://x.com (https://x.com)"))
        #expect(text.contains("> quoted\n> text"))
    }

    @Test func dataURLImagesBecomeInlineParts() {
        let html = "<p>x<img src=\"data:image/png;base64,AQID\"></p>"
        let (rewritten, parts) = OutgoingAssembler.extractInlineImages(html)
        #expect(parts.count == 1)
        #expect(parts.first?.data == Data([1, 2, 3]))
        #expect(rewritten.contains("cid:\(parts.first?.contentID ?? "")"))
        #expect(!rewritten.contains("data:image"))
    }

    @Test func largeMessagesUseTheUploadEndpoint() async throws {
        let transport = StubTransport { _, _ in
            (200, [:], jsonData(["id": "m1", "threadId": "t1"]))
        }
        let tokens = TokenProvider(accountID: "a", secrets: InMemorySecretStore(["a": "r"]), refresher: { _ in
            TokenResponse(accessToken: "x", expiresIn: 3600, refreshToken: nil, idToken: nil, scope: nil)
        })
        let client = RESTGmailClient(transport: transport, tokens: tokens, quota: QuotaBucket(), sleep: { _ in })
        _ = try await client.sendMessage(raw: Data(repeating: 65, count: 100), threadID: "t1")
        _ = try await client.sendMessage(raw: Data(repeating: 65, count: 6 * 1024 * 1024), threadID: "t1")
        let urls = transport.requests.compactMap(\.url?.absoluteString)
        #expect(urls[0] == "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
        #expect(urls[1] == "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart")
        #expect(transport.requests[1].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/related") == true)
    }
}
