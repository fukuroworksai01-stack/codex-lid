#!/bin/bash
set -u

PROTECTED_APP="/Library/Application Support/Codex Lid/Codex Lid.app"
SYSTEM_APP="/Applications/Codex Lid.app"
USER_HOME="${HOME:-}"
RUNTIME_DIR="/private/tmp/codex-lid-$(/usr/bin/id -u)"

print_app() {
  local label="$1"
  local path="$2"
  local plist="$path/Contents/Info.plist"

  echo "$label: $path"
  if [[ -L "$path" ]]; then
    echo "  launcher link: $(/usr/bin/readlink "$path")"
  fi
  if [[ ! -d "$path" ]]; then
    echo "  not found"
    return
  fi

  local version="unknown"
  local build="unknown"
  if [[ -f "$plist" ]]; then
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || echo unknown)"
    build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || echo unknown)"
  fi
  echo "  version: $version ($build)"
  echo "  owner/mode: $(/usr/bin/stat -f '%Su:%Sg %Sp' "$path" 2>/dev/null || echo unknown)"
}

echo "Codex Lid diagnostics"
echo "Generated: $(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "macOS: $(/usr/bin/sw_vers -productVersion 2>/dev/null || echo unknown)"
echo "Architecture: $(/usr/bin/uname -m)"
echo

echo "Installed copies"
print_app "Protected" "$PROTECTED_APP"
print_app "System launcher" "$SYSTEM_APP"
if [[ -n "$USER_HOME" ]]; then
  print_app "Legacy user copy" "$USER_HOME/Applications/Codex Lid.app"
else
  echo "Legacy user copy: home directory unavailable"
fi
echo

echo "Running Codex Lid processes"
PIDS="$(/usr/bin/pgrep -x 'Codex Lid' 2>/dev/null)"
PGREP_STATUS=$?
case "$PGREP_STATUS" in
  0)
    while IFS= read -r pid; do
      /bin/ps -p "$pid" -o pid=,lstart=,comm=
    done <<< "$PIDS"
    ;;
  1) echo "  none" ;;
  *) echo "  unavailable (process access was denied or failed)" ;;
esac
echo

echo "Power source"
/usr/bin/pmset -g batt 2>&1 || true
echo

echo "Sleep settings"
/usr/bin/pmset -g 2>&1 | /usr/bin/grep -E 'sleepdisabled|SleepDisabled|^[[:space:]]+sleep[[:space:]]' || echo "  SleepDisabled is absent or unreadable"
echo

echo "Relevant power assertions"
/usr/bin/pmset -g assertions 2>&1 | /usr/bin/grep -E 'PreventUserIdleSystemSleep|PreventSystemSleep|NoIdleSleepAssertion' || echo "  assertions unreadable"
echo

echo "Clamshell state"
/usr/sbin/ioreg -r -k AppleClamshellState -k AppleClamshellCausesSleep -k SleepDisabled 2>&1 | /usr/bin/grep -E 'AppleClamshellState|AppleClamshellCausesSleep|SleepDisabled' || echo "  clamshell state unreadable"
echo

echo "Active display summary"
/usr/sbin/system_profiler SPDisplaysDataType -detailLevel mini 2>&1 | /usr/bin/grep -E 'Display Type:|Resolution:|Main Display:|Online:|Connection Type:' || echo "  no active display details found"
echo

echo "Runtime markers"
if [[ -d "$RUNTIME_DIR" ]]; then
  echo "  runtime directory: present ($(/usr/bin/stat -f '%Su:%Sg %Sp' "$RUNTIME_DIR" 2>/dev/null || echo unknown))"
else
  echo "  runtime directory: absent"
fi
for marker in \
  /var/run/com.fukuroworks.codexlid.active \
  /var/run/com.fukuroworks.codexlid.lock \
  /var/run/com.fukuroworks.codexlid.power.lock; do
  if [[ -e "$marker" ]]; then
    echo "  $marker: present"
  else
    echo "  $marker: absent"
  fi
done

echo
echo "No network requests or unified-log collection were performed."
