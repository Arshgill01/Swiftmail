# Plan

Status legend: `[x]` done and tested, `[ ]` to do, `[h]` needs the human (real account or look and feel).
Automated acceptance criteria must pass before a milestone is committed; human checks are
listed per milestone and tracked here until ticked.

## M0: Project skeleton

- [x] `project.yml` (XcodeGen) with app target, local `SwiftmailCore` package, test scheme
- [x] `scripts/build.sh`, `test.sh`, `lint.sh`, plus `disk-check.sh` (7 GB buffer)
- [x] SwiftFormat and SwiftLint configs
- [x] Empty three-column `NavigationSplitView` window, Settings window shell
- [x] `Config/Secrets.example.xcconfig`, optional include of `Secrets.xcconfig`
- [x] README with Google Cloud setup, `DECISIONS.md`
- [x] Accept: `scripts/test.sh` passes; app launches with three empty columns

## M1: Sign-in

- [x] base64url helper, PKCE (verifier, S256 challenge), random state
- [x] `LoopbackServer` (NWListener on 127.0.0.1, OS port, one shot, 5 min timeout, success page)
- [x] `OAuthClient`: auth URL, code exchange, refresh, revoke; `invalid_grant` mapping
- [x] ID token decoding (`sub`, email, name, picture)
- [x] `KeychainStore` (service `app.swiftmail.oauth`, account `<sub>`) behind a `SecretStore` protocol
- [x] `TokenProvider` actor: refresh 60 s before expiry, shared in-flight refresh, forced refresh
- [x] `SignInFlow`: steps 1 to 8, `getProfile` check, update existing account instead of duplicating
- [x] Minimal `accounts` table + `AccountStore`; add and remove account (revoke, Keychain, rows, files)
- [x] Sidebar account rows; Settings > Accounts add/remove; "needs sign-in" banner
- [x] Tests: PKCE vectors, auth URL, loopback request parsing, token provider refresh sharing, invalid_grant
- [x] Keychain verified inside the sandbox (`Swiftmail --keychain-selftest`, debug builds)
- [h] Human: create the Google Cloud client (README), sign in with two accounts; relaunch stays signed in; remove account revokes

## M2: Store and first sync

- [x] Full schema migration (all tables, FTS5), `AppDatabase` (DatabasePool, WAL); v2 adds sync state columns
- [x] Gmail models; `GmailClient` protocol; `RESTGmailClient` (URLSession, 401 refresh+retry)
- [x] Batch requests (multipart/mixed, ≤ 50 per batch, per-part retry), backoff (2^n + jitter, ≤ 64 s, Retry-After)
- [x] `QuotaBucket` (6,000/min, 2,000 reserve for background), task-local request priority
- [x] `MessageDecoder` (MIME tree, charsets, base64url, attachments, inline parts, RFC 2047/2231)
- [x] `MailWriter`: threads/messages/labels/bodies/attachments, thread_labels union, flags, FTS, contacts
- [x] `SyncEngine.firstSync` steps 1 to 4; backfill steps 5 to 7 (resumable cursor, 90-day full/metadata split, window)
- [x] `AccountSession` owns token provider, client, sync engine; bootstraps first sync + backfill
- [x] Sidebar: unified + per-account mailboxes, nested labels with colors and counts, sync footer
- [x] Thread list (read-only): rows, paging from the store, server paging past the cache, densities, category bar
- [x] `FakeGmailServer`, first-sync/backfill tests, store perf tests on 30,000 threads / 100,000 messages
- [x] Launch to first list render on the synthetic 30k-thread store: 368–419 ms (debug build), budget 500 ms
- [h] Human: inbox within 10 s of sign-in; relaunch under 500 ms (also offline); backfill resumes; scrolling feel

## M3: Incremental sync

- [x] `history.list` paging and record application (added, deleted, labels added/removed), one transaction per page
- [x] 404 on `messages.get` skipped; historyId written with the last page; unknown labels refresh the label list
- [x] History 404: `syncing_full`, fresh historyId, metadata re-list, keep bodies, prune vanished threads (`resync_seen`, migration v3)
- [x] Sync triggers: 30 s active / 120 s background, activate, wake (pause on sleep), network path back; send/action hooks via `triggerSync`
- [x] One run per account with coalesced triggers; label count refresh at most once a minute
- [x] Tests: each record type, duplicates/replays, added-then-deleted, expiry recovery, randomized changes converge, coalescing
- [h] Human: changes in Gmail web show within 60 s; new mail within 60 s

## M4: Reader

