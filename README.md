# Mac Uninstall

Removing a Mac app by dragging it to the Trash leaves its data behind — preferences,
caches, containers, launch daemons, privileged helpers. This app finds the rest of the
footprint, shows you exactly what it found and why, and moves it somewhere you can get
it back from.

## Status

Working v1. Scanning, review, and removal all function end to end. Distributed directly
(not via the Mac App Store), because the sandbox cannot read other apps' Library folders
and a sandboxed uninstaller cannot honestly claim to be thorough.

## Build and run

```bash
Scripts/build-app.sh release
```

The signed bundle lands in `dist/MacUninstall.app`.

**Keep this repository out of iCloud Drive or any syncing folder.** A file provider
re-attaches a `com.apple.FinderInfo` xattr within seconds of each write, and `codesign`
refuses to seal a bundle carrying one, so builds fail strict verification no matter how
often the xattr is stripped. Sync can also revert uncommitted edits without warning.

**Install it to `/Applications` to use the privileged helper.** launchd only resolves a
bundled daemon for apps in Applications; anywhere else, `SMAppService` reports the
service as not found. The app detects this and says so rather than failing silently.

```bash
Scripts/notarize.sh
```

```bash
swift test
```

Grant **Full Disk Access** in System Settings → Privacy & Security. Without it, protected
folders read as *empty* rather than erroring, so leftovers are silently missed. The app
detects this and shows a warning banner instead of pretending the scan was complete.

Full Disk Access is bound to the code-signing identity, so an ad-hoc build must be
re-granted after each rebuild. Set `MACUNINSTALL_SIGN_IDENTITY` to a Developer ID to get
a stable identity you can also notarise.

## How matching works

A bundle identifier alone finds only a fraction of a real app's footprint. Six signals
are collected per app and matched as a union, each carrying its own confidence:

| Signal | Example | Confidence |
| --- | --- | --- |
| Bundle ID and dotted children | `com.acme.App.helper.plist` | Certain |
| Nested helper and login-item IDs | `com.acme.App.Updater` | Certain |
| Reverse-DNS siblings | `com.acme.SharedUpdater` | Likely |
| Executable or display name | `~/Library/Logs/Acme` | Likely |
| Team identifier prefix | `AB12CD34EF.com.acme.group` | Likely |
| Vendor name | `Application Support/AcmeSoft` | Needs review |
| File contents referencing the app | `com.todesktop.230313mzl4w4u92.plist` | Needs review |

That last row matters: Electron and ToDesktop apps store data under opaque identifiers
that no name rule can match, so unmatched preference files are searched for the app's
identifier and bundle path.

**Only `Certain` matches are ticked by default.** Everything else is listed with a
plain-English reason and left for you to decide.

## Safety

The core risk in this category is deleting something shared. The design answers it in
four places:

1. **Vendor folders are never claimed whole.** Uninstalling Chrome proposes
   `Application Support/Google/Chrome`, not `Application Support/Google`, because the
   latter also holds Google Drive's data. The scanner descends into a shared parent and
   prefers specific children.
2. **Embedded third-party frameworks are not evidence.** Sparkle, Electron, and crash
   reporters ship inside hundreds of apps. Only nested bundle IDs within the app's own
   namespace count.
3. **macOS system files are never attributed to an app.** `com.apple.dock.plist` names
   every app with a Dock tile; being mentioned in a shared system registry is normal and
   proves nothing.
4. **Nothing is ever hard-deleted.** User files go to the Trash, so Finder's *Put Back*
   works. Root-owned files are moved to a timestamped quarantine folder with a
   `MANIFEST.txt` of their original paths.

Every path is re-validated against `ProtectedPaths` immediately before removal,
independently of how it entered the plan. The filesystem root, system directories,
top-level user folders, Library container roots, keychains, and iCloud/CloudStorage
trees are refused unconditionally, as is anything outside the allowed roots or reached
through a symlink that escapes them.

Points 1–3 were each found by running the scanner against a real Mac; all three would
have caused data loss and none were visible against synthetic fixtures. They are locked
down by regression tests in `CrossContaminationTests`.

Running apps are quit before removal — many rewrite their preferences on exit and would
otherwise recreate the files just deleted.

## Layout

```
Sources/MacUninstallCore/     Pure Foundation; safe to link into a root process
  Models/       AppIdentity, Leftover, Confidence, ScanResult
  Discovery/    AppScanner — bundle identity, code signature, nested helpers
  Scanning/     SearchLocation catalog, Matcher, LeftoverScanner
  Removal/      Remover, PrivilegedExecutor, HelperClient, HelperValidation
  Support/      ProtectedPaths, PermissionChecker
Sources/MacUninstallHelper/   The root daemon: XPC listener and privileged operations
Sources/MacUninstallApp/      SwiftUI app, plus RunningAppGuard (the only AppKit user)
Tests/                        58 tests, incl. read-only smoke tests against this Mac
```

## The privileged helper

System-level leftovers — launch daemons, privileged helper tools, installer receipts —
need root to remove. Rather than prompting for a password on every uninstall, the app
ships a daemon that `SMAppService` installs from inside its own bundle. There is no
separate installer and no `setuid` binary. The user approves it once under Login Items.

The interface across that boundary is a fixed vocabulary of two operations —
`quarantine(items:into:)` and `bootout(label:isDaemon:)` — not "run this command". An
earlier design passed a shell script, which is fine for a one-shot authenticated prompt
but would be a local privilege-escalation hole in a daemon that stays installed:
anything able to reach the Mach service would get arbitrary root execution.

The daemon trusts nothing the client sends:

- Callers are pinned to the app's code signature with `setCodeSigningRequirement`. The
  requirement is derived from the helper's *own* signature at runtime, so one source
  tree builds correctly for Developer ID and for local ad-hoc use without a build-time
  substitution that could silently produce a helper accepting anyone.
- Every path is re-validated against `ProtectedPaths` on the root side.
- The destination must be inside the user's quarantine area, or "move a file as root"
  becomes "write anywhere as root".
- Launchd labels are restricted to a strict character set, because the label is
  concatenated into a domain target.

`MacUninstallCore` links no UI framework, so nothing from AppKit is ever loaded into a
root process. If the helper is absent or unapproved, `AdaptivePrivilegedExecutor` falls
back to the authenticated prompt — the app works before approval rather than
dead-ending.

## Known limitations

- Full Disk Access and the helper approval both bind to the signing identity, so both
  must be re-granted whenever the certificate changes.
- Mac App Store item IDs are only read when an app declares `ITunesItemIdentifier`;
  parsing the signed receipt would cover the rest.
- A scan takes a few seconds on a full Library. Results render before sizes are
  measured, so the list is usable immediately.
- No undo *inside the app* yet — recovery is via the Trash or the quarantine manifest.
