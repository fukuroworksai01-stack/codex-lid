#!/bin/bash
set -euo pipefail

export LC_ALL=C

EXPECTED_BUNDLE_ID="com.fukuroworks.codexlid"
CURRENT_UID="$(/usr/bin/id -u)"
USER_HOME="${HOME:-}"
USER_APPS_DIR="$USER_HOME/Applications"
LEGACY_APP="$USER_APPS_DIR/Codex Lid.app"
TRASH_DIRECTORY="$USER_HOME/.Trash"

LIBRARY_DIR="/Library"
APPLICATION_SUPPORT_DIR="/Library/Application Support"
PROTECTED_ROOT="/Library/Application Support/Codex Lid"
PROTECTED_APP="$PROTECTED_ROOT/Codex Lid.app"
APPLICATIONS_DIR="/Applications"
PUBLIC_APP="$APPLICATIONS_DIR/Codex Lid.app"
PRIVILEGED_HELPER_DIR="/Library/PrivilegedHelperTools"
LEGACY_HELPER="/Library/PrivilegedHelperTools/com.fukuroworks.codexlid.worker"
ACTIVE_SESSION_PATH="/var/run/com.fukuroworks.codexlid.active"

die() {
  echo "Error: $*" >&2
  exit 1
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

path_type() {
  /usr/bin/stat -f '%HT' "$1"
}

path_owner() {
  /usr/bin/stat -f '%Su:%Sg' "$1"
}

path_mode() {
  /usr/bin/stat -f '%Sp' "$1"
}

path_links() {
  /usr/bin/stat -f '%l' "$1"
}

has_group_or_other_write() {
  local permissions="$1"
  local group_permissions="${permissions:4:3}"
  local other_permissions="${permissions:7:3}"
  [[ "$group_permissions" == *w* || "$other_permissions" == *w* ]]
}

validate_no_extended_acl() {
  local acl_output
  acl_output="$(/bin/ls -lde "$1" 2>/dev/null)" || return 1
  [[ "$acl_output" != *$'\n'* ]]
}

validate_secure_root_directory() {
  local path="$1"
  path_exists "$path" || return 1
  [[ "$(path_type "$path")" == "Directory" ]] || return 1
  [[ "$(path_owner "$path")" == "root:wheel" ]] || return 1
  validate_no_extended_acl "$path" || return 1
  ! has_group_or_other_write "$(path_mode "$path")"
}

validate_system_root_directory() {
  local path="$1"
  path_exists "$path" || return 1
  [[ "$(path_type "$path")" == "Directory" ]] || return 1
  [[ "$(/usr/bin/stat -f '%u' "$path")" == "0" ]] || return 1
  validate_no_extended_acl "$path" || return 1
  ! has_group_or_other_write "$(path_mode "$path")"
}

validate_root_applications_directory() {
  local path="$1"
  path_exists "$path" || return 1
  [[ "$(path_type "$path")" == "Directory" ]] || return 1
  [[ "$(/usr/bin/stat -f '%u' "$path")" == "0" ]] || return 1
  validate_no_extended_acl "$path" || return 1
  local permissions
  permissions="$(path_mode "$path")"
  local other_permissions="${permissions:7:3}"
  [[ "$other_permissions" != *w* ]]
}

validate_secure_root_file() {
  local path="$1"
  local permissions
  path_exists "$path" || return 1
  [[ "$(path_type "$path")" == "Regular File" ]] || return 1
  [[ "$(path_owner "$path")" == "root:wheel" ]] || return 1
  validate_no_extended_acl "$path" || return 1
  permissions="$(path_mode "$path")"
  ! has_group_or_other_write "$permissions" || return 1
  [[ "$permissions" != *s* && "$permissions" != *S* ]] || return 1
  [[ "$(path_links "$path")" == "1" ]]
}

validate_secure_root_executable() {
  validate_secure_root_file "$1" && [[ -x "$1" ]]
}

validate_regular_file() {
  local path="$1"
  path_exists "$path" || return 1
  [[ "$(path_type "$path")" == "Regular File" ]] || return 1
  [[ "$(path_links "$path")" == "1" ]]
}

validate_regular_executable() {
  validate_regular_file "$1" && [[ -x "$1" ]]
}

validate_no_symlinks() {
  local bundle="$1"
  local symlink_path
  if ! symlink_path="$(/usr/bin/find -P "$bundle" -type l -print -quit 2>/dev/null)"; then
    return 1
  fi
  [[ -z "$symlink_path" ]]
}

bundle_id() {
  local app="$1"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null
}

validate_protected_bundle() {
  local app="$1"
  local contents="$app/Contents"
  local macos="$contents/MacOS"
  local resources="$contents/Resources"
  local worker="$resources/CodexLidWorker"

  validate_no_symlinks "$app" || return 1
  validate_secure_root_directory "$app" || return 1
  validate_secure_root_directory "$contents" || return 1
  validate_secure_root_directory "$macos" || return 1
  validate_secure_root_directory "$resources" || return 1
  validate_secure_root_file "$contents/Info.plist" || return 1
  validate_secure_root_executable "$macos/Codex Lid" || return 1
  validate_secure_root_executable "$worker" || return 1
  [[ "$(bundle_id "$app")" == "$EXPECTED_BUNDLE_ID" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
  /usr/bin/codesign --verify --strict "$worker" >/dev/null 2>&1 || return 1

  local worker_hash
  worker_hash="$(/usr/bin/shasum -a 256 "$worker" | /usr/bin/awk '{print $1}')"
  [[ "$worker_hash" =~ ^[0-9a-f]{64}$ ]]
}

validate_public_bundle() {
  local app="$1"
  [[ "$(path_type "$app")" == "Directory" ]] || return 1
  [[ "$(bundle_id "$app")" == "$EXPECTED_BUNDLE_ID" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
}

validate_user_directory() {
  local path="$1"
  path_exists "$path" || return 1
  [[ "$(path_type "$path")" == "Directory" ]] || return 1
  [[ "$(/usr/bin/stat -f '%u' "$path")" == "$CURRENT_UID" ]]
}

ensure_app_not_running() {
  local pgrep_status
  if /usr/bin/pgrep -x "Codex Lid" >/dev/null 2>&1; then
    pgrep_status=0
  else
    pgrep_status=$?
  fi
  case "$pgrep_status" in
    0) die "Quit Codex Lid before uninstalling it." ;;
    1) return 0 ;;
    *) die "Could not determine whether Codex Lid is running; uninstall was aborted." ;;
  esac
}

check_sleep_setting_before_uninstall() {
  local pmset_output
  if ! pmset_output="$(/usr/bin/pmset -g 2>&1)"; then
    die "Could not read the current sleep setting with pmset; uninstall was aborted."
  fi

  local sleep_state
  sleep_state="$(/usr/bin/awk '
    BEGIN { count = 0; value = ""; invalid = 0 }
    tolower($1) == "sleepdisabled" {
      count++
      if ($2 == "0" || $2 == "1") {
        value = $2
      } else {
        invalid = 1
      }
    }
    END {
      if (count == 0) print "absent"
      else if (count != 1 || invalid || value == "") print "unknown"
      else print value
    }' <<< "$pmset_output")"

  case "$sleep_state" in
    0|absent) ;;
    1) die "SleepDisabled is active. Stop the session and restore normal sleep before uninstalling." ;;
    *) die "Could not determine the current SleepDisabled state; uninstall was aborted." ;;
  esac
}

