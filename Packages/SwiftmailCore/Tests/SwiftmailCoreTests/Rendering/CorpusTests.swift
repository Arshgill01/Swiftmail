import Foundation
@testable import SwiftmailCore
import SwiftSoup
import Testing

enum Corpus {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestCorpus/emails")

    static var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".eml") }.sorted()
    }

    static func decode(_ name: String) throws -> DecodedMessage {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return MessageDecoder.decode(EMLParser.parse(data))
    }

    static func render(_ name: String) throws -> RenderedBody {
        try BodyRenderer.render(decode(name), accountID: "acc", messageID: name)
    }
}

struct CorpusTests {
    @Test func corpusHasAboutThirtyMessages() {
        #expect(Corpus.files.count >= 30)
    }

    @Test(arguments: Corpus.files)
    func rendersSafely(_ name: String) throws {
        let rendered = try Corpus.render(name)
        let document = try SwiftSoup.parse(rendered.html)
        // No active content survives.
        #expect(try document.select("script, iframe, frame, object, embed, applet, form, input, button, base, link").isEmpty())
        for element in try document.getAllElements().array() {
            for attribute in element.getAttributes()?.asList() ?? [] {
                #expect(!attribute.getKey().lowercased().hasPrefix("on"), "\(name): \(attribute.getKey())")
                let value = attribute.getValue().lowercased().filter { !$0.isWhitespace }
                #expect(!value.hasPrefix("javascript:"), "\(name)")
            }
        }
        // Exactly one CSP, the blocking one; the only http(s) images are ones the CSP blocks.
        let metas = try document.select("meta[http-equiv]").array()
        #expect(metas.count == 1)
        #expect(try metas.first?.attr("content") == ReaderCSP.blocked)
        #expect(rendered.html.contains("class=\"sm-content\""))
    }

    @Test func specificCorpusExpectations() throws {
        let newsletter = try Corpus.render("01-newsletter-table.eml")
        #expect(newsletter.hasRemoteContent)
        #expect(newsletter.trackerCount == 1)
        #expect(newsletter.usesPaper)

        let inline = try Corpus.decode("03-inline-images.eml")
        #expect(inline.attachments.filter(\.isInline).count == 2)
        #expect(try Corpus.render("03-inline-images.eml").html.contains("swiftmail-cid://acc/03-inline-images.eml/chart%40corpus"))

        #expect(try Corpus.decode("04-calendar-invite.eml").calendarPart?.contains("BEGIN:VCALENDAR") == true)
        #expect(try Corpus.decode("07-iso-8859-1.eml").plain?.contains("Café crème") == true)
        #expect(try Corpus.decode("07-iso-8859-1.eml").headers.subject == "Réunion à 15h")
        #expect(try Corpus.decode("08-shift-jis.eml").plain?.contains("こんにちは") == true)
        #expect(try Corpus.decode("10-twenty-attachments.eml").attachments.count == 20)
        #expect(try Corpus.decode("17-utf8-emoji-subject.eml").headers.subject == "🎉 Ünïcödé subject über alles")
        #expect(try Corpus.decode("17-utf8-emoji-subject.eml").headers.from?.name == "Zoë Ångström")
        #expect(try Corpus.decode("18-rfc2231-filename.eml").attachments.first?.filename == "résumé – 2026.pdf")
        #expect(try Corpus.decode("19-quoted-printable-html.eml").html?.contains("Café — quoted-printable") == true)
        #expect(try Corpus.decode("27-windows-1252.eml").plain == "“Smart quotes” and — dashes …")
        #expect(try Corpus.decode("28-text-attachment.eml").attachments.map(\.filename) == ["notes.txt"])
        #expect(try Corpus.decode("29-message-rfc822.eml").attachments.first?.mimeType == "message/rfc822")
        #expect(try Corpus.decode("31-multiple-html-parts.eml").html?.contains("List footer") == true)

        #expect(try Corpus.render("22-tracker-pixels.eml").trackerCount == 5)
        #expect(try !Corpus.render("20-simple-html.eml").usesPaper)
        #expect(try Corpus.render("32-dark-colors.eml").usesPaper)
        #expect(try Corpus.render("21-css-background-remote.eml").hasRemoteContent)
        #expect(try Corpus.render("02-plain-flowed.eml").html.contains("soft line breaks should join into one paragraph when shown."))
        func quotes(_ name: String) throws -> Int {
            try SwiftSoup.parse(Corpus.render(name).html).select("details.sm-quote").size()
        }
        #expect(try quotes("11-long-thread-nested-quotes.eml") == 1)
        #expect(try quotes("13-apple-mail-reply.eml") == 1)
        #expect(try quotes("14-outlook-reply.eml") == 1)
        #expect(try quotes("16-plain-reply-quoted.eml") == 1)
        #expect(try quotes("02-plain-flowed.eml") == 1)
        #expect(try quotes("15-gmail-forward.eml") == 0)
        #expect(try Corpus.render("23-javascript-links.eml").html.contains("data:image/png;base64"))
    }

    @Test func hugeMailSanitizesQuickly() throws {
        let decoded = try Corpus.decode("09-huge-html.eml")
        let start = Date()
        let rendered = BodyRenderer.render(decoded, accountID: "a", messageID: "m")
        #expect(rendered.html.count > 500_000)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
