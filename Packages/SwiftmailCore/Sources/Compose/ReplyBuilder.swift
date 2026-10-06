import Foundation

/// Gmail's reply, reply-all and forward rules: recipients, alias choice, subject
/// prefixes, threading headers, signature placement and quoting.
public enum ReplyBuilder {
    public struct Alias: Sendable, Equatable {
        public let email: String
        public let name: String?
        public let signatureHTML: String?
        public let isDefault: Bool

        public init(email: String, name: String?, signatureHTML: String?, isDefault: Bool) {
            self.email = email
            self.name = name
            self.signatureHTML = signatureHTML
            self.isDefault = isDefault
        }
    }

    public struct Original: Sendable {
        public var from: EmailAddress
        public var replyTo: [EmailAddress]
        public var to: [EmailAddress]
        public var cc: [EmailAddress]
        public var subject: String
        public var date: Date
        public var messageID: String?
        public var references: String?
        public var threadID: String
        /// Already cleaned for quoting (`HTMLSanitizer.quotable`).
        public var quotableHTML: String

        public init(
            from: EmailAddress, replyTo: [EmailAddress], to: [EmailAddress], cc: [EmailAddress], subject: String, date: Date,
            messageID: String?, references: String?, threadID: String, quotableHTML: String
        ) {
            self.from = from
            self.replyTo = replyTo
            self.to = to
            self.cc = cc
            self.subject = subject
            self.date = date
            self.messageID = messageID
            self.references = references
            self.threadID = threadID
            self.quotableHTML = quotableHTML
        }
    }

    public static func make(_ mode: ComposeMode, original: Original, accountID: String, aliases: [Alias]) -> ComposeState {
        let own = Set(aliases.map { $0.email.lowercased() })
        let alias = chooseAlias(original: original, aliases: aliases)
        var state = ComposeState(accountID: accountID, from: alias?.email ?? aliases.first?.email ?? "")
        state.mode = mode
        let sentByMe = own.contains(original.from.email.lowercased())
        switch mode {
        case .reply:
            state.to = sentByMe ? original.to : (original.replyTo.isEmpty ? [original.from] : original.replyTo)
        case .replyAll:
            let primary = sentByMe ? original.to : (original.replyTo.isEmpty ? [original.from] : original.replyTo) + original.to
            state.to = dedupe(primary, excluding: own)
            state.cc = dedupe(original.cc, excluding: own.union(state.to.map { $0.email.lowercased() }))
        case .forward, .new:
            break
        }
        if mode == .reply {
            state.to = dedupe(state.to, excluding: sentByMe ? [] : own)
        }
        state.subject = mode == .forward ? prefixed(original.subject, "Fwd: ", existing: ["fwd:", "fw:"]) : prefixed(
            original.subject,
            "Re: ",
            existing: ["re:"]
        )
        if mode != .forward {
            state.threadID = original.threadID
            state.inReplyTo = original.messageID
            state.references = [original.references, original.messageID].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " ")
        }
        state.showCcBcc = !state.cc.isEmpty
        state.bodyHTML = body(mode: mode, original: original, signature: alias?.signatureHTML)
        return state
    }

    /// The alias the original was sent to, otherwise the default alias.
    public static func chooseAlias(original: Original, aliases: [Alias]) -> Alias? {
        let recipients = Set((original.to + original.cc).map { $0.email.lowercased() })
        return aliases.first { recipients.contains($0.email.lowercased()) } ?? aliases.first(where: \.isDefault) ?? aliases.first
    }

    static func dedupe(_ addresses: [EmailAddress], excluding: Set<String>) -> [EmailAddress] {
        var seen = excluding
        return addresses.filter { seen.insert($0.email.lowercased()).inserted }
    }

    /// Adds "Re: " or "Fwd: " unless the subject already starts with it, in any case.
    public static func prefixed(_ subject: String, _ prefix: String, existing: [String]) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if existing.contains(where: { trimmed.lowercased().hasPrefix($0) }) {
            return trimmed
        }
        return prefix + trimmed
    }

    // MARK: Body

    public static func body(mode: ComposeMode, original: Original?, signature: String?) -> String {
        var html = "<div dir=\"ltr\"><br></div>"
        if let signature, !signature.isEmpty {
            html += signatureBlock(signature)
        }
        guard let original, mode != .new else { return html }
        if mode == .forward {
            html += "<br>" + forwardBlock(original)
        } else {
            html += "<br>" + quoteBlock(original)
        }
        return html
    }

    /// Gmail's signature wrapper; the editor swaps its contents when the alias changes.
    public static func signatureBlock(_ signature: String) -> String {
        "<div dir=\"ltr\" class=\"gmail_signature_prefix\">-- </div>"
            + "<div dir=\"ltr\" class=\"gmail_signature\" data-smartmail=\"gmail_signature\">\(signature)</div>"
    }

    static func quoteBlock(_ original: Original) -> String {
        """
        <div class="gmail_quote"><div dir="ltr" class="gmail_attr">\(escape(attribution(original))) wrote:<br></div>\
        <blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">\
        \(original.quotableHTML)</blockquote></div>
        """
    }

    static func forwardBlock(_ original: Original) -> String {
        var header = "---------- Forwarded message ---------<br>"
        header += "From: <strong class=\"gmail_sendername\" dir=\"auto\">\(escape(original.from.name ?? original.from.email))</strong> "
        header += "<span dir=\"auto\">&lt;\(escape(original.from.email))&gt;</span><br>"
        header += "Date: \(escape(gmailDate(original.date)))<br>"
        header += "Subject: \(escape(original.subject))<br>"
        header += "To: \(escape(original.to.map(display).joined(separator: ", ")))<br>"
        if !original.cc.isEmpty {
            header += "Cc: \(escape(original.cc.map(display).joined(separator: ", ")))<br>"
        }
        return "<div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">\(header)</div><br><br>\(original.quotableHTML)</div>"
    }

    /// "On Tue, 6 Oct 2026 at 13:31, Name <email>"
    public static func attribution(_ original: Original) -> String {
        "On \(gmailDate(original.date)), \(display(original.from))"
    }

    static func gmailDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }

    static func display(_ address: EmailAddress) -> String {
        address.name.map { "\($0) <\(address.email)>" } ?? address.email
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
