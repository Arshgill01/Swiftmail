import Foundation
@testable import SwiftmailCore
import Testing

private func part(
    _ mime: String,
    _ text: String? = nil,
    data: Data? = nil,
    headers: [GmailHeader] = [],
    filename: String? = nil,
    attachmentID: String? = nil,
    parts: [GmailMessagePart]? = nil,
    id: String = "0"
) -> GmailMessagePart {
    let bytes = data ?? text.map { Data($0.utf8) }
    return GmailMessagePart(
        partId: id, mimeType: mime, filename: filename ?? "",
        headers: headers.isEmpty ? [GmailHeader(name: "Content-Type", value: mime)] : headers,
        body: GmailMessagePartBody(attachmentId: attachmentID, size: bytes?.count ?? 1000, data: bytes.map(Base64URL.encode)),
        parts: parts
    )
}

struct DecodingTests {
    @Test func nestedMultipartPicksHTMLAndPlainAndAttachments() {
        let alternative = part("multipart/alternative", parts: [
            part("text/plain", "Hello plain", id: "0.0.0"),
            part("text/html", "<p>Hello <img src=\"cid:logo@x\"></p>", id: "0.0.1"),
        ], id: "0.0")
        let related = part("multipart/related", parts: [
            alternative,
            part("image/png", data: Data([1, 2, 3]), headers: [
                GmailHeader(name: "Content-Type", value: "image/png"), GmailHeader(name: "Content-ID", value: "<logo@x>"),
            ], id: "0.1"),
        ], id: "0")
        let mixed = part("multipart/mixed", parts: [
            related,
            part("application/pdf", filename: "report.pdf", attachmentID: "ATT1", id: "1"),
        ], id: "")
        let decoded = MessageDecoder.decode(mixed)
        #expect(decoded.plain == "Hello plain")
        #expect(decoded.html?.contains("cid:logo@x") == true)
        #expect(decoded.attachments.count == 2)
        let logo = decoded.attachments.first { $0.contentID == "logo@x" }
        #expect(logo?.isInline == true)
        #expect(logo?.data == Data([1, 2, 3]))
        let pdf = decoded.attachments.first { $0.filename == "report.pdf" }
        #expect(pdf?.attachmentID == "ATT1")
        #expect(pdf?.isInline == false)
    }

    @Test func charsetsDecode() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in ISO-8859-1
        let shiftJIS = Data([0x82, 0xB1, 0x82, 0xF1, 0x82, 0xC9, 0x82, 0xBF, 0x82, 0xCD]) // こんにちは
        let decoded1 = MessageDecoder.decode(part("text/plain", data: latin1, headers: [
            GmailHeader(name: "Content-Type", value: "text/plain; charset=\"ISO-8859-1\""),
        ]))
        #expect(decoded1.plain == "café")
        let decoded2 = MessageDecoder.decode(part("text/plain", data: shiftJIS, headers: [
            GmailHeader(name: "Content-Type", value: "text/plain; charset=Shift_JIS"),
        ]))
        #expect(decoded2.plain == "こんにちは")
        // Unknown charset falls back to UTF-8, then Windows-1252.
        #expect(Charset.decode(Data("ok ✓".utf8), charset: "x-unknown") == "ok ✓")
        #expect(Charset.decode(Data([0x93, 0x68, 0x69, 0x94]), charset: nil) == "“hi”")
    }

    @Test func formatFlowedFlagAndMissingParts() {
        let decoded = MessageDecoder.decode(part("text/plain", "a \nb", headers: [
            GmailHeader(name: "Content-Type", value: "text/plain; charset=utf-8; format=flowed; delsp=yes"),
        ]))
        #expect(decoded.plainIsFlowed)
        #expect(decoded.plainDelSp)
        let empty = MessageDecoder.decode(GmailMessagePart(mimeType: "multipart/mixed", headers: [], parts: []))
        #expect(empty.html == nil && empty.plain == nil && empty.attachments.isEmpty)
    }

    @Test func largeBodiesBecomePendingParts() {
        let big = part("text/html", nil, attachmentID: "BIG")
        let decoded = MessageDecoder.decode(big)
        #expect(decoded.pendingBodyParts == [PendingBodyPart(attachmentID: "BIG", isHTML: true, charset: nil)])
    }

    @Test func rfc2047Headers() {
        #expect(HeaderDecoding.decode("=?UTF-8?B?w6l0w6k=?=") == "été")
        #expect(HeaderDecoding.decode("=?ISO-8859-1?Q?caf=E9_cr=E8me?=") == "café crème")
        #expect(HeaderDecoding.decode("=?UTF-8?Q?a?= =?UTF-8?Q?b?=") == "ab")
        #expect(HeaderDecoding.decode("Re: =?UTF-8?B?5pel5pys?= news") == "Re: 日本 news")
        #expect(HeaderDecoding.decode("plain") == "plain")
    }

    @Test func rfc2231Filenames() {
        let params = HeaderParameters("attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf")
        #expect(params.value == "attachment")
        #expect(params["filename"] == "résumé.pdf")
        let continued = HeaderParameters("attachment; filename*0*=UTF-8''na%C3%AF; filename*1=ve.txt")
        #expect(continued["filename"] == "naïve.txt")
        #expect(HeaderParameters("text/html; charset=\"utf-8\"")["charset"] == "utf-8")
    }

    @Test func addressLists() {
        let list = EmailAddress.parseList(#""Doe, Jane" <jane@x.com>, bob@y.com, =?UTF-8?Q?Ren=C3=A9?= <rene@z.fr>, a@b.c (Al)"#)
        #expect(list.map(\.email) == ["jane@x.com", "bob@y.com", "rene@z.fr", "a@b.c"])
        #expect(list[0].name == "Doe, Jane")
        #expect(list[2].name == "René")
        #expect(list[3].name == "Al")
        #expect(EmailAddress.parseList("undisclosed-recipients:;").isEmpty)
    }

    @Test func snippetEntities() {
        #expect(HTMLEntities.decode("It&#39;s &amp; &quot;fine&quot; &#x263A;") == "It's & \"fine\" ☺")
        #expect(HTMLEntities.decode("a & b") == "a & b")
    }
}
