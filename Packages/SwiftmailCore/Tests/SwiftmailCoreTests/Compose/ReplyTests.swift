import Foundation
@testable import SwiftmailCore
import Testing

struct ReplyTests {
    let aliases = [
        ReplyBuilder.Alias(email: "me@example.com", name: "Me", signatureHTML: "Me<br>Example Inc.", isDefault: true),
        ReplyBuilder.Alias(email: "me@work.example", name: "Me", signatureHTML: "Work sig", isDefault: false),
    ]

    func original(
        from: String = "Alex <alex@example.com>",
        to: String = "me@example.com, bo@example.com",
        cc: String = "cy@example.com, me@work.example",
        replyTo: String = "",
        subject: String = "Plans"
    ) -> ReplyBuilder.Original {
        ReplyBuilder.Original(
            from: EmailAddress.parse(from)!, replyTo: EmailAddress.parseList(replyTo), to: EmailAddress.parseList(to),
            cc: EmailAddress.parseList(cc), subject: subject, date: Date(timeIntervalSince1970: 1_791_300_660),
            messageID: "<orig@example.com>", references: "<root@example.com>", threadID: "t1", quotableHTML: "<div>Original body</div>"
        )
    }

    @Test func replyGoesToSenderOrReplyTo() {
        let state = ReplyBuilder.make(.reply, original: original(), accountID: "a", aliases: aliases)
        #expect(state.to.map(\.email) == ["alex@example.com"])
        #expect(state.cc.isEmpty)
        let withReplyTo = ReplyBuilder.make(.reply, original: original(replyTo: "list@example.com"), accountID: "a", aliases: aliases)
        #expect(withReplyTo.to.map(\.email) == ["list@example.com"])
    }

    @Test func replyAllDropsOwnAddressesAndDuplicates() {
        let state = ReplyBuilder.make(.replyAll, original: original(to: "me@example.com, bo@example.com, alex@example.com"), accountID: "a", aliases: aliases)
        #expect(state.to.map(\.email) == ["alex@example.com", "bo@example.com"])
        #expect(state.cc.map(\.email) == ["cy@example.com"])
        #expect(state.showCcBcc)
    }

    @Test func replyToMyOwnMessageGoesToItsRecipients() {
        let state = ReplyBuilder.make(.reply, original: original(from: "Me <me@example.com>", to: "bo@example.com"), accountID: "a", aliases: aliases)
        #expect(state.to.map(\.email) == ["bo@example.com"])
    }

    @Test func aliasFollowsTheAddressTheOriginalWasSentTo() {
        let toWork = ReplyBuilder.make(.reply, original: original(to: "me@work.example", cc: ""), accountID: "a", aliases: aliases)
        #expect(toWork.from == "me@work.example")
        #expect(toWork.bodyHTML.contains("Work sig"))
        let toNone = ReplyBuilder.make(.reply, original: original(to: "list@example.com", cc: ""), accountID: "a", aliases: aliases)
        #expect(toNone.from == "me@example.com")
    }

    @Test func subjectsAndThreadingHeaders() {
        #expect(ReplyBuilder.prefixed("Plans", "Re: ", existing: ["re:"]) == "Re: Plans")
        #expect(ReplyBuilder.prefixed("RE: Plans", "Re: ", existing: ["re:"]) == "RE: Plans")
        #expect(ReplyBuilder.prefixed("Fw: x", "Fwd: ", existing: ["fwd:", "fw:"]) == "Fw: x")
        let state = ReplyBuilder.make(.reply, original: original(), accountID: "a", aliases: aliases)
        #expect(state.subject == "Re: Plans")
        #expect(state.threadID == "t1")
        #expect(state.inReplyTo == "<orig@example.com>")
        #expect(state.references == "<root@example.com> <orig@example.com>")
    }

    @Test func gmailStyleQuoteWithSignatureAbove() {
        let state = ReplyBuilder.make(.reply, original: original(), accountID: "a", aliases: aliases)
        let html = state.bodyHTML
        let signature = html.range(of: "gmail_signature\"")
        let quote = html.range(of: "class=\"gmail_quote\"")
        #expect(signature != nil && quote != nil)
        if let signature, let quote {
            #expect(signature.lowerBound < quote.lowerBound)
        }
        #expect(html.contains("wrote:<br></div><blockquote class=\"gmail_quote\""))
        #expect(html.contains("On ") && html.contains(", Alex &lt;alex@example.com&gt; wrote:"))
        #expect(html.contains("<div>Original body</div>"))
    }

    @Test func forwardHasGmailHeaderAndNoThreading() {
        let state = ReplyBuilder.make(.forward, original: original(), accountID: "a", aliases: aliases)
        #expect(state.subject == "Fwd: Plans")
        #expect(state.to.isEmpty)
        #expect(state.threadID == nil && state.inReplyTo == nil)
        #expect(state.bodyHTML.contains("---------- Forwarded message ---------"))
        #expect(state.bodyHTML.contains("Subject: Plans<br>"))
        #expect(state.bodyHTML.contains("Cc: cy@example.com, me@work.example<br>"))
    }

    @Test func quotableStripsActiveAndRemoteContent() {
        let html = HTMLSanitizer.quotable(html: "<p onclick='x()'>Hi<img src='https://t.example/p.gif'><script>x()</script></p>", plain: nil)
        #expect(html.contains("Hi"))
        #expect(!html.contains("onclick") && !html.contains("script") && !html.contains("t.example"))
        #expect(HTMLSanitizer.quotable(html: nil, plain: "a <b>\nc") == "<div dir=\"ltr\">a &lt;b&gt;<br>c</div>")
    }

    @Test func validation() {
        var state = ComposeState(accountID: "a", from: "me@example.com")
        #expect(state.validationError() != nil)
        state.to = [EmailAddress(email: "bad-address")]
        #expect(state.validationError()?.contains("isn't a valid") == true)
        state.to = [EmailAddress(email: "ok@example.com")]
        #expect(state.validationError() == nil)
        state.attachments = [ComposeAttachment(filename: "big", mimeType: "x", size: 26 * 1024 * 1024, path: "x")]
        #expect(state.validationError()?.contains("25 MB") == true)
    }
}
