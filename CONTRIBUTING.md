# Contributing

Small, reviewable pull requests are welcome.

## Before opening a pull request

1. Explain the user-facing problem and safety impact.
2. Keep administrator-privileged code as small as possible.
3. Do not add networking, analytics, a running privileged daemon, or a sudoers modification without prior design discussion.
4. Run:

   ```bash
   ./scripts/test.sh
   ```

5. For changes to sleep control, test the 5-minute mode on AC power and confirm `SleepDisabled` returns to `0` or disappears afterward.

Never test a closed, awake Mac in a bag, case, bed, or other heat-trapping location. Avoid posting secrets or security exploit details in a public issue; follow [SECURITY.md](SECURITY.md) instead.
