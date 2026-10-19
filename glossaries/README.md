# Glossary bundles

SideWave starts with no bundled glossaries. Vocabulary > Browse bundles and
Settings > Speech Recognition > Glossary bundles open the same GitHub catalog.
The catalog is empty until reviewed bundles are published. A private repository
cannot serve the unauthenticated public catalog; no GitHub token is requested.

A download creates a read-only subscription with a stable catalog ID. Updates are
manual by default. A user can enable daily checks for an individual bundle while
SideWave is open. No checks run at startup unless a bundle has that explicit opt-in.
Search runs locally over the downloaded index. Catalog and file transfers appear in
Data Transparency. No vocabulary, audio, transcripts, or usage data are uploaded.

Updates atomically replace publisher content in that subscription only. The bundle's
local identity, enabled state, template links, automatic-update preference, and
hidden words remain intact. Failed integrity checks or writes keep the previous
active version. Removing an entry from the catalog does not delete installed words.
The user can remove the subscription or make an independent copy.

Use Make a personal copy to edit a complete bundle, or open a word and copy it to a
personal glossary. Copies receive new local identities and never sync. An enabled
personal word takes priority over a bundle word with the same spelling. Use this
bundle word can be switched off locally when a replacement is too aggressive; that
choice survives updates, including removal and later reintroduction of the word.

## Publishing a revision

Export one personal glossary from SideWave and review its content. Save each revision
under an immutable versioned filename, such as `plant_science/2026.10.1.json`.
Update its catalog entry and the new file together in one repository commit. Never
replace the contents of an already-published revision file. This prevents a cached
index from pointing at changed bytes during publication.

| Field | Value |
| --- | --- |
| `id` | Stable identifier, for example `plant_science`; never change it for a revision |
| `name` | Short display name (the app displays at most 30 characters) |
| `description` | Scope and intended use |
| `version` | Human-readable content version |
| `path` | Versioned JSON path relative to this directory |
| `sha256` | SHA-256 digest of the exact file bytes |
| `bytes` | Exact file length, at most 8 MiB |
| `termCount` | Number of terms, at most 5,000 |
| `tags` | Array of search terms |
| `releaseNotes` | Optional explanation of changes, at most 8,000 characters |

Each file must contain exactly one glossary in version 1 of the
`sidewave.glossary` export format. Terms support `canonical`, `aliases`,
`pronunciation`, `category`, `definition`, `usageNote`, `priority`, and `scope`.
Scope is 1 for replacement, 2 for a refinement hint, or 3 for both. Priority 1 pins a
refinement hint; priority 2 includes it when relevant. Matching thresholds remain
owned by the recognition pipeline; bundle files cannot execute code or change
engine settings. Pronunciation is written as likely recognized words, not IPA.

Canonical spellings must be nonempty and unique ignoring case. Review ambiguous
aliases, short words, word boundaries, pronunciation, licensing, and unintended
replacement before publishing. Prefer conservative aliases; remove an entry if
newer models already recognize it reliably and its correction causes false matches.

The app compares revisions by checksum, preserves unchanged word identities, and
records added, edited, and removed words with publisher notes. The latest 100 update
records for each installed bundle stay on the Mac. Renaming a canonical spelling
appears as one removal and one addition. Personal copies are never modified.
