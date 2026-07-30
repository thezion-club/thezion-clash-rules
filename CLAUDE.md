# thezion-clash-rules

Clash/mihomo rule-set repository for **the zion club**, built on top of
[Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules). The
published rule-sets are consumed raw from `main`:

```
https://raw.githubusercontent.com/thezion-club/thezion-clash-rules/refs/heads/main/<file>
```

The user updates the rules by running `bash update.sh` from the repo root.

## Update workflow (`update.sh`)

The script caches all remote sources in `./tmp/` and uses **conditional HTTP
requests (ETag)** so that unchanged remotes are neither re-downloaded nor
re-processed. Stages, in order:

1. **Download phase (cached)** — every remote source is fetched into `./tmp/`
   in parallel (`xargs -P 10`) via the `fetch_cached` helper: an upstream URL
   per non-empty line of `upstream` (9 Loyalsoldier `.txt` rule-sets), the two
   v2fly `domain-list-community` data files (`apple`, `apple-tvplus`), and the
   MetaCubeX `GeoLite2-ASN.mmdb`. `fetch_cached` uses `curl --etag-compare/
   --etag-save` (If-None-Match) against a per-file `<dest>.etag` sidecar:
   - `304` → remote unchanged; skip download (and later, skip processing).
   - `200` → remote changed; replace the cached copy and mark it changed.
   - Cache missing (empty `./tmp`, deleted file) → downloads and marks changed.
   - `curl` is used because these hosts serve an ETag but **no**
     `Last-Modified`, so `wget -N` timestamping does not work.
2. **Change detection** — builds a `CHANGED` set from the fetch results, and
   hashes `exclude.conf` (`shasum`, stored in `./tmp/.meta`) to detect
   exclusion-rule changes across runs.
3. **Per-file processing decision** — a rule-set is re-processed only if its
   upstream changed, **or** `exclude.conf` changed *and* the file has an
   exclusion section (`direct.txt`, `proxy.txt`), **or** its working `.txt` /
   `.mrs` is missing. Excluded files are produced by `sed`-ing the cached raw
   source (`./tmp/<file>`) into the working `.txt`; non-excluded changed files
   are `cp`'d. Unchanged files are left entirely alone.
4. **`update_apple_cn`** — reads the cached `./tmp/apple` and
   `./tmp/apple-tvplus` (falls back to a direct `wget` if a cached source is
   missing), formats `@cn`-tagged Apple entries and all Apple TV+ entries as
   `DOMAIN` / `DOMAIN-SUFFIX` rules, and injects them into `thezion-direct.conf`
   under the `# Apple@cn` marker. **Skipped entirely** if neither source
   changed and the section already has content.
5. **`update_asn_extract`** — extracts CIDRs for `TARGET_ASNS` from the cached
   `./tmp/GeoLite2-ASN.mmdb` via `.venv/bin/python3 extract_asn.py --db-path
   ./tmp/GeoLite2-ASN.mmdb` (no `--refresh` — never downloads), and injects
   them into `thezion-direct.conf` under the `# ASN Extract` marker. **Skipped
   entirely** if the mmdb is unchanged and the section already has content.
6. **`convert_to_mrs`** — converts **only the changed `.txt` subset** to
   `.mrs` via `mihomo convert-ruleset`, in parallel (`xargs -P`, jobs = cores
   capped at 8). Runs in the background, overlapping stages 4–5 (they touch
   only `thezion-direct.conf`; conversions touch only `*.txt`/`*.mrs`). Empty
   subset → skips.

`update_apple_cn` and `update_asn_extract` run sequentially (both `perl -i`
the same conf file); everything else overlaps.

### Cache (`./tmp/`, gitignored)

- `<name>.txt`, `apple`, `apple-tvplus`, `GeoLite2-ASN.mmdb` — raw cached sources.
- `<source>.etag` — ETag sidecar per cached source (drives conditional GETs).
- `.meta` — `EXCLUDE_HASH=<shasum of exclude.conf>` from the last build.
- **Force a full refresh:** `rm -rf tmp` → next run re-downloads and
  re-processes everything.

