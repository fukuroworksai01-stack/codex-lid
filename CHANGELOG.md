# Changelog

All notable changes are documented here.

## [Unreleased]

## [0.2.2] - 2026-08-30

- Reported process-enumeration failures explicitly instead of treating them as no running Codex Lid process in restricted environments.

## [0.2.1] - 2026-08-30

- Clarified that Codex Lid controls macOS sleep but does not maintain Codex Remote transport.
- Added an advisory external-display check and Remote-specific guidance before timed sessions.
- Added first-launch guidance for the supported lid-open Remote workflow.
- Displayed the running app version, path, and protected-install status in the menu.
- Added a read-only diagnostic script for installed copies, power, sleep, and display state.
- Documented OpenAI's external-display requirement for closed-lid Remote use.

## [0.2.0] - 2026-08-30

- Hardened the user/root runtime boundary with exact paths, no-follow opens, descriptor-based directory validation, and link-count checks.
- Installed the complete app bundle in a root-owned protected directory; neither the UI nor its worker can be replaced by an unprivileged user before elevation.
- Removed inherited ACLs during installation and rejected protected paths writable by the login user.
- Cleared and rejected set-user-ID/set-group-ID bits on protected executables.
- Removed root log redirection into a user-controlled directory.
- Cleared the elevated process environment and disabled privileged actions from unprotected app copies.
- Moved root-owned coordination files from `/var/tmp` to `/var/run` and prevented lock descriptor inheritance.
- Enforced session deadlines with `mach_continuous_time`, independent of wall-clock changes.
- Added a failsafe readiness acknowledgement and made failsafe diagnostics nonfatal.
- Serialized power-setting writes with an exec-inherited lock so crash recovery cannot be overtaken by an orphaned enable command.
- Reset immediately if the independent failsafe disappears during an active session.
- Made user-controlled runtime file opens non-blocking so special files cannot stall the safety loop.
- Rebuilt the generated app bundle from a clean directory to prevent stale files from surviving between builds.
- Kept ownership and issued cleanup when `SleepDisabled` output becomes absent or unreadable after enable.
- Changed unknown power-state handling to fail closed.
- Removed watchdog signaling that could target a reused PID.
- Ensured a partially successful `pmset` enable is still cleaned up when verification fails.
- Rejected stale status/PID combinations in the menu-bar UI.
- Added bilingual documentation, security policy, architecture notes, CI, and an MIT license.

[Unreleased]: https://github.com/fukuroworksai01-stack/codex-lid/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/fukuroworksai01-stack/codex-lid/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/fukuroworksai01-stack/codex-lid/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/fukuroworksai01-stack/codex-lid/tree/v0.2.0
