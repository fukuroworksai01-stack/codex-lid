#!/bin/bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/dist/Codex Lid.app"
SOURCE_WORKER="$SOURCE_APP/Contents/Resources/CodexLidWorker"

EXPECTED_BUNDLE_ID="com.fukuroworks.codexlid"
CURRENT_UID="$(/usr/bin/id -u)"
CURRENT_USER="$(/usr/bin/id -un)"
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
LEGACY_HELPER="$PRIVILEGED_HELPER_DIR/com.fukuroworks.codexlid.worker"
ACTIVE_SESSION_PATH="/var/run/com.fukuroworks.codexlid.active"

STAGING_DIR=""
STAGING_APP=""
LINK_STAGE=""
OLD_PROTECTED_DIR=""
OLD_PUBLIC_DIR=""
PROTECTED_OLD_MOVED=0
PUBLIC_OLD_MOVED=0
PROTECTED_NEW_MOVED=0
PUBLIC_LINK_INSTALLED=0
COMMIT_COMPLETE=0

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

validate_source_bundle() {
  local app="$1"
  [[ "$(path_type "$app")" == "Directory" ]] || return 1
  validate_no_symlinks "$app" || return 1
  validate_regular_file "$app/Contents/Info.plist" || return 1
  validate_regular_executable "$app/Contents/MacOS/Codex Lid" || return 1
  validate_regular_executable "$app/Contents/Resources/CodexLidWorker" || return 1
  [[ "$(bundle_id "$app")" == "$EXPECTED_BUNDLE_ID" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
  /usr/bin/codesign --verify --strict "$app/Contents/Resources/CodexLidWorker" >/dev/null 2>&1
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
}

validate_user_directory() {
  local path="$1"
  path_exists "$path" || return 1
  [[ "$(path_type "$path")" == "Directory" ]] || return 1
  [[ "$(/usr/bin/stat -f '%u' "$path")" == "$CURRENT_UID" ]]
}

check_sleep_setting_before_install() {
  local pmset_output
  if ! pmset_output="$(/usr/bin/pmset -g 2>&1)"; then
    die "Could not read the current sleep setting with pmset; installation was aborted."
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
    1) die "SleepDisabled is already active; stop the current session or other sleep-prevention tool first." ;;
    *) die "Could not determine the current SleepDisabled state; installation was aborted." ;;
  esac
}

ensure_protected_directories() {
  validate_system_root_directory "$LIBRARY_DIR" \
    || die "Refusing to use an unsafe /Library directory."

  if path_exists "$APPLICATION_SUPPORT_DIR"; then
    validate_system_root_directory "$APPLICATION_SUPPORT_DIR" \
      || die "Refusing to use an unsafe /Library/Application Support directory."
  else
    /usr/bin/sudo /bin/mkdir -m 755 "$APPLICATION_SUPPORT_DIR"
    /usr/bin/sudo /usr/sbin/chown root:wheel "$APPLICATION_SUPPORT_DIR"
    /usr/bin/sudo /bin/chmod -N "$APPLICATION_SUPPORT_DIR"
    validate_system_root_directory "$APPLICATION_SUPPORT_DIR" \
      || die "Could not secure /Library/Application Support."
  fi

  if path_exists "$PROTECTED_ROOT"; then
    validate_secure_root_directory "$PROTECTED_ROOT" \
      || die "Refusing to use an unsafe protected directory: $PROTECTED_ROOT"
  else
    /usr/bin/sudo /bin/mkdir -m 755 "$PROTECTED_ROOT"
    /usr/bin/sudo /usr/sbin/chown root:wheel "$PROTECTED_ROOT"
    /usr/bin/sudo /bin/chmod -N "$PROTECTED_ROOT"
    validate_secure_root_directory "$PROTECTED_ROOT" \
      || die "Could not secure the protected directory."
  fi

  validate_root_applications_directory "$APPLICATIONS_DIR" \
    || die "Refusing to use an unsafe /Applications directory."
}

ensure_app_not_running() {
  local pgrep_status
  if /usr/bin/pgrep -x "Codex Lid" >/dev/null 2>&1; then
    pgrep_status=0
  else
    pgrep_status=$?
  fi
  case "$pgrep_status" in
    0) die "Quit Codex Lid before installing an update." ;;
    1) return 0 ;;
    *) die "Could not determine whether Codex Lid is running; installation was aborted." ;;
  esac
}

validate_legacy_helper() {
  validate_system_root_directory "$LIBRARY_DIR" || return 1
  validate_system_root_directory "$PRIVILEGED_HELPER_DIR" || return 1
  validate_secure_root_executable "$LEGACY_HELPER" || return 1
  /usr/bin/codesign --verify --strict "$LEGACY_HELPER" >/dev/null 2>&1
}

