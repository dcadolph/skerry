![Skelly the puffin standing on a skerry](skerry-banner.png)

# Skerry

![Platform](https://img.shields.io/badge/platform-macOS%2014+%20%7C%20iOS%2017+-1f6feb)
![Swift](https://img.shields.io/badge/Swift-6-f05138?logo=swift&logoColor=white)
![Encryption](https://img.shields.io/badge/encryption-AES--256--GCM-2ea44f)
![Local-first](https://img.shields.io/badge/local--first-no%20accounts-8957e5)
![Tests](https://img.shields.io/badge/tests-71%20passing-2ea44f)

**Notes that live in your own files, sealed with a key only you hold.**

Skerry is a Markdown notes app built on one rule: your notes are plain files in folders you
control. Search, tags, stars, and archiving come from a rebuildable index, never a
proprietary database. Any note can be sealed with AES-256-GCM so that even its title and file
name reveal nothing on disk. Back up with any tool that copies files.

The on-disk contract is [FORMAT.md](FORMAT.md). Any client that speaks the format is a full
citizen, and the format outlives the app.

## Why Skerry

- **Local-first, no accounts.** No backend, no sign-up, no telemetry. The files on disk are
  the truth.
- **Real encryption.** A random 256-bit master key seals each note with AES-256-GCM, and that
  master key is wrapped by an Argon2id-stretched key from your passphrase, held in the Keychain
  behind Face ID or Touch ID. An encrypted note is an opaque envelope: title, tags, dates, and
  body are all ciphertext, the file name is a random id, and the note stays out of the search
  index entirely.
- **Zero lock-in.** Plain Markdown and real folders. Delete the app and your notes are still
  there, readable in any editor.
- **Yours to sync and back up.** iCloud Drive, Syncthing, rsync, a NAS share, or Skerry's own
  folder snapshots to any location you pick.

## Writing

The editor highlights Markdown as you type and conceals the syntax around the cursor, so
prose stays clean while the markers stay editable. Lists and quotes continue on Return and an
empty item ends the block. Task boxes toggle with a tap and strike through when done. Writing
`[[note name]]` links to another note, clicking a link to a note that does not exist yet
creates it, and a bar under the editor lists every note that links back. Paste an image and it
lands in the library's `assets/` folder with a relative link. On iPhone a formatting bar and a
full alternative keyboard put headings, emphasis, lists, and code a tap away. Focus mode
strips the window down to the text.

## Encryption and privacy

Set a passphrase once, then seal any note from its menu. Your passphrase never encrypts notes
directly: it is stretched with Argon2id into a key that wraps a random 256-bit master key, and
that master key seals each note with AES-256-GCM. Nothing plaintext is ever written for a
sealed note: the file becomes an opaque `<id>.md` envelope, the search index is redacted, and
the passphrase lives in the Keychain released only after you authenticate. Because notes are
sealed under the master key, changing the passphrase only re-wraps that key rather than
re-encrypting every note, and a one-time recovery code can wrap the same key as a second way
in. Notes can also be locked behind device authentication without encryption when you only
need a gate, not ciphertext. The full scheme is documented in FORMAT.md.

## Export and print

Export a note to Markdown, Plain Text, HTML, Rich Text, or PDF, or copy it to the clipboard as
Markdown, HTML, or Plain Text. On iPhone you can print or share through the system sheet; on
Mac a save panel writes the file wherever you choose.

## Finding things

The command palette jumps to any note by fuzzy match over titles and paths. Full-text search
runs on a SQLite FTS5 index with prefix matching, so results appear from the first keystrokes.
The sidebar carries starred and archived views, the folder tree, and every tag with a count.
Pinned notes hold the top of the list, and deleted notes rest in a real Trash for thirty days.

## Backup

Point Skerry at any folder through Files, iCloud Drive, or a NAS and it writes browsable
snapshots you can open anywhere, no archive to unpack. Turn on automatic backup and it snaps a
copy when the app leaves the foreground, keeping the newest ten and restoring any of them from
Settings.

## Your files

Skerry is native SwiftUI on macOS and iOS around one shared core. Renaming or moving a note
moves the file on disk. Editing a file in another tool shows up within about a second on macOS
and on return to the foreground on iOS. Nothing lives anywhere except your folder.

## Keyboard shortcuts (macOS)

| Shortcut    | Action                          |
|-------------|---------------------------------|
| Cmd-N       | New note in the current folder  |
| Cmd-K       | Command palette                 |
| Cmd-O       | Open a library folder           |
| Cmd-Shift-F | Toggle focus mode               |

## The library

A library is any folder. Notes are `.md` files, folders are folders, attachments live in
`assets/`, and the only thing Skerry adds is a `.skerry/` cache holding the search index.
Delete the cache anytime and it rebuilds. No import or export step exists because there is
nothing to convert. Point iCloud Drive, Syncthing, rsync, or a NAS mount at the library and
every device sees the same notes. Skerry ships no sync protocol and no server, so there is
none to break or shut down.

## Building from source

Requires Xcode 16 or newer and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```
swift test                      # SkerryKit unit tests
xcodegen generate               # produces Skerry.xcodeproj from project.yml
xcodebuild -project Skerry.xcodeproj -scheme SkerryMac build
xcodebuild -project Skerry.xcodeproj -scheme SkerryiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

`swift run Skerry` also works for a quick unbundled macOS run during development.

## Status

Early and moving fast, dogfooded daily on a real iPhone. Encryption of titles and file names,
folder-snapshot backup, and the full export suite have shipped. The roadmap points at themes
and a deeper Settings screen, whole-library export as a static site, cloud and backup targets
over WebDAV and S3, a git-backed history time machine, and photo-to-note text capture.
