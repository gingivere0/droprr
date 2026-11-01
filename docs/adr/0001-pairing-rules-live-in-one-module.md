# 1. Pairing rules live in one module per platform

Date: 2026-10-31. Status: accepted.

## Context

Every way of pairing (QR, the one code, LAN pairing in both directions, Tailscale pairing, a phone checking in, a browser connecting) changes the saved peers. On Windows those rules were spread through `App.xaml.cs`, `App.Lan.cs`, the receiver, and the Send and Settings windows, and the "is this the same device?" check was written seven slightly different ways. On the Mac and iPhone, each app had its own copy of "add or update the peer that paired". Fixes such as "pairing again never says already paired" had to be made in several places on each platform.

## Decision

- Windows: `src/Droprr.Windows/Peers/` holds the peer model and every rule for adding, updating, matching, and merging peers (`PeerBook`, `PeerMerge`, `PeerList`). Callers load settings, call it, and save. Nothing in `Peers/` may use anything outside the .NET base class library: `tests/Droprr.Windows.Tests` compiles those files directly, so a dependency on WPF, ASP.NET, or the rest of the app breaks the test build.
- Mac and iPhone: `apple/Shared/PeerBook.swift` (`applyPairing`, `repairablePeer`) on `DroprrSettings`, used by both apps.
- Which peer a pairing applies to is one value, `PairTarget` (match, new, update, repair), not a set of flags that could contradict each other.

## Consequences

A new pairing path, or a change to an existing rule, is made in one file per platform and, on Windows, covered by a test that runs on any OS. The Windows and Apple modules use the same names so a rule can be found on both sides.
