#!/usr/bin/env bash
#
# fpm.sh - Firefox Profile Management
#
# Manages Firefox profiles found in the user's home directory. It checks the
# common Firefox locations, including Firefox installed via snap and flatpak.
# Both profile backends are supported:
#   * the legacy profiles.ini file
#   * the new SQLite-backed profile store ("Profile Groups")
#
# Actions:
#   list     List all profiles (names, identifiers, paths). Default action.
#              ./fpm.sh
#              ./fpm.sh list
#
#   export   Zip a profile directory into the current directory.
#              ./fpm.sh export --name NAME [--output FILE]
#              ./fpm.sh export --id ID   [--output FILE]
#              --name NAME    Select the profile by name.
#              --id ID        Select the profile by identifier (e.g. Profile0).
#              --output FILE  Archive filename (default: firefox-profile.zip).
#
#   import   Import a profile from a zip archive and register it in both
#            profiles.ini and the SQLite profile store.
#              ./fpm.sh import [--name NAME] [--dir DIR] ARCHIVE.zip
#              --name NAME    Name for the imported profile (default: Default).
#              --dir DIR      Target Firefox directory (required if more than
#                             one is found; accepts a path or native/snap/flatpak).
#              ARCHIVE        The zip archive produced by "export".
#
#   delete   Delete a profile by name, removing it from profiles.ini and the
#            SQLite profile store. The on-disk profile directory is left in
#            place.
#              ./fpm.sh delete NAME
#              --name NAME    Name of the profile to delete (or pass as a
#                             positional argument).
#
#   help     Show usage information.
#              ./fpm.sh help

set -euo pipefail

readonly VERSION="0.4.0"
readonly SQLITE3_BIN="${SQLITE3_BIN:-/usr/bin/sqlite3}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

err() { printf '%s\n' "$*" >&2; }

