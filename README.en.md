# Codex Lid

[日本語 README](README.md)

Codex Lid is an experimental macOS menu-bar app that keeps local Codex runs and builds working for a **strictly limited time** after a MacBook lid is closed.

This is an unofficial community project and is not affiliated with OpenAI. It does not connect to the Codex API or control Codex itself.

> [!WARNING]
> This app temporarily disables sleep for the whole Mac, not just Codex. Never put a closed, awake Mac in a bag, case, bed, or any place that traps heat.

## Highlights

- A recommended 5-minute first test, plus 30-minute, 1-hour, and 2-hour limits
- AC power required by default
- Optional battery operation with an automatic stop at 25%
- Automatic stop on low-power mode, serious thermal pressure, AC disconnect, or timeout
- Fail-closed behavior when power source or battery percentage cannot be read safely
- A time-bounded root monitor independent of the UI and a second failsafe process for crash recovery
- The complete app and worker are installed root-owned under `/Library/Application Support/Codex Lid`, so user-writable code is never elevated
- No persistent sudoers entry, running privileged daemon, kernel extension, networking, or analytics
- Refuses to start when another tool already owns the system-wide sleep override

## Requirements

- macOS 13 or later
- Apple Silicon or Intel Mac
- Xcode Command Line Tools (`xcrun swiftc`)
- An account that can approve the administrator prompt when a session starts

There is no Developer ID-signed and notarized binary release yet. Build locally from source:

```bash
git clone https://github.com/fukuroworksai01-stack/codex-lid.git
cd codex-lid
./scripts/test.sh
./scripts/install.sh
```

The app is first built at `dist/Codex Lid.app`. The installer places the complete verified bundle at `/Library/Application Support/Codex Lid/Codex Lid.app` as root-owned files and makes it available at `/Applications/Codex Lid.app`. It therefore requests an administrator password. Quit an installed copy before replacing it:

```bash
./scripts/install.sh --replace
```

## Use

1. Launch `/Applications/Codex Lid.app`.
2. Connect power and put the Mac on a hard, flat, ventilated surface.
3. Choose the 5-minute test from the moon icon in the menu bar.
4. Review the warning and approve the macOS administrator prompt.
5. Choose **Lock and turn off display**, then close the lid.
6. Reopen the lid and verify both the task result and return to normal sleep.

To stop early, choose **Stop and restore normal sleep**. The independent monitor remains active until the deadline even if the menu-bar UI quits.

## Recovery

Check the system-wide state with:

```bash
pmset -g | grep SleepDisabled
```

If `SleepDisabled 1` remains after the session should have ended, restore normal behavior with the following command. The protected worker waits for any in-flight setting operation before resetting. This also clears an override owned by another sleep-prevention tool.

```bash
sudo "/Library/Application Support/Codex Lid/Codex Lid.app/Contents/Resources/CodexLidWorker" --set-sleep 0
```

If the protected worker cannot run, use `sudo pmset -a disablesleep 0` as the last-resort fallback.

## Important limitations

- `pmset disablesleep` is an undocumented macOS setting and may change. Run the 5-minute test after every major OS update.
- Codex can still pause for approval, input, networking, or another external dependency.
- Fanless MacBook Air models are not suitable for sustained high-load work in a closed-lid configuration.
- Compilation, self-tests, and app launch have been checked on an M1 MacBook Air. Test your exact hardware and OS combination before real work.

See [the architecture and threat model](docs/ARCHITECTURE.md), [security policy](SECURITY.md), and [contribution guide](CONTRIBUTING.md).

## Uninstall

Stop any active session, quit Codex Lid, and run:

```bash
./scripts/uninstall.sh
```

The protected app and its `/Applications` launcher are removed. A valid legacy copy under `~/Applications` is moved to Trash. No sudoers entry or running daemon is left behind. After uninstall completes, you may delete `/private/tmp/codex-lid-$(id -u)` if you no longer need its diagnostics.

## License

[MIT License](LICENSE)
