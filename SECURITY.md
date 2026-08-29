# Security policy

Codex Lid changes a system-wide power setting with administrator privileges. Please treat any unexpected command execution, path handling, privilege-boundary bypass, or failure to restore normal sleep as security-sensitive.

## Supported versions

Until the first stable release, only the latest commit on `main` is supported.

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** form in the Security tab of this repository. Do not publish exploit details, private data, or a proof of concept in a public issue.

Include:

- macOS version and Mac model
- Codex Lid commit or version
- whether AC or battery mode was selected
- minimal reproduction steps
- the output of `pmset -g | grep SleepDisabled`, with unrelated details removed
- impact and any safe workaround you found

For an immediate local safety concern, restore normal sleep first:

```bash
sudo "/Library/Application Support/Codex Lid/Codex Lid.app/Contents/Resources/CodexLidWorker" --set-sleep 0
```

If the protected worker cannot run, use `sudo pmset -a disablesleep 0` as the last-resort fallback. Either command can also clear an override created by another sleep-prevention tool.
