# Decisions

Choices that deviate from the build spec, or fill a gap where it is silent.

## D1. Minimum macOS is 15, not 26 (M0)

The development Mac runs macOS 15.7 with Xcode 16.3, which has no macOS 26 SDK. The app
targets macOS 15 so it can be built, run and tested here. Liquid Glass comes for free from
the system toolbar once built with the macOS 26 SDK; no custom glass is drawn anywhere.
Raise `deploymentTarget` in `project.yml` and `platforms` in `Package.swift` after upgrading.

## D2. One `SwiftmailCore` module with folders per area (M0)

`Packages/SwiftmailCore/Sources/{AuthKit,GmailAPI,Store,...}` are folders inside one Swift
module rather than nine targets. The responsibility split from the spec is kept by folder,
and the app still sees only `public` API. This avoids nine sets of `public` cross-module
boilerplate for a personal app; it can be split later without code changes beyond access control.

## D3. Build output lives in `.build/` inside the repo (M0)

`scripts/build.sh` and `test.sh` pass `-derivedDataPath .build/DerivedData`, so all build
products and SwiftPM checkouts sit in one git-ignored folder that is easy to measure and
delete. Every build runs `scripts/disk-check.sh`, which fails below 7 GB free (agreed buffer).

## D4. Signing: Apple Development certificate, manual style, no provisioning profile (M0)

The app is signed with the developer's Apple Development identity (team `QJ7KXRU547`). The
entitlements in use (sandbox, network client/server, user-selected and Downloads files) need
no provisioning profile on macOS, so signing works from the command line without Xcode
account access.

## D5. Commands folder in core (M0)

The spec's `CommandRouter` is pure key-to-command mapping logic, so it lives in
`SwiftmailCore/Sources/Commands` where it is unit tested without UI. The app owns the
`NSEvent` monitor that feeds it.

## D6. Keychain: data protection keychain with a login-keychain fallback (M1)

`KeychainStore` tries the data protection keychain first (where
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` applies). Without a provisioning profile
the app has no keychain access group, so that returns `errSecMissingEntitlement` and the
store falls back to the login keychain, whose items are still limited to this app's signed
identity. Verified in the sandbox with `Swiftmail --keychain-selftest` (debug builds only).

## D7. `Accounts` folder for `AccountManager` and `AccountSession` (M1)

The per-account session actor and the manager that signs accounts in and out don't belong to
any single spec module, so they live in `Sources/Accounts`. Sign-in step 6 confirms Gmail
access with `getProfile` before anything is saved, so a failed probe leaves no Keychain item.

## D8. HTTP seam is `HTTPTransport`, not `URLProtocol` (M1)

`RESTGmailClient` and `OAuthClient` take an `HTTPTransport`. Tests use `StubTransport` to
script 401s, 429s, `Retry-After`, 5xx and batch responses without touching the network.
Offline errors are not retried inside the client; callers keep the work queued until the
network path monitor reports the connection is back.

## D9. First sync also lists every unread inbox thread (M2)

Step 4 adds `threads.list labelIds=INBOX,UNREAD` (metadata, up to 1,000) before drafts, so
the local unread counts, the sidebar and the Dock badge are right from the first sync even
when unread mail is older than the backfill window.

## D10. Inbox and category unread counts are computed locally (M2)

Inbox, category and unified counts come from the local store (`UNREAD` rows of
`thread_labels` joined to `INBOX`), so they move instantly with optimistic actions and need
no extra API calls. User labels, Spam and Drafts show Gmail's own counts from `labels.get`.

## D11. Backfill runs in two exact phases (M2)

Instead of guessing when the 90-day mark is crossed, the backfill lists
`after:<boundary>` (bodies, `format=full`) and then `before:<boundary>` (`format=metadata`),
with the phase, boundary and page token saved in `backfill_cursor`. Threads that became local
while a page was in flight are not overwritten. Older pages beyond the window load on demand
through `before:<oldest row>` when the list is scrolled to its end.

## D12. Debug-only synthetic store for UI and launch checks (M2)

`scripts/preview-db.sh` writes a 30,000-thread synthetic mailbox to `Preview.sqlite` in the
app container using the test target's generator; debug builds open it with
`--database Preview.sqlite`. No fixture data is in the app target, and the real `Mail.sqlite`
is never touched.

## D13. Line length 160 (M2)

SQL inside Swift strings made 140 columns impractical; SwiftLint and SwiftFormat use 160.
