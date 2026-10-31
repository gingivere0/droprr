# 2. The protocol is the seam between platforms

Date: 2026-10-31. Status: accepted.

## Context

Droprr is three codebases: C# (Windows), Swift (Mac and iPhone), and JavaScript (the browser pages, the hidden host page, and the relay). Code can't be shared between C# and Swift, so keeping behavior identical depends on something else.

## Decision

`docs/PROTOCOL.md` is the contract between platforms. Rules that every platform applies (pairing, merging, which path a send takes) are written there once, and each platform implements them in its own pairing module (see ADR 1) under the same names. Within one language, code is shared rather than copied: the two browser pages share `site/common.js` and `site/app.css`, and the computers serve them along with `site/rtc.js`.

## Consequences

Don't propose a shared cross-language library or code generation for the apps; the cost isn't worth it at this size. When a rule changes, change PROTOCOL.md, then each platform's module. The test vectors in PROTOCOL.md (for example, the LAN pairing code) are the cross-platform check.
