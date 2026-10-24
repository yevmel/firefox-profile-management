# FPM — Firefox Profile Management

A small Bash CLI for discovering, exporting and importing Firefox profiles on
Linux. It understands **both** places where Firefox stores profile metadata:

- the legacy `profiles.ini` file, and
- the newer SQLite-backed **Profile Groups** store.

This matters because the modern Firefox profile picker reads from SQLite — not
from `profiles.ini` (see [The import challenge](#the-import-challenge)).

## Features

| Action | What it does |
| --- | --- |
| `list` | Lists every profile found (name, identifier, path). This is the default action. |
| `export` | Zips a profile directory into the current directory. |
| `import` | Extracts a profile archive and registers it in **both** `profiles.ini` and the embedded SQLite store. |

## Requirements

- [`sqlite3`](https://sqlite.org/cli.html) (defaults to `/usr/bin/sqlite3`, overridable via `SQLITE3_BIN`)
- `zip` (for `export`) and `unzip` (for `import`)

## Usage

### List profiles

```bash
./fpm.sh            # "list" is the default action
./fpm.sh list
```

Example output:

```
Found 3 Firefox profile(s) in 1 location(s).

Source: snap (/home/user/snap/firefox/common/.mozilla/firefox)
  ID        NAME     PATH
  Profile0  Private  /home/user/snap/firefox/common/.mozilla/firefox/6mu9dp3i.default
  Profile1  Default  /home/user/snap/firefox/common/.mozilla/firefox/kffddu03.default-release *

(*) default profile
```

### Export a profile

```bash
./fpm.sh export --name Default
./fpm.sh export --name Default --output my-profile.zip
./fpm.sh export --id Profile0 --output private.zip
```

`--name` and `--id` are mutually exclusive; exactly one is required.
`--output` defaults to `firefox-profile.zip`.

The archive contains the profile directory as its single top-level folder:

```
my-profile.zip
└── kffddu03.default-release/
    ├── prefs.js
    ├── places.sqlite
    └── ...
```

### Import a profile

```bash
./fpm.sh import --name "Restored Default" my-profile.zip
```

If more than one Firefox directory is found (for example a native install and a
snap install), `fpm.sh` refuses to guess and asks for `--dir`:

```
Multiple Firefox directories found:
  native (/home/user/.mozilla/firefox)
  snap (/home/user/snap/firefox/common/.mozilla/firefox)
Specify which one to import into with --dir.
```

```bash
./fpm.sh import --dir snap --name "Restored Default" my-profile.zip
./fpm.sh import --dir "$HOME/.mozilla/firefox" my-profile.zip
```

`--dir` accepts a full path or one of the short labels `native`, `snap`,
`flatpak`. `--name` defaults to `Default`.

## Where FPM looks

| Build | Directory |
| --- | --- |
| Native / distro | `~/.mozilla/firefox` |
| Snap | `~/snap/firefox/common/.mozilla/firefox` |
| Flatpak | `~/.var/app/org.mozilla.firefox/.mozilla/firefox` |

Additional directories can be provided through `FPM_PROFILE_DIRS`
(colon-separated):

```bash
FPM_PROFILE_DIRS="/mnt/backup/firefox:/tmp/ff" ./fpm.sh list
```

Within each directory, FPM reads:

- `profiles.ini` (legacy backend)
- `Profile Groups/*.sqlite` (new SQLite backend)

## The import challenge

For a long time, all Firefox profile metadata lived in a single INI file:

```ini
[Profile0]
Name=Default
IsRelative=1
Path=kffddu03.default-release
```

Restoring a profile was easy: copy the profile directory somewhere, append a
`[ProfileN]` section, and you were done.

Newer Firefox versions (138+) introduced **Profile Groups**, where each group's
metadata lives in an embedded SQLite database:

```
~/.mozilla/firefox/Profile Groups/
├── 9d3233fc.sqlite
└── 373817ac.sqlite
```

The profile list used by the startup dialog — the **"Choose a Firefox profile"**
dialog — is served by this SQLite store. Each database contains a `Profiles`
table:

```sql
CREATE TABLE "Profiles" (
  id      INTEGER NOT NULL,
  path    TEXT NOT NULL UNIQUE,
  name    TEXT NOT NULL,
  avatar  TEXT NOT NULL,
  themeId TEXT NOT NULL,
  themeFg TEXT NOT NULL,
  themeBg TEXT NOT NULL,
  PRIMARY KEY(id)
);
```

This is the part that trips up manual imports: **if you only update
`profiles.ini`, the imported profile is missing from the "Choose a Firefox
profile" dialog.** The legacy code path may still be able to launch it, but the
new profile picker never sees it, because it never queries `profiles.ini` — it
reads the `Profiles` table.

Getting the SQLite update right by hand is fiddly:

- The profile `path` is stored **relative** to the Firefox directory (for
  example `kffddu03.default-release`), not as an absolute path.
- `avatar`, `themeId`, `themeFg` and `themeBg` are `NOT NULL`, so a bare
  `INSERT` with only `id`/`path`/`name` fails.
- `id` must be unique; it is not auto-assigned unless the table declares it so.
- A profile group database can contain more than just `Profiles`; Firefox
  tracks a schema version via `PRAGMA user_version` (observed as `7`).
- With several `Profile Groups/*.sqlite` databases present, you must pick the
  right one. The legacy `profiles.ini` links profiles to a group through a
  `StoreID=` key that matches the database filename (`9d3233fc.sqlite`).

`fpm.sh import` automates all of that:

1. Extracts the single top-level profile directory from the archive.
2. Moves it into the target Firefox directory under a collision-free name.
3. Appends the profile to `profiles.ini` (including the correct `StoreID`).
4. Inserts the row into the right `Profiles` table — populating every required
   column with Firefox's theme defaults — or creates a compatible group
   database (full schema, `user_version = 7`) when none exists yet.

The result is a profile that appears both in the legacy store and in the
"Choose a Firefox profile" dialog.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Operational error (profile not found, ambiguous target, bad archive, …) |
| `2` | Usage error (missing/unknown argument) |
