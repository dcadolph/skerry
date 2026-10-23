# Skerry Note Format

The note format is the contract between every current and future Skerry client. Any program
that reads and writes this format is a full citizen. The format favors longevity over
cleverness: plain text, real folders, no proprietary containers.

## Library

A library is any folder. Notes are Markdown files inside it. Subfolders are organizational
folders, nested to any depth. Nothing about the library requires Skerry to open it.

Reserved entries at the library root:

| Entry      | Purpose                                                          |
|------------|------------------------------------------------------------------|
| `.skerry/` | Rebuildable cache (search index, thumbnails). Safe to delete.    |
| `assets/`  | Attachments referenced by notes via relative links.              |

Folders and files whose names start with a dot are ignored.

## Note file

A note is a UTF-8 text file. Markdown with the `.md` extension is the default and the
richest citizen; `.markdown` is treated identically. Plain text `.txt` notes carry front
matter and metadata but render without Markdown styling. HTML `.html` notes are edited as
source and saved body-only, never gaining a front matter block. An optional front matter
block carries metadata. Markdown bodies are CommonMark.

```markdown
---
id: 7A0E38D2-4CBB-4E30-9A57-2A9F3D1B6C11
title: Ferry timetable research
tags: [travel, scotland]
starred: true
pinned: false
archived: false
created: 2026-07-13T09:30:00Z
updated: 2026-07-13T10:02:41Z
---

# Ferry timetable research

Body starts here.
```

## Front matter

Delimited by `---` lines at the top of the file. Keys are lowercase. Unknown keys are
preserved on rewrite, never dropped. All keys are optional; a bare Markdown file with no
front matter is a valid note.

| Key         | Type         | Meaning                                                    |
|-------------|--------------|------------------------------------------------------------|
| `id`        | UUID string  | Stable identity across renames and moves.                  |
| `title`     | string       | Display title. Fallback: first H1, then file name.         |
| `tags`      | string list  | Inline form `[a, b]`. Tag names are case-insensitive.      |
| `starred`   | bool         | Shown in the starred view.                                 |
| `pinned`    | bool         | Pinned to the top of its folder listing.                   |
| `archived`  | bool         | Hidden from normal views, kept in search behind a filter.  |
| `locked`    | bool         | Body shown only after device-owner authentication.         |
| `encrypted` | bool         | Body, title, and tags sealed as ciphertext on disk.        |
| `created`   | ISO 8601 UTC | Creation time. File birth time is the fallback.            |
| `updated`   | ISO 8601 UTC | Last content change. File mtime is the fallback.           |

Scalar values are unquoted unless they contain `#`, `:`, or leading/trailing whitespace, in
which case they are double-quoted. Booleans are `true` or `false`.

A locked note gates its body behind authentication in clients and stays out of full-text
search indexes. The file itself remains plain text on disk; `locked` is an interface
guard, not encryption.

## Encryption

An encrypted note protects its contents at rest with a passphrase, so a copy on a synced
folder, a NAS, or a backup drive reveals nothing about the note. The file is a sealed
envelope: plain front matter carries only `id` and `encrypted: true`, and the body is the
base64 blob `salt || nonce || ciphertext || tag`. The ciphertext is the note's full inner
document, its title and tags and dates and body, encrypted with AES-256-GCM under a key
derived from the passphrase by PBKDF2-SHA256.

```markdown
---
id: 7A0E38D2-4CBB-4E30-9A57-2A9F3D1B6C11
encrypted: true
---

c2FsdG5vbmNlY2lwaGVydGV4dGFuZHRhZ2Jhc2U2NA==
```

The file name is the note's `id` with a `.md` extension, never the title, so the name leaks
nothing either. Only that an encrypted note exists, its position in the folder tree, and its
file timestamps are observable without the passphrase. Encrypted notes stay out of the
search index entirely. The passphrase is the user's alone; a client that lacks it can copy,
move, and back up the file but cannot read it.

### Master-key format

