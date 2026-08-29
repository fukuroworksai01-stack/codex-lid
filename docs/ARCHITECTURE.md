# Architecture and threat model

Codex Lid deliberately avoids installing a daemon or editing sudoers. Each timed session is authorized separately through the standard macOS administrator prompt.

## Process and privilege boundary

```text
Menu-bar app (login user, root-owned protected bundle)
  ├─ writes stop.request (0600) in a per-user runtime directory
  └─ one administrator prompt starts a fixed protected path
       └─ worker (root-owned file, bounded deadline)
            ├─ owns the session lock and calls pmset
            └─ starts failsafe (root)
                 └─ restores pmset if the worker dies
```

The build embeds the worker in the app bundle. `scripts/install.sh` verifies the tested app, stages the complete bundle under `/Library/Application Support/Codex Lid`, removes inherited ACLs, makes it `root:wheel` and non-writable by group/other, verifies its signature and worker SHA-256 hash, and then replaces the installed bundle. `/Applications/Codex Lid.app` is only a launcher link to that protected copy. The menu-bar app refuses to start a session unless its own executable and the worker resolve to their fixed protected paths and are not writable by the login user. Both processes verify the protected directory chain, ownership, file type, link count, and write permissions before elevation or sleep control.

The app constructs a fixed command from validated numeric, UUID, and exact-path arguments. It starts the privileged process with a cleared environment and a fixed `PATH`. Root output is discarded to `/dev/null`; it is never redirected to a user-selected path. The protected executable is a file on disk, not a launch daemon or continuously running helper. The emergency-reset action is also unavailable from an unprotected build.

## Runtime data

The login-user side uses `/private/tmp/codex-lid-<uid>` with mode `0700`:

- `status.json` is diagnostics for the menu-bar UI. It is not trusted for a safety decision.
- `stop.request` contains the active session UUID and must be a single-link regular file owned by the login user.

The root worker opens the runtime directory with `O_DIRECTORY`, `O_NOFOLLOW`, and `O_CLOEXEC`, verifies its owner and mode with `fstat`, and accesses the two exact filenames relative to that descriptor. Status writes reject symlinks and multi-link files.

Root-only coordination files live in `/var/run`:

- `com.fukuroworks.codexlid.lock` prevents overlapping sessions.
- `com.fukuroworks.codexlid.power.lock` serializes every Codex Lid `pmset` write. The lock descriptor is deliberately inherited by the spawned `pmset` process, so a reset cannot overtake an orphaned enable command.
- `com.fukuroworks.codexlid.active` binds a failsafe to one UUID. Its UUID is readable by the UI, but only root can modify the file.
- `com.fukuroworks.codexlid.ready` is a short-lived acknowledgement. The worker does not change `pmset` until the failsafe has completed its safety-critical initialization.

No credentials or Codex task contents are written by Codex Lid.

## Session lifecycle

1. The UI rejects a start if system-wide sleep is already disabled.
2. The user approves an administrator prompt for one bounded worker process.
3. The worker validates its own protected path, power state, battery percentage, and thermal state; then it takes an exclusive lock and records the active UUID.
4. The failsafe validates the protected path and root coordination state, then writes a ready acknowledgement. Its diagnostic-directory access is optional, so loss of user-owned diagnostics cannot disable recovery.
5. Only after receiving that acknowledgement does the worker enable `pmset -a disablesleep 1`. It takes the power-operation lock before spawning `pmset`; the child inherits that lock until the command has fully exited.
6. Every five seconds, the worker checks a boot-relative `mach_continuous_time` deadline, stop request, AC/battery state, low-power mode, thermal state, and the current sleep setting.
7. On every normal exit path after enable, the worker attempts and verifies `pmset -a disablesleep 0`. A reset waits behind any earlier enable command, including one orphaned by worker termination.
8. If the worker dies, the failsafe performs the same ordered reset. If the failsafe itself disappears while the worker is active, the worker resets immediately. At the monotonic deadline the failsafe resets the setting without signaling a PID that might have been reused.

The menu-bar process may quit without ending a session. The root worker and failsafe have null standard streams and remain independent of the UI.

## Threat model

Defended cases include:

- a symlink or substituted file in the per-user runtime directory
- replacement of either executable by an unprivileged user after installation
- a path argument outside the exact runtime filenames
- two simultaneous Codex Lid sessions
- a stale UI status file whose PID has been reused
- worker termination, UI termination, AC removal, low battery, unreadable power state, and serious thermal pressure
- worker termination while its `pmset` enable subprocess is still running
- wall-clock changes during a session
- failure or removal of the diagnostic directory after the failsafe starts
- accidental inheritance of the root session lock by the failsafe

Out of scope:

- an attacker who already has root access
- a compromised source tree or build process at the moment the user intentionally installs it with administrator privileges
- hardware, firmware, or macOS failures that prevent the reset command from running
- guaranteeing that Codex itself will not pause for input or approval

## Known tradeoffs

- `disablesleep` is not documented in the `pmset(1)` manual and may change across macOS releases.
- The fallback is time-bounded with a monotonic clock, not transactional: a kernel panic or total power failure can interrupt all user-space cleanup. Users should verify the state after abnormal shutdown.
- PID reuse can delay crash detection until the session deadline, but the failsafe never sends a signal to that PID.
- Because `disablesleep` is a shared global setting, another tool changing it during an active session cannot be attributed reliably. Codex Lid avoids starting when it is already enabled, but a later race may still cause one tool to clear another tool's override.
- Status JSON is intentionally non-authoritative. Losing it can reduce UI visibility without disabling the worker's independent safety checks.
- The protected app remains installed on disk until `scripts/uninstall.sh` is run, but no component is registered or launched as a daemon.
- The project currently uses ad-hoc local signing. Public binary distribution should wait for Developer ID signing, notarization, and broader hardware coverage.