- [x] Sanitizer (SwiftSoup): removals, on* attrs, js/vbscript/data URLs, CSS expressions, CSP, cid rewrite, tracker removal
- [x] Plain text rendering (links, format=flowed), quoted-text collapse (Gmail, Apple, Outlook, Yahoo, plain) via JS-free `<details>`
- [x] Dark mode: simple mail follows the system; colored mail on a white paper card
- [x] WKWebView pool + pre-warm, JS off, separate content world measuring script, non-persistent store
- [x] `swiftmail-cid` scheme handler; content rule list blocks http(s); links open outside; link hover bubble
- [x] Remote images banner, load once / always for sender or domain, global setting key
- [x] Conversation view: cards, collapse/expand, newest + unread expanded, header, labels, star display
- [x] Attachments: chips, download on demand, Quick Look, open, save, drag to Finder
- [x] Wide fixed-width mail scales down to fit the card
- [x] Test corpus (32 synthetic .eml) + EML parser; every file renders safely; WebKit test proves no remote loads and no page JS
- [x] Cached thread read under 50 ms on the 30k-thread store (perf test)
- [x] Debug-only `--snapshot` captures the window for visual checks (reviewed light and dark: newsletter, flowed text, Outlook reply, inline images)
- [h] Human: look and feel of real mail

## M5: Actions, offline queue and undo

- [x] `MailActions` optimistic local changes + `pending_actions` in one transaction (star/unread on the newest message)
- [x] `ActionQueue`: drain in order, threads.modify (≤ 5) / batchModify / trash / untrash, backoff retries, offline hold, rollback with a message
- [x] Merge rule: pending changes re-applied over incoming history (`PendingOverlay`)
- [x] Undo: queued → delete + restore; sent → inverse action; 8 s toast; Cmd-Z and `z`
- [x] `CommandRouter` + all single-key shortcuts (local key monitor, never in text fields), menus, toolbar, `?` sheet
- [x] Multi-select (shift/cmd click, `x` with a cursor), hover actions, drag to label (Option = move), drop on Inbox/Starred/Spam/Trash
- [x] Label picker (`l`), move picker (`v`), go to label (`g l`); selection moves to the thread below after removal
- [x] Opening an unread thread marks it read
- [x] Trashed and spam messages no longer keep a thread in other views
- [x] Tests: actions, batching, offline, undo before/after send, rollback (transient and permanent), overlay, shortcut routing
- [h] Human: offline actions apply after reconnect; undo reverses server state; feel of shortcuts and hover actions

## M6: Compose

- [x] MIME builder (RFC 5322/2047/2231, structure rules, plain text from HTML), golden and round-trip tests
- [x] Reply/reply-all/forward rules, alias selection, Gmail quoting, signatures above the quote, forward header + attachments
- [x] Editor page + JS bridge in its own content world (page JS off, CSP), formatting bar, ⌘B/I/U/K, paste cleaning, pasted/dropped images inline
- [x] Compose window: From picker (hidden with one address), token fields with autocomplete, subject, attachments, 25 MB block
- [x] Local drafts from the first keystroke, reopened on launch; Gmail draft create after 2 s, update ≤ every 3 s and on close; discard deletes
- [x] Send: outbox file, held `send` row, "Sending… Undo" toast for the undo delay, media upload > 5 MB, Outbox mailbox with retry
- [x] Quit with held messages sends them first (up to 10 s, "Sending 1 message…")
- [x] `mailto:` handling (To, Cc, Bcc, Subject, Body); drafts from Gmail web open with Edit
- [h] Human: reply threads in Gmail web; non-ASCII round trip; 20 MB attachment; quit during undo

## M7: Search

- [x] Query parser (`from:`, `to:`, `subject:`, `has:attachment`, `is:unread`, `is:starred`, `label:`/`in:`, phrases, free text)
- [x] Local FTS search as you type (60 ms debounce), injection-safe MATCH expressions with prefix matching
- [x] Server search via `messages.list q=` with full Gmail syntax; server-only threads fetched as metadata and openable
- [x] Merge results (local first, no duplicates); tokens and contact suggestions for `from:` and `has:attachment`
- [x] `/` and ⌥⌘F focus search; Escape clears it; offline and signed-out states explained
- [x] Perf test: 100,000-message synthetic DB answers under 100 ms
- [h] Human: server-only results open normally with a real account

## M8: Notifications and polish

- [ ] Notification policy (new, INBOX+UNREAD, Primary, not from self, no first sync, summary > 10)
- [ ] UNUserNotificationCenter: permission after first inbox sync, Archive / Mark as Read actions, open thread
- [ ] Remove delivered notifications when read or archived
- [ ] Dock badge; default mail app button; all Settings
- [ ] Empty and error states, accessibility labels, signposts for every budget
- [h] Human: tick the switch-ready checklist

## Human checks at each milestone

With the real account: compare the inbox with Gmail web, do an action in each app and check
the other, send a reply to yourself, and check notifications.
