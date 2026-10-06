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

- [ ] `history.list` paging and record application (added, deleted, labels added/removed)
- [ ] 404 on `messages.get` skipped; historyId written with the last page
- [ ] History 404: `syncing_full`, fresh historyId, metadata re-list, keep bodies, prune vanished threads
- [ ] Sync triggers: 30 s active / 120 s background, activate, wake, network path, after send/action
- [ ] One run per account, rerun flag; label count refresh at most once a minute
- [ ] Tests: each record type, out-of-order/duplicates, 404 message, expiry recovery, randomized server changes
- [h] Human: changes in Gmail web show within 60 s; new mail within 60 s

## M4: Reader

- [ ] Sanitizer (SwiftSoup): removals, on* attrs, js URLs, CSP, cid rewrite, tracker detection
- [ ] Plain text rendering (links, format=flowed), quoted-text collapse (Gmail, Apple, Outlook, plain)
- [ ] Dark mode: simple vs paper card
- [ ] WKWebView pool + pre-warm, JS off, separate content world height script, non-persistent store
- [ ] `swiftmail-cid` scheme handler; content rule lists for remote blocking; link policy
- [ ] Remote images banner, allow once / always (sender or domain), global setting
- [ ] Conversation view: cards, collapse/expand, expand all, header, labels, star
- [ ] Attachments: chips, download on demand, Quick Look, save, drag to Finder
- [ ] Test corpus (~30 synthetic .eml) + EML parser; render tests for every corpus file
- [h] Human: look and feel of real mail

## M5: Actions, offline queue and undo

- [ ] `MailActions` optimistic local changes + `pending_actions` in one transaction
- [ ] `ActionQueue`: drain, threads.modify / batchModify / trash, retries, offline hold, rollback
- [ ] Merge rule: pending changes re-applied over incoming history
- [ ] Undo: queued → delete + restore; sent → inverse action; toast 8 s; Cmd-Z and `z`
- [ ] `CommandRouter` + all single-key shortcuts, menus, toolbar, `?` help sheet
- [ ] Multi-select, bulk actions, drag to label (Option = move), label/move pickers
- [ ] Tests: actions, undo, rollback, offline, shortcut routing
- [h] Human: offline actions apply after reconnect; undo reverses server state

## M6: Compose

- [ ] MIME builder (RFC 5322/2047/2231, structure rules, plain-text from HTML), golden tests
- [ ] Reply/reply-all/forward rules, alias selection, quoting, signatures
- [ ] Editor page + JS bridge, formatting bar, paste cleaning, inline images
- [ ] Compose window: From picker, token fields with autocomplete, subject, attachments (25 MB)
- [ ] Local drafts from first keystroke, reopen on launch; Gmail draft create/update/delete
- [ ] Send: outbox file, held `send` action, undo-send toast, media upload > 5 MB, Outbox mailbox
- [ ] Quit with held messages sends them first (up to 10 s)
- [ ] `mailto:` handling
- [h] Human: reply threads in Gmail web; non-ASCII round trip; 20 MB attachment; quit during undo

## M7: Search

- [ ] Query parser (`from:`, `to:`, `subject:`, `has:attachment`, `is:unread`, free text)
- [ ] Local FTS search as you type; server search via `messages.list q=`
- [ ] Merge results (local first), server-only threads fetched and openable
- [ ] Perf test: 100,000-message synthetic DB under 100 ms
- [h] Human: server-only results open normally

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