A library may upgrade to a key hierarchy. A random 256-bit master key encrypts the notes, and
that master key is itself wrapped by a key derived from the passphrase, stored in a
`.skerryvault` keyfile at the library root. A note sealed this way carries `encv: 2` in its
plain front matter, and its body is `base64(nonce || ciphertext || tag)` under the master key,
with no per-note salt or key derivation. Because the slow derivation runs once at unlock rather
than per note, the passphrase can use a higher iteration count, changing the passphrase only
re-wraps the master key, and a recovery code can wrap the same master key as a second way in.
The keyfile reveals nothing without the passphrase or recovery code, and a note without
`encv: 2` uses the passphrase-per-note form above, so both coexist during migration.

### Keyfile versions and key derivation

Each wrapping in the keyfile names its KDF, so the derivation can strengthen over time
without breaking older libraries:

- Version 2 wrappings carry no `kdf` field and use PBKDF2-SHA256 with the stored iteration
  count (600,000 by default).
- Version 3 wrappings carry `kdf: "argon2id"` with `memory` (KiB), `iterations` (passes),
  and `parallelism` (lanes). New wrappings use RFC 9106's memory-constrained
  recommendation: 64 MiB, 3 passes, 4 lanes. Argon2id is memory-hard, which makes GPU and
  ASIC password guessing dramatically more expensive than PBKDF2 allows.

A client that opens a version 2 keyfile re-wraps the passphrase wrapping under Argon2id
after the first successful unlock; the recovery wrapping upgrades the next time the
recovery code itself is used, since upgrading requires the secret in hand. A wrapping with
an unrecognized `kdf` name must be refused, never guessed at.

### Cipher agility

AES-256-GCM is the default everywhere. ChaCha20-Poly1305 is available as an alternative;
both produce `nonce || ciphertext || tag` with a 12-byte nonce and a 16-byte tag, so blobs
keep one shape across ciphers. Where the cipher is recorded:

- A master-key note envelope sealed with a non-default cipher carries `encv: 3` and
  `alg: chacha20poly1305` in its plain front matter. `encv: 2` always means AES-256-GCM.
- A keyfile wrapping names its cipher in a `cipher` field; absence means AES-256-GCM. An
  unrecognized name must be refused.
- Sealed attachments (`.skbox`) and sync objects carry no framing; a reader tries each
  cipher, and the authentication tag guarantees only the right one opens. A wrong-cipher
  attempt can never produce wrong plaintext, only failure.

## Attachments

Attachments live in `assets/` at the library root and are referenced with standard relative
Markdown links, for example `![diagram](../assets/diagram.png)`. Clients must not rewrite
attachment links they did not create.

## Index

`.skerry/index.db` is a SQLite database with an FTS5 table over title, tags, and body. It is
a cache: any client may delete and rebuild it at any time, and its absence must never lose
user data.

## Sync and backup

The library syncs and backs up as ordinary files: iCloud Drive, Syncthing, rsync to a NAS,
SMB mounts, S3-compatible tools. Conflicted copies produced by file-sync tools appear as
sibling files and are surfaced to the user, not merged silently.

Skerry also ships its own encrypted sync over storage the user owns. On the remote,
everything lives under a `Skerry Sync/` folder:

| Entry                 | Purpose                                                        |
|-----------------------|----------------------------------------------------------------|
| `objects/<id>`        | One library file, AES-256-GCM sealed under the vault master key. The id is the first 32 hex chars of SHA-256 of the file's library-relative path. |
| `manifest.skmanifest` | Sealed JSON listing every object: path, content hash, update time, and delete tombstones. |
| `keyfile.skerryvault` | The wrapped vault keyfile, copied verbatim; it is passphrase-wrapped by design. |

The remote only ever holds ciphertext and opaque names. Reconciliation is a three-way merge
against per-device state in `.skerry/sync-state.json`: edits flow both ways, deletes
propagate through tombstones that expire after 30 days, an edit beats a delete, and a file
changed on two devices at once keeps both versions, the remote one as a `(conflict ...)`
sibling. Files another device deleted are parked under `.skerry/sync-deleted/` for 30 days
before cleanup.