usage() {
  cat <<EOF
FPM - Firefox Profile Management (v${VERSION})

Usage:
  ${0##*/} [command]

Commands:
  list    List all Firefox profiles (names, paths, identifiers). (default)
          Profiles are read from both profiles.ini and the new SQLite store.
  export  Export a profile directory as a zip archive.
  import  Import a profile from a zip archive.
  delete  Delete a profile by name (from profiles.ini and the SQLite store).
  help    Show this help message.

Export options:
  --name NAME    Select the profile by name.
  --id ID        Select the profile by its identifier (e.g. Profile0).
  --output FILE  Archive filename (default: firefox-profile.zip).

Import options:
  --name NAME    Name for the imported profile (default: Default).
  --dir DIR      Target Firefox directory (required if more than one exists).
  ARCHIVE        The zip archive to import.

Delete options:
  NAME           Name of the profile to delete.
  --name NAME    Name of the profile to delete.

Note: delete removes the profile's registration; the on-disk directory is kept.
EOF
}

# ---------------------------------------------------------------------------
# Collected profiles. Kept as parallel arrays so names/paths may contain
# spaces or special characters.
# ---------------------------------------------------------------------------

declare -a P_SRC=() P_ID=() P_NAME=() P_PATH=() P_DEFAULT=() SRC_ORDER=()
declare -A SEEN=()
TARGET_DIR=""

# ---------------------------------------------------------------------------
# Candidate Firefox configuration directories (most common first).
# ---------------------------------------------------------------------------

# Every well-known Firefox profile directory, existing or not.
known_firefox_dirs() {
  local d
  for d in \
    "$HOME/.config/mozilla/firefox" \
    "$HOME/.mozilla/firefox" \
    "$HOME/snap/firefox/common/.mozilla/firefox" \
    "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"; do
    [[ -n "$d" ]] && printf '%s\n' "$d"
  done

  # Allow extra directories via FPM_PROFILE_DIRS (colon separated).
  if [[ -n "${FPM_PROFILE_DIRS:-}" ]]; then
    local IFS=':'
    for d in $FPM_PROFILE_DIRS; do
      [[ -n "$d" ]] && printf '%s\n' "$d"
    done
  fi
}

# Directories that already contain profile data.
firefox_config_dirs() {
  local d
  while IFS= read -r d; do
    has_profile_data "$d" && printf '%s\n' "$d"
  done < <(known_firefox_dirs)
}

# Directories that exist on disk (used by import as possible targets).
existing_firefox_dirs() {
  local d
  while IFS= read -r d; do
    [[ -d "$d" ]] && printf '%s\n' "$d"
  done < <(known_firefox_dirs)
}

# A Firefox config directory is relevant if it has the legacy profiles.ini or
# at least one SQLite profile-group database.
has_profile_data() {
  local d="$1"
  [[ -f "$d/profiles.ini" ]] && return 0
  local -a group_dbs=("$d"/Profile\ Groups/*.sqlite)
  [[ -e "${group_dbs[0]}" ]] && return 0
  return 1
}

# Human-friendly label for a source directory.
describe_source() {
  local d="$1"
  if [[ "$d" == "$HOME/.mozilla/firefox" ]]; then
    printf 'native (%s)' "$d"
  elif [[ "$d" == "$HOME/snap/firefox/common/.mozilla/firefox" ]]; then
    printf 'snap (%s)' "$d"
  elif [[ "$d" == "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" ]]; then
    printf 'flatpak (%s)' "$d"
  else
    printf '%s' "$d"
  fi
}

add_source() {
  local src="$1" e
  for e in "${SRC_ORDER[@]}"; do
    [[ "$e" == "$src" ]] && return
  done
  SRC_ORDER+=("$src")
}

# ---------------------------------------------------------------------------
# profiles.ini parsing
# ---------------------------------------------------------------------------

emit_profile() {
  local src="$1" id="$2" name="$3" path="$4" isrel="$5" default="$6" base="$7"
  local full

  if [[ "$isrel" == "0" ]]; then
    full="$path"
  else
    # IsRelative=1 (or missing, as in very old files) -> relative to base.
    full="${base%/}/${path#/}"
  fi

  # The same profile directory may be listed both by profiles.ini and by a
  # SQLite profile-group database. Keep the first occurrence only.
  [[ -n "${SEEN[$full]:-}" ]] && return 0
  SEEN[$full]=1

  P_SRC+=("$src")
  P_ID+=("$id")
  P_NAME+=("$name")
  P_PATH+=("$full")
  if [[ "$default" == "1" ]]; then
    P_DEFAULT+=("1")
  else
    P_DEFAULT+=("0")
  fi
}

parse_profiles_ini() {
  local src="$1" ini="$2"
  local base
  base="$(dirname "$ini")"

  local section="" name="" path="" isrel="" default=""
  local line key value

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue

    if [[ "$line" == \[*\] ]]; then
      # New section: flush any pending profile.
      if [[ "$section" == Profile* && -n "$name" && -n "$path" ]]; then
        emit_profile "$src" "$section" "$name" "$path" "$isrel" "$default" "$base"
      fi
      section="${line#\[}"
      section="${section%\]}"
      name=""; path=""; isrel=""; default=""
      continue
    fi

    if [[ "$section" == Profile* && "$line" == *=* ]]; then
      key="${line%%=*}"
      value="${line#*=}"
      key="${key%"${key##*[![:space:]]}"}"     # rtrim key
      value="${value#"${value%%[![:space:]]*}"}" # ltrim value
      case "$key" in
        Name)       name="$value" ;;
        Path)       path="$value" ;;
        IsRelative) isrel="$value" ;;
        Default)    default="$value" ;;
      esac
    fi
  done < "$ini"

  if [[ "$section" == Profile* && -n "$name" && -n "$path" ]]; then
    emit_profile "$src" "$section" "$name" "$path" "$isrel" "$default" "$base"
  fi
}

# Some Firefox versions store the default profile only in install*.ini as
# "Default=Profiles/<dir>". Match it back onto the profiles found above.
mark_defaults() {
  local src="$1"
  local f line def b i
  local -a files=("$src/installs.ini")
  files+=("$src"/install*.ini)

  for f in "${files[@]}"; do
    [[ -e "$f" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ "$line" == Default=* ]] || continue

      def="${line#Default=}"
      b="${def##*/}"
      for i in "${!P_SRC[@]}"; do
        if [[ "${P_SRC[$i]}" == "$src" && "${P_PATH[$i]##*/}" == "$b" ]]; then
          P_DEFAULT[$i]="1"
        fi
      done
    done < "$f"
  done
}

# New Firefox backend: each profile group is an SQLite database stored in
# <firefox-dir>/Profile Groups/<store-id>.sqlite with a "Profiles" table.
parse_profile_groups() {
  local src="$1"
  [[ -x "$SQLITE3_BIN" ]] || return 0

  local db storeid id name path isrel
  for db in "$src"/Profile\ Groups/*.sqlite; do
    [[ -e "$db" ]] || continue

    storeid="$(basename "$db")"
    storeid="${storeid%.sqlite}"

    while IFS=$'\037' read -r id name path; do
      [[ -n "$name" || -n "$path" ]] || continue
      if [[ "$path" == /* ]]; then
        isrel="0"
      else
        isrel="1"
      fi
      emit_profile "$src" "sqlite:${storeid}#${id}" "$name" "$path" "$isrel" "" "$src"
    done < <("$SQLITE3_BIN" -separator $'\037' "$db" \
      'SELECT id, name, path FROM Profiles ORDER BY id;' 2>/dev/null)
  done
}

parse_source() {
  local src="$1"
  local before=${#P_ID[@]}

  [[ -f "$src/profiles.ini" ]] && parse_profiles_ini "$src" "$src/profiles.ini"
  parse_profile_groups "$src"

  if (( ${#P_ID[@]} > before )); then
    add_source "$src"
    mark_defaults "$src"
  fi
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

print_profiles() {
  local total=${#P_ID[@]}
  printf 'Found %d Firefox profile(s) in %d location(s).\n\n' "$total" "${#SRC_ORDER[@]}"

  local src i j
  local -a idx=()

  for src in "${SRC_ORDER[@]}"; do
    idx=()
    for i in "${!P_SRC[@]}"; do
      [[ "${P_SRC[$i]}" == "$src" ]] && idx+=("$i")
    done
    [[ ${#idx[@]} -eq 0 ]] && continue

    local w_id=2 w_name=4
    for i in "${idx[@]}"; do
      (( ${#P_ID[$i]} > w_id ))   && w_id=${#P_ID[$i]}
      (( ${#P_NAME[$i]} > w_name )) && w_name=${#P_NAME[$i]}
    done

    printf 'Source: %s\n' "$(describe_source "$src")"
    printf '  %-*s  %-*s  %s\n' "$w_id" "ID" "$w_name" "NAME" "PATH"

    for i in "${idx[@]}"; do
      local star=""
      [[ "${P_DEFAULT[$i]}" == "1" ]] && star=" *"
      printf '  %-*s  %-*s  %s%s\n' \
        "$w_id" "${P_ID[$i]}" \
        "$w_name" "${P_NAME[$i]}" \
        "${P_PATH[$i]}" "$star"
    done
    printf '\n'
  done

  printf '(*) default profile\n'

  local has_sqlite=0
  for i in "${!P_ID[@]}"; do
    [[ "${P_ID[$i]}" == sqlite:* ]] && { has_sqlite=1; break; }
  done
  if (( has_sqlite )); then
    printf 'IDs prefixed with "sqlite:" come from the new SQLite profile store.\n'
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

collect_profiles() {
  local d

  while IFS= read -r d; do
    [[ -n "$d" ]] && parse_source "$d"
  done < <(firefox_config_dirs)
}

cmd_list() {
  collect_profiles

  if [[ ${#P_ID[@]} -eq 0 ]]; then
    err "No Firefox profiles found."
    err "Checked the common Firefox locations (native, snap, flatpak)."
    err "Both profiles.ini and the SQLite profile store were inspected."
    exit 1
  fi

  print_profiles
}

cmd_export() {
  local name="" id="" output="firefox-profile.zip"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ -n "${2:-}" ]] || { err "Missing value for --name"; exit 2; }
        name="$2"; shift 2 ;;
      --name=*)
        name="${1#--name=}"; shift ;;
      --id)
        [[ -n "${2:-}" ]] || { err "Missing value for --id"; exit 2; }
        id="$2"; shift 2 ;;
      --id=*)
        id="${1#--id=}"; shift ;;
      --output)
        [[ -n "${2:-}" ]] || { err "Missing value for --output"; exit 2; }
        output="$2"; shift 2 ;;
      --output=*)
        output="${1#--output=}"; shift ;;
      -h|--help)
        usage; return 0 ;;
      *)
        err "Unknown export option: $1"
        usage >&2
        exit 2 ;;
    esac
  done

  if [[ -z "$name" && -z "$id" ]]; then
    err "Specify the profile to export with --name or --id."
    err "Use 'fpm.sh list' to see available profiles."
    exit 2
  fi
  if [[ -n "$name" && -n "$id" ]]; then
    err "Specify only one of --name or --id."
    exit 2
  fi

  collect_profiles
  if [[ ${#P_ID[@]} -eq 0 ]]; then
    err "No Firefox profiles found."
    exit 1
  fi

  # Resolve the selected profile.
  local idx=-1 i
  if [[ -n "$id" ]]; then
    local -a id_matches=()
    for i in "${!P_ID[@]}"; do
      [[ "${P_ID[$i]}" == "$id" ]] && id_matches+=("$i")
    done
    if (( ${#id_matches[@]} == 0 )); then
      err "No profile with id '$id' found."
      err "Use 'fpm.sh list' to see available profiles."
      exit 1
    elif (( ${#id_matches[@]} > 1 )); then
      err "Multiple profiles match the id '$id':"
      for i in "${id_matches[@]}"; do
        err "  ${P_NAME[$i]}  ${P_PATH[$i]}"
      done
      err "Please disambiguate using a unique --name or --id."
      exit 1
    fi
    idx="${id_matches[0]}"
  else
    local -a matches=()
    for i in "${!P_NAME[@]}"; do
      [[ "${P_NAME[$i]}" == "$name" ]] && matches+=("$i")
    done
    if (( ${#matches[@]} == 0 )); then
      err "No profile named '$name' found."
      err "Use 'fpm.sh list' to see available profiles."
      exit 1
    elif (( ${#matches[@]} > 1 )); then
      err "Multiple profiles match the name '$name':"
      for i in "${matches[@]}"; do
        err "  ${P_ID[$i]}  ${P_PATH[$i]}"
      done
      err "Please disambiguate using a unique --name or --id."
      exit 1
    fi
    idx="${matches[0]}"
  fi

  local dir="${P_PATH[$idx]}"
  if [[ ! -d "$dir" ]]; then
    err "Profile directory does not exist: $dir"
    exit 1
  fi

  if ! command -v zip >/dev/null 2>&1; then
    err "The 'zip' utility is required for export but was not found in PATH."
    exit 1
  fi

  local out_abs
  if [[ "$output" == /* ]]; then
    out_abs="$output"
  else
    out_abs="${PWD%/}/${output}"
  fi

  local parent base
  parent="$(dirname "$dir")"
  base="$(basename "$dir")"

  if ( cd "$parent" && zip -r -q "$out_abs" "$base" ); then
    printf 'Exported profile "%s" (%s) to %s\n' "${P_NAME[$idx]}" "${P_ID[$idx]}" "$out_abs"
  else
    err "Failed to create zip archive '$out_abs'."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Import
# ---------------------------------------------------------------------------

# Resolve a --dir argument (short label or path) to a directory path.
resolve_dir_arg() {
  case "$1" in
    native)  printf '%s' "$HOME/.mozilla/firefox" ;;
    snap)    printf '%s' "$HOME/snap/firefox/common/.mozilla/firefox" ;;
    flatpak) printf '%s' "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" ;;
    *)       printf '%s' "$1" ;;
  esac
}

# Choose the target Firefox directory, requiring --dir when ambiguous.
resolve_target_dir() {
  local given="$1"
  local d
  local -a dirs=()

  while IFS= read -r d; do
    [[ -n "$d" ]] && dirs+=("$d")
  done < <(existing_firefox_dirs)

  if [[ -n "$given" ]]; then
    TARGET_DIR="$(resolve_dir_arg "$given")"
    mkdir -p "$TARGET_DIR"
    return 0
  fi

  if (( ${#dirs[@]} == 0 )); then
    err "No Firefox directories found."
    err "Specify one with --dir (e.g. --dir \"$HOME/.mozilla/firefox\")."
    exit 1
  fi

  if (( ${#dirs[@]} > 1 )); then
    err "Multiple Firefox directories found:"
    for d in "${dirs[@]}"; do
      err "  $(describe_source "$d")"
    done
    err "Specify which one to import into with --dir."
    exit 1
  fi

  TARGET_DIR="${dirs[0]}"
}

# Return the single top-level directory name contained in a zip archive.
zip_top_dir() {
  local zipfile="$1"
  local entry top
  local -A seen=()
  local -a dirs=() files=()

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == */* ]]; then
      top="${entry%%/*}"
      [[ -n "$top" ]] || continue
      [[ -n "${seen[$top]:-}" ]] && continue
      seen[$top]=1
      dirs+=("$top")
    else
      files+=("$entry")
    fi
  done < <(unzip -Z1 "$zipfile" 2>/dev/null)

  if (( ${#dirs[@]} == 0 )); then
    err "Archive does not contain a profile directory (expected one top-level folder)."
    exit 1
  fi
  if (( ${#dirs[@]} > 1 )); then
    err "Archive contains multiple top-level directories:"
    for top in "${dirs[@]}"; do
      err "  $top"
    done
    err "Expected exactly one profile directory."
    exit 1
  fi
  if (( ${#files[@]} > 0 )); then
    err "Archive contains files at its root; expected only a profile directory."
    exit 1
  fi

  printf '%s\n' "${dirs[0]}"
}

# Pick a non-colliding directory name inside a target directory.
unique_dir_name() {
  local dir="$1" base="$2"
  local cand="$base" n=1
  while [[ -e "$dir/$cand" ]]; do
    cand="${base}-${n}"
    (( n += 1 ))
  done
  printf '%s\n' "$cand"
}

# Next free Profile index in a profiles.ini (or 0 if it does not exist).
next_profile_number() {
  local ini="$1" line n max=-1
  [[ -f "$ini" ]] || { printf '0'; return 0; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ "$line" =~ ^\[Profile([0-9]+)\]$ ]]; then
      n=$((10#${BASH_REMATCH[1]}))
      (( n > max )) && max=$n
    fi
  done < "$ini"
  printf '%d' "$((max + 1))"
}

# First StoreID referenced by profiles.ini (empty if none).
preferred_storeid() {
  local ini="$1/profiles.ini" line v
  [[ -f "$ini" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ "$line" == StoreID=* ]]; then
      v="${line#StoreID=}"
      v="${v#"${v%%[![:space:]]*}"}"
      v="${v%"${v##*[![:space:]]}"}"
      [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    fi
  done < "$ini"
  return 0
}

# Print the profile-group database to update.
# Return: 0 (printed path), 1 (none exists -> create one), 2 (ambiguous).
resolve_group_db() {
  local dir="$1"
  local db storeid
  local -a dbs=()

  for db in "$dir"/Profile\ Groups/*.sqlite; do
    [[ -e "$db" ]] && dbs+=("$db")
  done

  if (( ${#dbs[@]} == 1 )); then
    printf '%s\n' "${dbs[0]}"
    return 0
  fi
  if (( ${#dbs[@]} == 0 )); then
    return 1
  fi

  storeid="$(preferred_storeid "$dir")"
  if [[ -n "$storeid" && -e "$dir/Profile Groups/$storeid.sqlite" ]]; then
    printf '%s\n' "$dir/Profile Groups/$storeid.sqlite"
    return 0
  fi
  return 2
}

gen_storeid() {
  local s
  s="$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
  if [[ -z "$s" ]]; then
    s="$(printf '%08x' "$((RANDOM * 65536 + RANDOM))")"
  fi
  printf '%s' "$s"
}

init_group_db() {
  local db="$1"
  mkdir -p "$(dirname "$db")"
  "$SQLITE3_BIN" "$db" <<'SQL'
PRAGMA user_version = 7;
CREATE TABLE IF NOT EXISTS "Profiles" (
  id      INTEGER NOT NULL,
  path    TEXT NOT NULL UNIQUE,
  name    TEXT NOT NULL,
  avatar  TEXT NOT NULL,
  themeId TEXT NOT NULL,
  themeFg TEXT NOT NULL,
  themeBg TEXT NOT NULL,
  PRIMARY KEY(id)
);
CREATE TABLE IF NOT EXISTS "SharedPrefs" (
  id        INTEGER NOT NULL,
  name      TEXT NOT NULL UNIQUE,
  value     BLOB,
  isBoolean INTEGER,
  PRIMARY KEY(id)
);
CREATE TABLE IF NOT EXISTS "NimbusEnrollments" (
  id             INTEGER NOT NULL,
  profileId      INTEGER NOT NULL,
  slug           TEXT NOT NULL,
  branchSlug     TEXT NOT NULL,
  recipe         JSONB,
  active         BOOLEAN NOT NULL,
  unenrollReason TEXT,
  lastSeen       TEXT NOT NULL,
  setPrefs       JSONB,
  prefFlips      JSONB,
  source         TEXT NOT NULL,
  PRIMARY KEY(id),
  UNIQUE (profileId, slug) ON CONFLICT FAIL
);
CREATE TABLE IF NOT EXISTS "Heartbeats" (
  id              INTEGER NOT NULL,
  recipeId        TEXT NOT NULL UNIQUE,
  lastShown       INTEGER,
  lastInteraction INTEGER,
  PRIMARY KEY(id)
);
CREATE TABLE IF NOT EXISTS "MessagingSystemMessageImpressions" (
  id                  INTEGER PRIMARY KEY,
  messageId           TEXT UNIQUE NOT NULL,
  impressions         JSONB
);
CREATE TABLE IF NOT EXISTS "MessagingSystemMessageBlocklist" (
  id                  INTEGER PRIMARY KEY,
  messageId           TEXT UNIQUE NOT NULL
);
CREATE TABLE IF NOT EXISTS "NimbusSyncTimestamps" (
  id                  INTEGER NOT NULL,
  profileId           TEXT NOT NULL,
  collection          TEXT NOT NULL,
  lastModified        INTEGER NOT NULL,
  PRIMARY KEY(id),
  UNIQUE (profileId, collection) ON CONFLICT FAIL
);
SQL
}

insert_db_profile() {
  local db="$1" name="$2" path="$3"
  local next_id
  next_id="$("$SQLITE3_BIN" "$db" 'SELECT COALESCE(MAX(id),0)+1 FROM Profiles;' 2>/dev/null)"
  next_id="${next_id:-1}"

  local n p
  n="${name//\'/\'\'}"
  p="${path//\'/\'\'}"

  if ! "$SQLITE3_BIN" "$db" "INSERT INTO Profiles (id, path, name, avatar, themeId, themeFg, themeBg) VALUES ($next_id, '$p', '$n', 'heart', 'default-theme@mozilla.org', 'rgb(21,20,26)', 'rgb(240,240,244)');"; then
    err "Failed to update profile database: $db"
    return 1
  fi
}

update_profiles_ini() {
  local ini="$1" name="$2" dst_dir="$3" storeid="$4"

  mkdir -p "$(dirname "$ini")"

  local n
  n="$(next_profile_number "$ini")"

  # Build the [ProfileN] section text (used in each branch below).
  local block
  block="$( {
    printf '[Profile%d]\n' "$n"
    printf 'Name=%s\n' "$name"
    printf 'IsRelative=1\n'
    printf 'Path=%s\n' "$dst_dir"
    if [[ -n "$storeid" ]]; then
      printf 'StoreID=%s\n' "$storeid"
    fi
  } )"

  # If the file does not exist yet, create it with a [General] block and the
  # new profile.
  if [[ ! -f "$ini" || ! -s "$ini" ]]; then
    {
      printf '[General]\n'
      printf 'StartWithLastProfile=1\n'
      printf 'Version=2\n'
      printf '\n'
      printf '%s\n' "$block"
    } > "$ini"
    return 0
  fi

  # Otherwise, rewrite the file so the new [ProfileN] section lands right
  # after the [General] block and before any [Install...]/[Profile...]
  # sections. This matches Firefox's expected layout ([General], [Profile*],
  # [Install*]) and avoids appending the profile after an [Install*] block.
  # It also normalises StartWithLastProfile to 1 so the imported profile can
  # be selected on startup.
  local tmp
  tmp="$ini.tmp"
  : > "$tmp"

  local section="" in_general=0 written=0
  local has_start=0 has_version=0
  local line trimmed
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"

    if [[ "$trimmed" == [* ]]; then
      section="${trimmed#[}"
      section="${section%]}"

      # Leaving [General] and about to enter another section: flush the
      # profile and any missing [General] keys first.
      if (( in_general )) && (( ! written )) && [[ "$section" != General* ]]; then
        {
          (( has_start ))  || printf 'StartWithLastProfile=1\n'
          (( has_version )) || printf 'Version=2\n'
          printf '\n'
          printf '%s\n' "$block"
          printf '\n'
        } >> "$tmp"
        written=1
        in_general=0
      fi

      if [[ "$section" == General* ]]; then
        in_general=1
      fi
    fi

    # While in [General], rewrite StartWithLastProfile=0 to 1 and track which
    # keys are present.
    if (( in_general )); then
      if [[ "$trimmed" == StartWithLastProfile=* ]]; then
        has_start=1
        line='StartWithLastProfile=1'
      elif [[ "$trimmed" == Version=* ]]; then
        has_version=1
      fi
    fi

    printf '%s\n' "$line" >> "$tmp"
  done < "$ini"

  # If the file ended while still inside [General] (or never contained another
  # section), flush the profile after it.
  if (( in_general )) && (( ! written )); then
    {
      (( has_start ))  || printf 'StartWithLastProfile=1\n'
      (( has_version )) || printf 'Version=2\n'
      printf '\n'
      printf '%s\n' "$block"
      printf '\n'
    } >> "$tmp"
    written=1
  fi

  # If there was no [General] block at all, prepend one plus the new profile.
  if (( ! written )); then
    {
      printf '[General]\n'
      printf 'StartWithLastProfile=1\n'
      printf 'Version=2\n'
      printf '\n'
      printf '%s\n' "$block"
      printf '\n'
    } >> "$tmp"
  fi

  mv "$tmp" "$ini"
}

cmd_import() {
  local name="Default" dir="" zipfile=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ -n "${2:-}" ]] || { err "Missing value for --name"; exit 2; }
        name="$2"; shift 2 ;;
      --name=*)
        name="${1#--name=}"; shift ;;
      --dir)
        [[ -n "${2:-}" ]] || { err "Missing value for --dir"; exit 2; }
        dir="$2"; shift 2 ;;
      --dir=*)
        dir="${1#--dir=}"; shift ;;
      -h|--help)
        usage; return 0 ;;
      -*)
        err "Unknown import option: $1"
        usage >&2
        exit 2 ;;
      *)
        if [[ -n "$zipfile" ]]; then
          err "Unexpected extra argument: $1"
          exit 2
        fi
        zipfile="$1"; shift ;;
    esac
  done

  [[ -n "$name" ]] || { err "Profile name must not be empty."; exit 2; }
  [[ -n "$zipfile" ]] || { err "Missing archive argument."; err "Usage: ${0##*/} import [--name NAME] [--dir DIR] ARCHIVE.zip"; exit 2; }
  [[ -f "$zipfile" ]] || { err "Archive not found: $zipfile"; exit 1; }

  command -v unzip >/dev/null 2>&1 || { err "The 'unzip' utility is required for import but was not found in PATH."; exit 1; }
  [[ -x "$SQLITE3_BIN" ]] || { err "The sqlite3 utility ($SQLITE3_BIN) is required for import but was not found."; exit 1; }

  local top
  top="$(zip_top_dir "$zipfile")"

  resolve_target_dir "$dir"
  local target_dir="$TARGET_DIR"

  local dst_dir
  dst_dir="$(unique_dir_name "$target_dir" "$top")"

  # Determine which SQLite profile-group database to update.
  local group_db="" rc=0 storeid=""
  if group_db="$(resolve_group_db "$target_dir")"; then
    rc=0
  else
    rc=$?
  fi

  if (( rc == 0 )); then
    storeid="$(basename "$group_db")"
    storeid="${storeid%.sqlite}"
  elif (( rc == 1 )); then
    storeid="$(gen_storeid)"
    group_db="$target_dir/Profile Groups/$storeid.sqlite"
  else
    err "Multiple profile-group databases found in '$target_dir':"
    local g
    for g in "$target_dir"/Profile\ Groups/*.sqlite; do
      err "  $g"
    done
    err "Cannot determine which one to update."
    exit 1
  fi

  # Extract to a temporary location first, then move into place.
  local tmp
  tmp="$(mktemp -d)"
  if ! unzip -q "$zipfile" -d "$tmp"; then
    err "Failed to extract '$zipfile'."
    rm -rf "$tmp"
    exit 1
  fi
  if [[ ! -d "$tmp/$top" ]]; then
    err "Archive does not contain the expected directory '$top'."
    rm -rf "$tmp"
    exit 1
  fi

  mv "$tmp/$top" "$target_dir/$dst_dir"
  rm -rf "$tmp"

  if (( rc == 1 )); then
    init_group_db "$group_db"
  fi

  update_profiles_ini "$target_dir/profiles.ini" "$name" "$dst_dir" "$storeid"

  if ! insert_db_profile "$group_db" "$name" "$dst_dir"; then
    exit 1
  fi

  printf 'Imported profile "%s" into %s\n' "$name" "$target_dir/$dst_dir"
  printf 'Updated: %s and %s\n' "$target_dir/profiles.ini" "$group_db"
}

# ---------------------------------------------------------------------------
# Delete
# ---------------------------------------------------------------------------

cmd_delete() {
  local name=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ -n "${2:-}" ]] || { err "Missing value for --name"; exit 2; }
        name="$2"; shift 2 ;;
      --name=*)
        name="${1#--name=}"; shift ;;
      -h|--help)
        usage; return 0 ;;
      -*)
        err "Unknown delete option: $1"
        usage >&2
        exit 2 ;;
      *)
        if [[ -n "$name" ]]; then
          err "Unexpected extra argument: $1"
          exit 2
        fi
        name="$1"; shift ;;
    esac
  done

  [[ -n "$name" ]] || { err "Profile name must not be empty."; err "Usage: ${0##*/} delete NAME"; exit 2; }

  collect_profiles
  if [[ ${#P_ID[@]} -eq 0 ]]; then
    err "No Firefox profiles found."
    exit 1
  fi

  # Resolve the profile by name.
  local -a matches=()
  local i
  for i in "${!P_NAME[@]}"; do
    [[ "${P_NAME[$i]}" == "$name" ]] && matches+=("$i")
  done

  if (( ${#matches[@]} == 0 )); then
    err "No profile named '$name' found."
    err "Use 'fpm.sh list' to see available profiles."
    exit 1
  elif (( ${#matches[@]} > 1 )); then
    err "Multiple profiles match the name '$name':"
    for i in "${matches[@]}"; do
      err "  ${P_ID[$i]}  ${P_PATH[$i]}"
    done
    err "Refusing to delete an ambiguous name."
    err "Use a unique profile name, then retry."
    exit 1
  fi

  local idx="${matches[0]}"
  local src="${P_SRC[$idx]}"
  local id="${P_ID[$idx]}"
  local path="${P_PATH[$idx]}"

  if [[ "$id" == sqlite:* ]]; then
    # SQLite profile group. id is sqlite:<storeid>#<id>.
    local storeid dbid
    storeid="${id#sqlite:}"
    dbid="${storeid##*#}"
    storeid="${storeid%#*}"
    local db="$src/Profile Groups/$storeid.sqlite"

    [[ -x "$SQLITE3_BIN" ]] || { err "The sqlite3 utility ($SQLITE3_BIN) is required for delete but was not found."; exit 1; }
    [[ -e "$db" ]] || { err "Profile database not found: $db"; exit 1; }

    if ! "$SQLITE3_BIN" "$db" "DELETE FROM Profiles WHERE id = $dbid;" 2>/dev/null; then
      err "Failed to remove profile from database: $db"
      exit 1
    fi
  else
    # Legacy profiles.ini entry. Remove the matching [ProfileX] section.
    local ini="$src/profiles.ini"
    [[ -f "$ini" ]] || { err "profiles.ini not found: $ini"; exit 1; }

    if ! awk -v target="$id" '
      function flush() {
        if (have && sec != target) {
          for (i = 0; i < n; i++) print buf[i]
          if (!printed) printed = 1
        }
        have = 0; n = 0
      }
      {
        line = $0
        if (line ~ /^[[:space:]]*\[[^]]+\]/) {
          flush()
          sec = line
          sub(/^[[:space:]]*\[/, "", sec)
          sub(/\][[:space:]]*$/, "", sec)
          have = 1
        } else if (have) {
          buf[n++] = line
        } else {
          print line
        }
      }
      END { flush() }
    ' "$ini" > "$ini.tmp"; then
      err "Failed to rewrite profiles.ini"
      exit 1
    fi
    mv "$ini.tmp" "$ini"
  fi

  printf 'Deleted profile "%s" (%s) from %s\n' "$name" "$id" "$src"
  printf 'Note: the profile directory %s was left in place.\n' "$path"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  if [[ -z "${HOME:-}" ]]; then
    err "HOME is not set; cannot locate Firefox profile directories."
    exit 1
  fi

  local cmd="${1:-list}"
  if (( $# )); then
    shift
  fi

  case "$cmd" in
    list)
      cmd_list
      ;;
    export)
      cmd_export "$@"
      ;;
    import)
      cmd_import "$@"
      ;;
    delete)
      cmd_delete "$@"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      err "Unknown command: $cmd"
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