rollback_install() {
  if [[ "$PUBLIC_OLD_MOVED" == "1" ]]; then
    if [[ -L "$PUBLIC_APP" ]]; then
      /usr/bin/sudo /bin/rm -f "$PUBLIC_APP" >/dev/null 2>&1 || true
    elif path_exists "$PUBLIC_APP"; then
      /usr/bin/sudo /bin/rm -rf "$PUBLIC_APP" >/dev/null 2>&1 || true
    fi
    if [[ -n "$OLD_PUBLIC_DIR" ]] \
      && /usr/bin/sudo /bin/test -d "$OLD_PUBLIC_DIR/Codex Lid.app"
    then
      /usr/bin/sudo /bin/mv "$OLD_PUBLIC_DIR/Codex Lid.app" "$PUBLIC_APP" >/dev/null 2>&1 || true
    fi
    PUBLIC_OLD_MOVED=0
  elif [[ "$PUBLIC_LINK_INSTALLED" == "1" ]]; then
    if [[ "$PUBLIC_STATE" == "link" && "$PROTECTED_OLD_MOVED" == "1" ]]; then
      # The pre-existing link already targets the path restored below.
      PUBLIC_LINK_INSTALLED=0
    else
      /usr/bin/sudo /bin/rm -f "$PUBLIC_APP" >/dev/null 2>&1 || true
      PUBLIC_LINK_INSTALLED=0
    fi
  fi

  if [[ "$PROTECTED_NEW_MOVED" == "1" ]]; then
    if [[ -L "$PROTECTED_APP" ]]; then
      /usr/bin/sudo /bin/rm -f "$PROTECTED_APP" >/dev/null 2>&1 || true
    elif path_exists "$PROTECTED_APP"; then
      /usr/bin/sudo /bin/rm -rf "$PROTECTED_APP" >/dev/null 2>&1 || true
    fi
    PROTECTED_NEW_MOVED=0
  fi

  if [[ "$PROTECTED_OLD_MOVED" == "1" && -n "$OLD_PROTECTED_DIR" ]] \
    && /usr/bin/sudo /bin/test -d "$OLD_PROTECTED_DIR/Codex Lid.app"
  then
    /usr/bin/sudo /bin/mv "$OLD_PROTECTED_DIR/Codex Lid.app" "$PROTECTED_APP" >/dev/null 2>&1 || true
    PROTECTED_OLD_MOVED=0
  fi
}

prepare_legacy_app() {
  if ! path_exists "$LEGACY_APP"; then
    return 0
  fi
  [[ -L "$LEGACY_APP" ]] && die "Refusing to replace a symbolic link at $LEGACY_APP"
  [[ "$(path_type "$LEGACY_APP")" == "Directory" ]] \
    || die "Refusing to replace a non-directory at $LEGACY_APP"
  validate_no_symlinks "$LEGACY_APP" \
    || die "Refusing to replace a legacy app containing symbolic links."
  validate_regular_file "$LEGACY_APP/Contents/Info.plist" \
    || die "The legacy app Info.plist is not a regular single-link file."
  validate_regular_executable "$LEGACY_APP/Contents/MacOS/Codex Lid" \
    || die "The legacy app executable failed validation."
  validate_regular_executable "$LEGACY_APP/Contents/Resources/CodexLidWorker" \
    || die "The legacy app worker failed validation."
  [[ "$(bundle_id "$LEGACY_APP")" == "$EXPECTED_BUNDLE_ID" ]] \
    || die "Refusing to replace a different bundle at $LEGACY_APP"
  [[ "$(/usr/bin/stat -f '%u' "$LEGACY_APP")" == "$CURRENT_UID" ]] \
    || die "Refusing to move a legacy app not owned by $CURRENT_USER: $LEGACY_APP"
  /usr/bin/codesign --verify --deep --strict "$LEGACY_APP" >/dev/null 2>&1 \
    || die "The legacy app failed code-signature validation."
  /usr/bin/codesign --verify --strict "$LEGACY_APP/Contents/Resources/CodexLidWorker" \
    >/dev/null 2>&1 || die "The legacy app worker failed code-signature validation."
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

cleanup() {
  local result=$?
  if [[ "$result" -ne 0 && "$COMMIT_COMPLETE" != "1" ]]; then
    rollback_install
  fi
  if [[ -n "$LINK_STAGE" ]] && path_exists "$LINK_STAGE"; then
    /usr/bin/sudo /bin/rm -f "$LINK_STAGE" >/dev/null 2>&1 || true
  fi
  if [[ -n "$STAGING_DIR" ]] && path_exists "$STAGING_DIR"; then
    /usr/bin/sudo /bin/rm -rf "$STAGING_DIR" >/dev/null 2>&1 || true
  fi
  exit "$result"
}
trap cleanup EXIT

case "${1:-}" in
  "") REPLACE=0 ;;
  --replace) REPLACE=1 ;;
  *) die "Usage: $0 [--replace]" ;;
