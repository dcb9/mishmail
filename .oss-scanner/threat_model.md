# Threat model

## What this project does and where untrusted input enters

MishMail is a local-first macOS email client (SwiftUI/AppKit, macOS 14+).
It syncs Gmail through the Gmail API into a local SQLCipher database and
renders mail on the device. Untrusted input enters at these points:

- Email content: MIME bodies, headers, HTML mail, and attachments. Parsed
  in `Sources/MishMail/Gmail` (`MessageParsing.swift` especially) and
  rendered through `Sources/MishMail/Support/HTMLBody*.swift` into a
  locked-down WKWebView.
- Gmail API responses. The API transport is trusted; the message content
  it carries is not.
- `mailto:` and other deep links (`Sources/MishMail/Store/
  DeepLinkThreadResolver.swift`, `Support/DefaultMailClient.swift`).
- Attachments saved to disk or opened through QuickLook, and files dropped
  into the compose window.
- The local MCP server (`Sources/MishMail/MCP`). It is an HTTP listener on
  127.0.0.1 only, gated by a bearer token compared in constant time
  (`Sources/MishMail/Support/MCPServerSecurity.swift`). Any local process
  — or a web page making local requests — can reach the port.
- The OAuth loopback listener during sign-in
  (`Sources/MishMail/Auth/OAuth.swift`).
- The self-update path (`Sources/MishMail/Support/UpdateChecker.swift`,
  `UpdateInstaller.swift`) plus the relauncher helper
  (`Sources/MishMailRelauncher`), which removes the quarantine attribute
  from a downloaded update.
- LLM provider features (Ask Mish, summaries, drafts). Email content is
  sent to a model that can call tools, so prompt injection through email
  is in scope.

## Components that matter most / least

Matter most:

- HTML sanitization and the WebView policy: `HTMLBodyCSP.swift`,
  `HTMLBodyDocument.swift`, `RemoteImagePolicy.swift`,
  `HTMLRemoteImageBlocker.swift`, `CIDImageInliner.swift`, `Markdown.swift`,
  `HTMLEntities.swift`. A crafted message that runs script, navigates the
  WebView, loads remote content, or reads local files is the top concern.
- OAuth/PKCE and token storage: `Auth/OAuth.swift`,
  `Support/Keychain.swift`, `Gmail/AccessTokenCache.swift`,
  `Support/LLMOAuth.swift`.
- The MCP server: `MCP/MCPServer.swift`, `MCPHTTP.swift`, `MCPRouter.swift`,
  `MCPTools.swift`. Check what an unauthenticated or cross-origin local
  request can make it do.
- The SQL layer: `Store/*.swift` builds queries through GRDB. Look for
  string-built SQL — `SearchFTS.swift` and `SearchQuery.swift` first.
- Update verification and the relauncher: `UpdateInstaller.swift`,
  `Relaunch.swift`, `Quarantine.swift`. A bypass here installs attacker
  code, and the relauncher runs unsandboxed by design.

Matter least: SwiftUI layout, theming, and onboarding code — in scope
only where they create security-relevant behavior.

## How to exercise it

`Tests/MishMailTests` holds unit tests over the non-UI core: parsers,
MIME, the database schema, sync derivation, and the MCP router. It
compiles the same `Sources/MishMail/{Gmail,Store,Auth,MCP,Support}`
directories without an app host.

Important for the scan container: the app builds only on macOS with
xcodebuild. There is no Xcode on Linux. Use `swiftc -parse <file>` to
syntax-check individual files, and compile small standalone reproducers
for Foundation-only logic. A checkout of GRDB at the pinned version is at
`/deps/GRDB`. Python helpers live in `scripts/`; `sqlite3` is installed
for inspecting the schema in `Store/Database.swift`.

## How to rate severity

- Critical: remote content executing code or exfiltrating data without
  user action. Examples: an HTML-mail escape to the network or the
  filesystem, RCE through the update path, MCP server actions reachable
  without the bearer token from another local process or a web page.
- High: OAuth or token theft, Keychain exposure, stored content that runs
  script inside the WebView, path traversal in attachment or snippet
  import handling, SQL injection reachable from message content or user
  input.
- Medium: navigation-policy or CSP weakenings that need user interaction,
  remote-image policy bypass (privacy/tracking), denial of service on
  malformed MIME.
- Low: issues that need an already-compromised local process, or purely
  cosmetic findings.

## Anything to leave alone

- Do not report the missing app sandbox on `MishMailRelauncher`. It is
  intentionally unsandboxed so it can remove `com.apple.quarantine` from
  updates; the reasons are documented in `project.yml` and the
  entitlements file.
- Debug and Release builds are two distinct apps on purpose
  (`MishMail Debug`, `dev.ronboger.MishMail.debug`). Differences between
  them are intentional.
- `Support/DemoSeed.swift` only acts when the `MISHMAIL_DEMO=1`
  environment variable is set.