move_legacy_app_to_trash() {
  if ! path_exists "$LEGACY_APP"; then
    return 0
  fi

  if path_exists "$TRASH_DIRECTORY"; then
    validate_user_directory "$TRASH_DIRECTORY" \
      || die "Refusing to use an unsafe Trash directory: $TRASH_DIRECTORY"
  else
    /bin/mkdir -m 700 "$TRASH_DIRECTORY"
    validate_user_directory "$TRASH_DIRECTORY" \
      || die "Could not prepare the user Trash directory."
  fi

  local trash_destination
  trash_destination="$(/usr/bin/mktemp -d "$TRASH_DIRECTORY/Codex Lid.app.XXXXXX")"
  /bin/rmdir "$trash_destination"
  /bin/mv "$LEGACY_APP" "$trash_destination"
  echo "Moved legacy app to: $trash_destination"
}

case "${1:-}" in
  "") ;;
  *) die "Usage: $0" ;;
esac

[[ "$CURRENT_UID" != "0" ]] || die "Run this script as the login user, not as root."
[[ -n "$USER_HOME" && "$USER_HOME" == /* ]] \
  || die "HOME must be an absolute path for a login user."

check_sleep_setting_before_uninstall

ensure_app_not_running

if path_exists "$ACTIVE_SESSION_PATH"; then
  [[ -L "$ACTIVE_SESSION_PATH" ]] && die "Refusing to uninstall while the active-session marker is a symbolic link."
  validate_secure_root_file "$ACTIVE_SESSION_PATH" \
    || die "Refusing to uninstall with an unexpected active-session marker."
  die "An active Codex Lid session marker remains; stop the session before uninstalling."
fi

PROTECTED_PRESENT=0
PROTECTED_WORKER_HASH=""
if path_exists "$PROTECTED_APP"; then
  [[ -L "$PROTECTED_APP" ]] && die "Refusing to remove a symbolic link at $PROTECTED_APP"
  validate_system_root_directory "$LIBRARY_DIR" \
    || die "Refusing to use an unsafe /Library directory."
  validate_system_root_directory "$APPLICATION_SUPPORT_DIR" \
    || die "Refusing to use an unsafe /Library/Application Support directory."
  validate_secure_root_directory "$PROTECTED_ROOT" \
    || die "Refusing to use an unsafe protected directory."
  validate_protected_bundle "$PROTECTED_APP" \
    || die "The protected app failed strict validation; it was not removed."
  PROTECTED_WORKER_HASH="$(/usr/bin/shasum -a 256 "$PROTECTED_APP/Contents/Resources/CodexLidWorker" | /usr/bin/awk '{print $1}')"
  PROTECTED_PRESENT=1
fi

PUBLIC_STATE="absent"
if path_exists "$PUBLIC_APP"; then
  validate_root_applications_directory "$APPLICATIONS_DIR" \
    || die "Refusing to use an unsafe /Applications directory."
  if [[ -L "$PUBLIC_APP" ]]; then
    [[ "$(/usr/bin/readlink "$PUBLIC_APP")" == "$PROTECTED_APP" ]] \
      || die "Refusing to remove an unexpected /Applications symlink: $PUBLIC_APP"
    PUBLIC_STATE="link"
  else
    validate_public_bundle "$PUBLIC_APP" \
      || die "The /Applications bundle failed strict validation; it was not removed."
    PUBLIC_STATE="app"
  fi
fi

LEGACY_PRESENT=0
if path_exists "$LEGACY_APP"; then
  [[ -L "$LEGACY_APP" ]] && die "Refusing to move a symbolic link: $LEGACY_APP"
  [[ "$(path_type "$LEGACY_APP")" == "Directory" ]] \
    || die "Refusing to move a non-directory: $LEGACY_APP"
  validate_no_symlinks "$LEGACY_APP" \
    || die "Refusing to move a legacy app containing symbolic links."
  validate_regular_file "$LEGACY_APP/Contents/Info.plist" \
    || die "The legacy app Info.plist failed validation."
  validate_regular_executable "$LEGACY_APP/Contents/MacOS/Codex Lid" \
    || die "The legacy app executable failed validation."
  validate_regular_executable "$LEGACY_APP/Contents/Resources/CodexLidWorker" \
    || die "The legacy app worker failed validation."
  [[ "$(bundle_id "$LEGACY_APP")" == "$EXPECTED_BUNDLE_ID" ]] \
    || die "Refusing to move a different bundle: $LEGACY_APP"
  [[ "$(/usr/bin/stat -f '%u' "$LEGACY_APP")" == "$CURRENT_UID" ]] \
    || die "Refusing to move a legacy app not owned by the login user: $LEGACY_APP"
  /usr/bin/codesign --verify --deep --strict "$LEGACY_APP" >/dev/null 2>&1 \
    || die "The legacy app failed code-signature validation."
  /usr/bin/codesign --verify --strict "$LEGACY_APP/Contents/Resources/CodexLidWorker" \
    >/dev/null 2>&1 || die "The legacy app worker failed code-signature validation."
  LEGACY_PRESENT=1
fi

OLD_HELPER_PRESENT=0
if path_exists "$LEGACY_HELPER"; then
  validate_system_root_directory "$LIBRARY_DIR" \
    || die "Refusing to use an unsafe /Library directory."
  validate_system_root_directory "$PRIVILEGED_HELPER_DIR" \
    || die "Refusing to use an unsafe privileged-helper directory."
  validate_secure_root_executable "$LEGACY_HELPER" \
    || die "The legacy protected worker failed strict validation; it was not removed."
  /usr/bin/codesign --verify --strict "$LEGACY_HELPER" >/dev/null 2>&1 \
    || die "The legacy protected worker failed code-signature validation."
  LEGACY_HELPER_HASH="$(/usr/bin/shasum -a 256 "$LEGACY_HELPER" | /usr/bin/awk '{print $1}')"
  if [[ -n "$PROTECTED_WORKER_HASH" && "$LEGACY_HELPER_HASH" != "$PROTECTED_WORKER_HASH" ]]; then
    die "The legacy protected worker hash does not match the installed app worker."
  elif [[ -z "$PROTECTED_WORKER_HASH" && "$LEGACY_PRESENT" == "1" ]]; then
    LEGACY_APP_WORKER_HASH="$(/usr/bin/shasum -a 256 "$LEGACY_APP/Contents/Resources/CodexLidWorker" | /usr/bin/awk '{print $1}')"
    [[ "$LEGACY_HELPER_HASH" == "$LEGACY_APP_WORKER_HASH" ]] \
      || die "The legacy protected worker hash does not match the legacy app worker."
  elif [[ -z "$PROTECTED_WORKER_HASH" ]]; then
    die "A legacy protected worker exists without a matching app; it was not removed."
  fi
  OLD_HELPER_PRESENT=1
fi

if [[ "$PROTECTED_PRESENT" == "0" && "$PUBLIC_STATE" == "absent" && "$LEGACY_PRESENT" == "0" && "$OLD_HELPER_PRESENT" == "0" ]]; then
  echo "No Codex Lid installation was found."
  exit 0
fi

/usr/bin/sudo -v

# Move the user-owned legacy app first. If a later root operation fails, the
# old app remains recoverable in Trash rather than being silently overwritten.
move_legacy_app_to_trash

if [[ "$OLD_HELPER_PRESENT" == "1" ]]; then
  /usr/bin/sudo /bin/rm -f "$LEGACY_HELPER"
fi

if [[ "$PUBLIC_STATE" == "link" ]]; then
  /usr/bin/sudo /bin/rm -f "$PUBLIC_APP"
elif [[ "$PUBLIC_STATE" == "app" ]]; then
  /usr/bin/sudo /bin/rm -rf "$PUBLIC_APP"
fi

if [[ "$PROTECTED_PRESENT" == "1" ]]; then
  /usr/bin/sudo /bin/rm -rf "$PROTECTED_APP"
  if path_exists "$PROTECTED_APP"; then
    die "Could not remove the protected app."
  fi
  /usr/bin/sudo /bin/rmdir "$PROTECTED_ROOT" >/dev/null 2>&1 || true
fi

echo "Codex Lid was uninstalled. Diagnostic files were left in /private/tmp/codex-lid-$(/usr/bin/id -u)."
