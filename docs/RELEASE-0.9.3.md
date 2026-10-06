# Aural 0.9.3 — keep running in the menu bar

Closing the last Aural window with the red close button or Command-W now removes its Dock icon while the equalizer and headphones menu keep running. Show Aural reopens the main window and restores Dock presence. The preset library, About, and update windows use the same presentation path. Open or minimized app windows keep Dock access; menus, popovers, and sheets do not independently keep it visible.

Quit Aural and Command-Q still stop processing and exit completely. Audio shutdown now belongs to the application delegate instead of the main view, so cleanup remains available after the main window closes. Window tracking observes AppKit notifications without replacing SwiftUI's window delegates. Settings and DSP behavior are unchanged.

## Verification

- Full DSP sanitizer, Swift parser/editor/preset, Swift/C bridge, and window-lifecycle suites passed.
- New deterministic AppKit-notification tests cover unrelated windows, final close, multiple scenes, minimized windows, retained-window reopening, simultaneous closes, and deferred close/reopen races. These tests inject activation-policy changes and do not start audio or display windows.
- Universal arm64/x86_64 packaging, strict ad-hoc signature verification, and DMG verification passed. The installed executable matches the package.
- Native checks on Apple silicon confirmed repeated close/reopen with the same process and active output meter, Command-W with Library still open, Library's Done dismissal, minimized-window recovery, and full Quit from Library after closing the main window. Read-only process inspection confirmed regular versus accessory activation policy at each transition.
- Saved settings remained byte-identical to the pre-install backup. Native automation did not directly exercise the status-item menu; its window commands use the shared presentation helper.

The intermittent Core Audio startup stall documented in earlier versions remains unresolved. It did not recur during these checks. Intel is cross-compiled, not runtime-tested. This local build is ad-hoc signed; no GitHub release was published for this change.
