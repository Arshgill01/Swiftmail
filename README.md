# Swiftmail

A personal, native SwiftUI Gmail client for macOS. Local first: the UI reads only
from a local SQLite store, and Gmail sync happens in the background.

- Build: `scripts/build.sh` (generates `Swiftmail.xcodeproj` with XcodeGen, builds into `.build/`)
- Test: `scripts/test.sh` (lint, build, all unit tests)
- Lint: `scripts/lint.sh` (`--fix` to auto-format)
- Disk guard: `scripts/disk-check.sh` fails when less than 7 GB is free (`MIN_FREE_GB` overrides)

Debug-build helpers (never in release builds):

- `scripts/preview-db.sh` writes a synthetic 30,000-thread mailbox plus the test corpus to
  `Preview.sqlite` in the app container; launch with `--database Preview.sqlite` to use it.
- `--snapshot <name.png> [--select n] [--search text] [--commands archive,reply]
  [--snapshot-window compose] [--appearance dark|light]` renders a window to the container's
  tmp folder and quits.
- `--keychain-selftest` checks Keychain access inside the sandbox.

Requirements: macOS 15 or later on Apple silicon, Xcode 16.3 or later,
`brew install xcodegen swiftlint swiftformat`.

See `PLAN.md` for progress and `DECISIONS.md` for choices that differ from or fill
gaps in the build spec.

## Google Cloud setup (one time, about 10 minutes)

The app signs in through your own Google Cloud project, published "In production"
but left unverified. That gives permanent refresh tokens without Google's paid
restricted-scope review, which is fine for personal use (up to 100 users).

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and create a project named `Swiftmail`. No billing account is needed.
2. APIs & Services > Library: enable the **Gmail API**. Also enable the **People API** now if you want contact autocomplete from Google Contacts later.
3. Google Auth Platform > Branding: set the app name and your email as the support and developer contact.
4. Audience: choose **External**.
5. Data Access: add the scopes listed below. Google will warn that some are restricted and need verification. For personal use, click through; you do not submit for verification.
6. Clients: create an OAuth client of type **Desktop app**. Copy the client ID and client secret into `Config/Secrets.xcconfig` (git-ignored; start from `Config/Secrets.example.xcconfig`). The secret of a Desktop client is not truly secret, but keep it out of git anyway.
7. Audience: click **Publish app** and confirm the status is **In production**. Do not leave it in Testing: in Testing, Google expires the refresh token after 7 days and you would have to sign in every week.
8. At first sign-in, Google shows "Google hasn't verified this app". Click Advanced, then Go to Swiftmail (unsafe), then allow access. This happens once per account.

### Scopes

| Scope | Used for |
| --- | --- |
| `openid`, `email`, `profile` | Account identity, name and avatar |
| `https://www.googleapis.com/auth/gmail.modify` | Read, send, drafts, labels, archive, trash, spam |
| `https://www.googleapis.com/auth/gmail.settings.basic` | Send-as aliases and their signatures |

Do not request `https://mail.google.com/`.

### Known limits

- Google Workspace (work or school) accounts may block unverified apps. Then the admin must allow this client ID.
- A refresh token unused for 6 months expires. Changing the Google password can also revoke tokens with mail scopes. Both cases show a "needs sign-in" banner.

## Layout

```
App/                      entry point, windows, menus, app state
Features/                 SwiftUI feature modules (Sidebar, ThreadList, Reader, Compose, Search, Settings)
Packages/SwiftmailCore/   local package, no UI: AuthKit, GmailAPI, Store, SyncEngine,
                          ActionQueue, MIME, Rendering, Search, Notifications, Commands
Resources/ComposeEditor/  bundled compose editor HTML, CSS, JS
TestCorpus/emails/        synthetic .eml fixtures (tests only)
scripts/                  build.sh, test.sh, lint.sh, disk-check.sh
```