### Section markers in `thezion-direct.conf`

`update_apple_cn` and `update_asn_extract` rewrite the content **between a
`# <Section>` header and the next `# ` header** (or EOF). The relevant markers:

- `# Apple@cn` — managed by `update_apple_cn`
- `# ASN Extract` — managed by `update_asn_extract`

Do **not** hand-edit the lines under these two headers — the next run that
re-processes them will overwrite them. To change them, edit the script /
`extract_asn.py` TARGET_ASNS, or the upstream v2fly source. Other `# ` sections
(Apple, Microsoft Connection Check, DDNS, NTP Service, UU Plugin, China DNS,
Time Server, Hardcode DNS Direct) are hand-maintained.

## Exclusions (`exclude.conf`)

INI-style: `[<filename>]` sections (currently `[direct.txt]`, `[proxy.txt]`)
each list patterns. Each pattern is turned into a sed `/<pattern>/d` command
and applied to the **cached raw source** (`./tmp/<file>`) to produce the
working `.txt` — i.e. **every line matching the pattern is deleted**.

- Patterns are raw strings dropped into a sed `/.../ ` regex, so special
  characters matter. Quote patterns that contain `+`, `'`, `/`, etc. — the
  quotes are part of the line read by the script, so e.g. `"+.updf.com"` and
  `"'time"` match the quoted form as it appears in the `.txt` payload.
- Editing `exclude.conf` bumps `EXCLUDE_HASH`, which re-processes the affected
  files on the next run even if upstream is unchanged.

## Files

| File | Role |
|---|---|
| `upstream` | list of Loyalsoldier rule-set URLs to download |
| `exclude.conf` | per-file deletion patterns applied after download |
| `extract_asn.py` | extracts CIDRs for target ASNs from GeoLite2-ASN mmdb |
| `update.sh` | the update pipeline; run with `bash update.sh` |
| `tmp/` | cache of raw remote sources + ETag sidecars (gitignored, not committed) |
| `thezion-config.conf` | main config; `[Rule]` references the rule-sets below |
| `thezion-direct.conf` | DIRECT rules; contains managed `# Apple@cn` & `# ASN Extract` sections |
| `thezion-proxy.conf` | PROXY rules (hand-maintained) |
| `thezion-fakeip-filter.conf` | fake-ip filter list |
| `*.txt` | YAML `payload:` rule-sets (source of truth for conversion) |
| `*.mrs` | compiled binary rule-sets, produced by `convert_to_mrs` (do not hand-edit) |

### `.txt` rule-set format

All `.txt` rule-sets are YAML with a `payload:` list:

- domain rule-sets: `  - '+.example.com'` (suffix form) — behavior `domain`
- ipcidr rule-sets: `  - '1.2.3.0/24'` — behavior `ipcidr` (files named `*cidr*`)

## Prerequisites

- `mihomo` CLI on PATH (Homebrew).
- Python venv at `./.venv` with `maxminddb`: `python3 -m venv .venv && .venv/bin/pip install maxminddb`
- `curl` (≥ 7.68, for `--etag-compare`/`--etag-save`), `wget` (Apple fallback),
  `awk`, `sed`, `perl`, `xargs`, `shasum`.

## Conventions / gotchas

- `.mrs` files are generated — never edit by hand; edit the `.txt` and re-run `update.sh`.
- The `# Apple@cn` and `# ASN Extract` blocks in `thezion-direct.conf` are regenerated when their sources change — hand edits there are lost.
- `tmp/` is gitignored cache; it is **not** committed. `rm -rf tmp` forces a full refresh.
- `ASN_DB_URL` is defined in `update.sh` and mirrors `extract_asn.py`'s `DB_URL` — update both if it changes.
- Outputs are byte-identical to a full uncached run: the cache only skips
  unchanged work, it never changes what is produced.
- Commit regenerated `.txt` and `.mrs` together so the published raw files stay consistent.
- Branch for PRs is `main`.