esac

[[ "$CURRENT_UID" != "0" ]] || die "Run this script as the login user, not as root."
[[ -n "$USER_HOME" && "$USER_HOME" == /* ]] \
  || die "HOME must be an absolute path for a login user."

validate_regular_file "$SOURCE_APP/Contents/Info.plist" \
  || die "Build the app first with ./scripts/test.sh"
validate_source_bundle "$SOURCE_APP" \
  || die "The source app failed bundle, signature, or executable validation."
SOURCE_HASH="$(/usr/bin/shasum -a 256 "$SOURCE_WORKER" | /usr/bin/awk '{print $1}')"

ensure_app_not_running

check_sleep_setting_before_install

if path_exists "$ACTIVE_SESSION_PATH"; then
  die "An active Codex Lid session marker exists; installation was aborted."
fi

PROTECTED_PRESENT=0
if path_exists "$PROTECTED_APP"; then
  [[ -L "$PROTECTED_APP" ]] && die "Refusing to replace a symbolic link at $PROTECTED_APP"
  validate_protected_bundle "$PROTECTED_APP" \
    || die "The existing protected app failed strict validation: $PROTECTED_APP"
  PROTECTED_PRESENT=1
fi

LEGACY_HELPER_PRESENT=0
LEGACY_HELPER_HASH=""
if path_exists "$LEGACY_HELPER"; then
  validate_legacy_helper \
    || die "The legacy protected worker failed strict validation."
  LEGACY_HELPER_HASH="$(/usr/bin/shasum -a 256 "$LEGACY_HELPER" | /usr/bin/awk '{print $1}')"
  if [[ "$PROTECTED_PRESENT" == "1" ]]; then
    EXISTING_WORKER_HASH="$(/usr/bin/shasum -a 256 "$PROTECTED_APP/Contents/Resources/CodexLidWorker" | /usr/bin/awk '{print $1}')"
    [[ "$LEGACY_HELPER_HASH" == "$EXISTING_WORKER_HASH" ]] \
      || die "The legacy protected worker does not match the existing protected app."
  elif path_exists "$LEGACY_APP"; then
    prepare_legacy_app
    LEGACY_APP_WORKER_HASH="$(/usr/bin/shasum -a 256 "$LEGACY_APP/Contents/Resources/CodexLidWorker" | /usr/bin/awk '{print $1}')"
    [[ "$LEGACY_HELPER_HASH" == "$LEGACY_APP_WORKER_HASH" ]] \
      || die "The legacy protected worker does not match the legacy app."
  else
    die "A legacy protected worker exists without a matching app; remove it only after manual review."
  fi
  LEGACY_HELPER_PRESENT=1
fi

PUBLIC_STATE="absent"
if path_exists "$PUBLIC_APP"; then
  if [[ -L "$PUBLIC_APP" ]]; then
    [[ "$(/usr/bin/readlink "$PUBLIC_APP")" == "$PROTECTED_APP" ]] \
      || die "Refusing to replace an unexpected /Applications symlink: $PUBLIC_APP"
    PUBLIC_STATE="link"
  else
    [[ "$(path_type "$PUBLIC_APP")" == "Directory" ]] \
      || die "Refusing to replace a non-directory at $PUBLIC_APP"
    [[ "$(bundle_id "$PUBLIC_APP")" == "$EXPECTED_BUNDLE_ID" ]] \
      || die "Refusing to replace a different bundle at $PUBLIC_APP"
    PUBLIC_STATE="app"
  fi
fi

LEGACY_PRESENT=0
if path_exists "$LEGACY_APP"; then
  prepare_legacy_app
  LEGACY_PRESENT=1
fi

if [[ "$REPLACE" == "0" && ( "$PROTECTED_PRESENT" == "1" || "$PUBLIC_STATE" != "absent" || "$LEGACY_PRESENT" == "1" || "$LEGACY_HELPER_PRESENT" == "1" ) ]]; then
  die "An existing Codex Lid installation was found. Re-run with --replace after reviewing it."
fi

echo "Installing the protected app under $PROTECTED_ROOT..."
/usr/bin/sudo -v
ensure_protected_directories

STAGING_DIR="$(/usr/bin/sudo /usr/bin/mktemp -d "$PROTECTED_ROOT/.CodexLid-staging.XXXXXX")"
/usr/bin/sudo /bin/chmod 755 "$STAGING_DIR"
STAGING_APP="$STAGING_DIR/Codex Lid.app"
/usr/bin/sudo /usr/bin/ditto "$SOURCE_APP" "$STAGING_APP"
/usr/bin/sudo /usr/sbin/chown -R root:wheel "$STAGING_APP"
/usr/bin/sudo /bin/chmod -RN "$STAGING_APP"
/usr/bin/sudo /bin/chmod -R a-s "$STAGING_APP"
/usr/bin/sudo /bin/chmod -R go-w "$STAGING_APP"

validate_protected_bundle "$STAGING_APP" \
  || die "The staged app failed strict protected-bundle validation."
STAGING_HASH="$(/usr/bin/shasum -a 256 "$STAGING_APP/Contents/Resources/CodexLidWorker" | /usr/bin/awk '{print $1}')"
[[ "$STAGING_HASH" == "$SOURCE_HASH" ]] \
  || die "The staged worker hash does not match the tested source worker."

move_legacy_app_to_trash

if [[ "$PROTECTED_PRESENT" == "1" ]]; then
  OLD_PROTECTED_DIR="$(/usr/bin/sudo /usr/bin/mktemp -d "$PROTECTED_ROOT/.CodexLid-old.XXXXXX")"
  /usr/bin/sudo /bin/mv "$PROTECTED_APP" "$OLD_PROTECTED_DIR/Codex Lid.app"
  PROTECTED_OLD_MOVED=1
fi

if [[ "$PUBLIC_STATE" == "app" ]]; then
  OLD_PUBLIC_DIR="$(/usr/bin/sudo /usr/bin/mktemp -d "$PROTECTED_ROOT/.CodexLid-public-old.XXXXXX")"
  /usr/bin/sudo /bin/mv "$PUBLIC_APP" "$OLD_PUBLIC_DIR/Codex Lid.app"
  PUBLIC_OLD_MOVED=1
fi

if ! /usr/bin/sudo /bin/mv "$STAGING_APP" "$PROTECTED_APP"; then
  die "Could not install the protected app; the previous app was restored when possible."
fi
PROTECTED_NEW_MOVED=1

validate_protected_bundle "$PROTECTED_APP" \
  || die "The installed protected app failed post-install validation."
INSTALLED_HASH="$(/usr/bin/shasum -a 256 "$PROTECTED_APP/Contents/Resources/CodexLidWorker" | /usr/bin/awk '{print $1}')"
[[ "$INSTALLED_HASH" == "$SOURCE_HASH" ]] \
  || die "The installed worker hash does not match the tested source worker."

if [[ "$PUBLIC_STATE" != "link" ]]; then
  LINK_STAGE="$(/usr/bin/sudo /usr/bin/mktemp -d "$APPLICATIONS_DIR/.CodexLid-link.XXXXXX")"
  /usr/bin/sudo /bin/rmdir "$LINK_STAGE"
  /usr/bin/sudo /bin/ln -s "$PROTECTED_APP" "$LINK_STAGE"
  [[ -L "$LINK_STAGE" && "$(/usr/bin/readlink "$LINK_STAGE")" == "$PROTECTED_APP" ]] \
    || die "Could not create the validated /Applications symlink."

  if ! /usr/bin/sudo /bin/mv "$LINK_STAGE" "$PUBLIC_APP"; then
    die "Could not install the /Applications symlink."
  fi
  LINK_STAGE=""
  PUBLIC_LINK_INSTALLED=1
fi

[[ -L "$PUBLIC_APP" && "$(/usr/bin/readlink "$PUBLIC_APP")" == "$PROTECTED_APP" ]] \
  || die "The installed /Applications symlink failed validation."

if [[ "$LEGACY_HELPER_PRESENT" == "1" ]]; then
  /usr/bin/sudo /bin/rm -f "$LEGACY_HELPER"
  path_exists "$LEGACY_HELPER" \
    && die "Could not remove the legacy protected worker."
fi

COMMIT_COMPLETE=1

if [[ -n "$OLD_PROTECTED_DIR" ]]; then
  /usr/bin/sudo /bin/rm -rf "$OLD_PROTECTED_DIR"
  OLD_PROTECTED_DIR=""
fi
if [[ -n "$OLD_PUBLIC_DIR" ]]; then
  /usr/bin/sudo /bin/rm -rf "$OLD_PUBLIC_DIR"
  OLD_PUBLIC_DIR=""
fi

echo "Installed app: $PROTECTED_APP"
echo "Installed symlink: $PUBLIC_APP -> $PROTECTED_APP"
