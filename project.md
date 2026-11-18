# Project: thezion-clash-rules

Long-term memory for this project. Memory file rules are in GEMINI.md; do not repeat them here.

## Purpose
Clash/mihomo rule-set repository for the zion club, built on top of [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules).
Published rule-sets are consumed raw from `main`:
`https://raw.githubusercontent.com/thezion-club/thezion-clash-rules/refs/heads/main/<file>`

Rule-sets and configurations are updated by running `bash update.sh` from the repository root.

## Settings
| Setting | Value |
|--|--|
| Project root | `/Users/jiayuan/thezion-clash-rules` |

## Folder layout
```
thezion-clash-rules/
  GEMINI.md                     Shared memory-file rules (same file in every project)
  project.md                    This file: rules, structure and long-term memory
  context.md, todo.md           Short-term and project task tracking (see GEMINI.md)
  memories/                     Task state and reference data
    task-state.md               Checkpoint of day-to-day task in progress
    task-todo.md                Day-to-day follow-ups from tasks
  .githooks/pre-commit          Blocks commit while context.md is not reset
  .gitignore
  upstream                      Loyalsoldier rule-set source URLs
  exclude.conf                  Exclusion patterns for downloaded rule-sets
  extract_asn.py                Script extracting CIDRs for target ASNs
  update.sh                     Pipeline script downloading and compiling rules
  thezion-config.conf           Main clash config
  thezion-direct.conf           DIRECT rules (includes managed sections)
  thezion-proxy.conf            PROXY rules (manual)
  thezion-fakeip-filter.conf    Fake-IP filter list
  *.txt                         Source rule-set payload files
  *.mrs                         Compiled binary rule-sets
```

## Memory files
Reference files in `memories/` for this project (the general memory files are defined in GEMINI.md):

| File | Holds |
|--|--|
| `memories/git-history.md` | Consolidated git history and repository evolution log |

## Update workflow (`update.sh`)
The script caches remote sources in `./tmp/` and uses conditional HTTP requests (ETag) so unchanged remotes are neither re-downloaded nor re-processed.

Stages in order:
1. **Download phase (cached)**: Fetches every remote source into `./tmp/` in parallel (`xargs -P 10`) using `fetch_cached`: upstream URLs in `upstream` (9 Loyalsoldier `.txt` rule-sets), two v2fly `domain-list-community` files (`apple`, `apple-tvplus`), and MetaCubeX `GeoLite2-ASN.mmdb`. Uses `curl --etag-compare/--etag-save` against `<dest>.etag` sidecars:
   - `304`: Remote unchanged; skip download and processing.
   - `200`: Remote changed; update cache and mark changed.
   - Missing cache: Downloads and marks changed.
2. **Change detection**: Builds a `CHANGED` set from fetch results, and hashes `exclude.conf` (`shasum`, stored in `./tmp/.meta`) to detect exclusion changes.
3. **Per-file processing decision**: Re-processes a rule-set only if upstream changed, or `exclude.conf` changed and the file has an exclusion section (`direct.txt`, `proxy.txt`), or working `.txt` / `.mrs` is missing. Excluded files are filtered with `sed` from raw source `./tmp/<file>` into working `.txt`; non-excluded changed files are copied. Unchanged files are skipped.
4. **`update_apple_cn`**: Formats `@cn`-tagged Apple entries and all Apple TV+ entries as `DOMAIN` / `DOMAIN-SUFFIX` rules from `./tmp/apple` and `./tmp/apple-tvplus`, injecting them into `thezion-direct.conf` under `# Apple@cn`. Skipped if sources are unchanged and the section has content.
5. **`update_asn_extract`**: Extracts CIDRs for `TARGET_ASNS` from `./tmp/GeoLite2-ASN.mmdb` via `.venv/bin/python3 extract_asn.py --db-path ./tmp/GeoLite2-ASN.mmdb`, injecting them into `thezion-direct.conf` under `# ASN Extract`. Skipped if mmdb is unchanged and the section has content.
6. **`convert_to_mrs`**: Converts only changed `.txt` files to `.mrs` using `mihomo convert-ruleset` in parallel. Overlaps with stages 4 and 5 in the background.

### Cache (`./tmp/`, gitignored)
- `<name>.txt`, `apple`, `apple-tvplus`, `GeoLite2-ASN.mmdb`: Raw cached sources.
- `<source>.etag`: ETag sidecar per cached source.
- `.meta`: `EXCLUDE_HASH=<shasum of exclude.conf>` from last run.
- Full refresh: `rm -rf tmp`.

### Section markers in `thezion-direct.conf`
`update_apple_cn` and `update_asn_extract` rewrite content between `# <Section>` and the next `# ` header (or EOF):
- `# Apple@cn`: Managed by `update_apple_cn`.
- `# ASN Extract`: Managed by `update_asn_extract`.

Do not edit lines under these two headers manually. Other sections (Apple, Microsoft Connection Check, DDNS, NTP Service, UU Plugin, China DNS, Time Server, Hardcode DNS Direct) are manually maintained.

## Exclusions (`exclude.conf`)
INI-style sections (`[direct.txt]`, `[proxy.txt]`) list patterns converted to sed `/<pattern>/d` commands and applied to cached sources.
- Quote patterns containing special characters (`+`, `'`, `/`, etc.) when matching lines formatted as YAML items.
- Editing `exclude.conf` updates `EXCLUDE_HASH`, triggering re-processing on the next run.

## File specifications
| File | Role |
|---|---|
| `upstream` | List of Loyalsoldier rule-set URLs to download |
| `exclude.conf` | Per-file deletion patterns applied after download |
| `extract_asn.py` | Extracts CIDRs for target ASNs from GeoLite2-ASN mmdb |
| `update.sh` | Update pipeline script |
| `tmp/` | Cache directory (gitignored) |
| `thezion-config.conf` | Main configuration file |
| `thezion-direct.conf` | DIRECT rules (contains managed sections) |
| `thezion-proxy.conf` | PROXY rules (manually maintained) |
| `thezion-fakeip-filter.conf` | Fake-IP filter list |
| `*.txt` | YAML `payload:` rule-sets (source of truth) |
| `*.mrs` | Compiled binary rule-sets (generated by `convert_to_mrs`) |

### `.txt` rule-set format
YAML format with a `payload:` list:
- Domain rule-sets: `  - '+.example.com'` (behavior `domain`)
- IP-CIDR rule-sets: `  - '1.2.3.0/24'` (behavior `ipcidr`, files named `*cidr*`)

## Prerequisites
- `mihomo` CLI on PATH.
- Python virtual environment at `./.venv` with `maxminddb`:
  `python3 -m venv .venv && .venv/bin/pip install maxminddb`
- System utilities: `curl` (>= 7.68), `wget`, `awk`, `sed`, `perl`, `xargs`, `shasum`.

## Rules
- `.mrs` files are generated; never edit by hand. Edit `.txt` and re-run `update.sh`.
- Do not manually edit `# Apple@cn` and `# ASN Extract` sections in `thezion-direct.conf`.
- `tmp/` is a cache directory and must remain gitignored.
- `ASN_DB_URL` in `update.sh` mirrors `extract_asn.py`'s `DB_URL`; keep both in sync if modified.
- Output files must remain deterministic and byte-identical to a full uncached run.
- Commit regenerated `.txt` and `.mrs` together.
- Default branch is `main`.

## Git
- Commit only when the user asks.
- Track changes with git commit messages; do not log change history in the memory files.
