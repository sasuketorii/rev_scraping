<!-- SPDX-License-Identifier: MIT -->
<!-- Source: rev_scraping Phase 9g -->

# Authenticated Scraping Flow

This document shows the Phase 9 authenticated scraping lifecycle. The flow is
human-in-the-loop by design: users authenticate manually, then the system stores
and replays encrypted cookies without exposing cookie values.

## Diagram A — CLI Capture

`rev-stealth auth login` performs AUP enforcement first, then delegates the
headed browser session to `rev-auth`. Cookie capture happens after the user has
completed login manually.

```mermaid
sequenceDiagram
    participant User
    participant CLI as rev-stealth
    participant AUP as AUP enforce
    participant Helper as rev-auth
    participant Browser as obscura headed
    participant CDP as CDP getAllCookies
    participant Store as AuthStore encrypt

    User->>CLI: rev-stealth auth login
    CLI->>AUP: validate auth_allowed target
    AUP-->>CLI: allowed
    CLI->>Helper: spawn rev-auth login
    Helper->>Browser: open headed login URL
    User->>Browser: manual login
    Browser-->>Helper: completion pattern or user confirmation
    Helper->>CDP: getAllCookies
    CDP-->>Helper: cookie metadata and values
    Helper->>Store: encrypt jar with profile-bound AAD
    Store-->>Helper: encrypted blob saved
    Helper-->>CLI: exit 0
    CLI-->>User: JSON envelope without cookie values
```

## Diagram B — MCP Two-Phase Capture

MCP login uses a start/complete split so the server never blocks an agent call
for several minutes while the human signs in. The complete call observes only
the marker and profile metadata.

```mermaid
sequenceDiagram
    participant Agent
    participant MCP as stealth-mcp
    participant AUP as AUP enforce
    participant Helper as rev-auth
    participant Browser as obscura headed
    participant Marker as completion marker
    participant Store as AuthStore metadata

    Agent->>MCP: tools/call auth_login_start
    MCP->>AUP: validate auth_allowed target
    AUP-->>MCP: allowed
    MCP->>Helper: spawn rev-auth with session_token
    Helper->>Browser: open headed login URL
    MCP-->>Agent: session_token and login hint
    Agent->>User: ask user to complete login
    User->>Browser: manual login
    Helper->>Store: save encrypted cookie jar
    Helper->>Marker: write rev-auth-token.complete
    Agent->>MCP: tools/call auth_login_complete
    MCP->>Marker: poll marker file
    Marker-->>MCP: present
    MCP->>Store: read ProfileMeta only
    Store-->>MCP: profile, domains, counts
    MCP-->>Agent: success, cookie_values_returned=false
```

## Diagram C — Spider Replay

`spider --use-auth` loads the encrypted profile, constructs an
`AuthCookieJar`, and applies the captured browser headers to HTTP fetches. When
the browser path is used, the same cookies are injected over CDP.

```mermaid
sequenceDiagram
    participant CLI as rev-stealth spider
    participant Store as AuthStore.load
    participant Jar as AuthCookieJar
    participant HTTP as reqwest::Client
    participant Browser as obscura CDP branch
    participant Host as target host

    CLI->>Store: load profile with auth-domain AAD
    Store-->>CLI: decrypted cookies in process memory
    CLI->>Jar: build replay jar
    CLI->>HTTP: configure UA and Accept-Language replay
    HTTP->>Jar: request cookies for URL
    Jar-->>HTTP: Cookie header names and values
    HTTP->>Host: authenticated request
    Host-->>HTTP: response
    HTTP-->>CLI: HTML response
    CLI-->>Browser: inject cookies when browser fetch is used
    Browser->>Host: authenticated browser navigation
```

See also: [README §14 Authenticated Scraping](../README.md#14-authenticated-scraping-phase-9).
