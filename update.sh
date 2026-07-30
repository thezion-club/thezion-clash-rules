#!/bin/bash

# Exit on error
set -e

# Use the directory where the script is located
CURRENT_DIR=$(dirname "${BASH_SOURCE[0]}")
cd "$CURRENT_DIR" || exit 1

EXCLUDED_FILE="exclude.conf"
UPSTREAM_FILE="upstream"
BASE_DIR="."
CACHE_DIR="tmp"

# Mirror of extract_asn.py DB_URL; update both if this changes.
ASN_DB_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"
ASN_DB="$CACHE_DIR/GeoLite2-ASN.mmdb"
APPLE_URL="https://raw.githubusercontent.com/v2fly/domain-list-community/refs/heads/master/data/apple"
APPLETV_URL="https://raw.githubusercontent.com/v2fly/domain-list-community/refs/heads/master/data/apple-tvplus"

# Parallel jobs for .mrs conversion (capped at 8)
JOBS=$( { sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null; } 2>/dev/null)
JOBS=${JOBS:-4}
(( JOBS > 8 )) && JOBS=8

# Check prerequisites
if [[ ! -f "$UPSTREAM_FILE" ]]; then
    echo "Error: $UPSTREAM_FILE not found."
    exit 1
fi

mkdir -p "$CACHE_DIR"

echo "Starting update process..."

# fetch_cached <url> <dest>
# Conditional GET via ETag (raw.githubusercontent.com / GitHub serve ETags but
# no Last-Modified, so wget -N can't be used). Writes dest + dest.etag.
# Returns: 0 = downloaded/changed; 1 = unchanged (304); 2 = error.
fetch_cached() {
    local url="$1" dest="$2" etag="${2}.etag" code
    if [[ -f "$dest" && -f "$etag" ]]; then
        code=$(curl -sL --etag-compare "$etag" --etag-save "${etag}.new" \
               -o "${dest}.new" -w '%{http_code}' "$url" 2>/dev/null) || code="000"
        case "$code" in
            304) rm -f "${dest}.new" "${etag}.new"; return 1 ;;
            200) mv -f "${dest}.new" "$dest"; mv -f "${etag}.new" "$etag" 2>/dev/null || true; return 0 ;;
            *)   rm -f "${dest}.new" "${etag}.new"; return 2 ;;
        esac
    else
        if curl -fsL --etag-save "$etag" -o "$dest" "$url" 2>/dev/null; then
            return 0
        else
            rm -f "$dest" "$etag"
            return 2
        fi
    fi
}

# section_has_content <header> <file>: exit 0 if the named '# section' has at
# least one non-empty line before the next '# ' header; exit 1 if empty/missing.
section_has_content() {
    awk -v h="$1" '
        $0 == h { found = 1; next }
        found && /^# / { exit 1 }
        found && NF { exit 0 }
        END { if (!found) exit 1 }
    ' "$2"
}

# --- Download phase: conditional fetch of every remote source into $CACHE_DIR ---
echo "Checking remote sources (conditional GET)..."

_fetch_one() {
    local url="$1" dest="$2" key="$3" code=0
    fetch_cached "$url" "$dest" || code=$?
    printf '%s %s\n' "$code" "$key"
}
export -f _fetch_one fetch_cached

# Build url|dest|key triples: upstream rule-sets + apple data + ASN DB.
items=()
while IFS= read -r url || [[ -n "$url" ]]; do
    [[ -z "${url//[[:space:]]/}" ]] && continue
    name=$(basename "$url")
    items+=("$url|$CACHE_DIR/$name|$name")
done < "$UPSTREAM_FILE"
items+=("$APPLE_URL|$CACHE_DIR/apple|apple")
items+=("$APPLETV_URL|$CACHE_DIR/apple-tvplus|apple-tvplus")
items+=("$ASN_DB_URL|$ASN_DB|GeoLite2-ASN.mmdb")

fetch_results=$(printf '%s\n' "${items[@]}" | xargs -P 10 -I {} bash -c '
    IFS="|" read -r url dest key <<< "$1"
    _fetch_one "$url" "$dest" "$key"
' _ {})

# Track what changed this run.
declare -A CHANGED=()
APPLE_CHANGED=0; APPLETV_CHANGED=0; ASN_CHANGED=0
while read -r code key; do
    [[ -z "$key" ]] && continue
    case "$key" in
        apple)
            [[ "$code" == 0 ]] && APPLE_CHANGED=1
            [[ "$code" == 2 ]] && echo "  Warning: apple source fetch failed."
            ;;
        apple-tvplus)
            [[ "$code" == 0 ]] && APPLETV_CHANGED=1
            [[ "$code" == 2 ]] && echo "  Warning: apple-tvplus source fetch failed."
            ;;
        GeoLite2-ASN.mmdb)
            [[ "$code" == 0 ]] && ASN_CHANGED=1
            [[ "$code" == 2 ]] && echo "  Warning: ASN database fetch failed."
            ;;
        *)
            if [[ "$code" == 0 ]]; then
                CHANGED[$key]=1
            elif [[ "$code" == 2 && ! -f "$CACHE_DIR/$key" ]]; then
                echo "  Warning: $key fetch failed (no cache; will reuse existing)."
            fi
            ;;
    esac
done <<< "$fetch_results"

# --- exclude.conf change detection ---
EXCLUDE_HASH=$(shasum -a 256 "$EXCLUDED_FILE" 2>/dev/null | cut -d' ' -f1)
META="$CACHE_DIR/.meta"
OLD_HASH=""
[[ -f "$META" ]] && OLD_HASH=$(sed -n 's/^EXCLUDE_HASH=//p' "$META")
EXCLUDE_CHANGED=0
[[ "$EXCLUDE_HASH" != "$OLD_HASH" ]] && EXCLUDE_CHANGED=1
if [[ "$EXCLUDE_CHANGED" == 1 ]]; then
    echo "exclude.conf changed since last build; re-applying exclusions."
fi

# --- Determine which rule-sets need (re)processing ---
# A rule-set needs processing if its upstream changed, exclude.conf changed
# (and it has an exclusion section), or its working .txt/.mrs is missing.
NEEDS=()
needs_file() {
    local n="$1" x
    for x in "${NEEDS[@]}"; do [[ "$x" == "$n" ]] && return 0; done
    return 1
}

while IFS= read -r url || [[ -n "$url" ]]; do
    [[ -z "${url//[[:space:]]/}" ]] && continue
    f=$(basename "$url")
    up=${CHANGED[$f]:-0}
    excl=0
    grep -q "^\[$f\]" "$EXCLUDED_FILE" 2>/dev/null && excl=1
    need=0
    [[ "$up" == 1 ]] && need=1
    [[ "$EXCLUDE_CHANGED" == 1 && "$excl" == 1 ]] && need=1
    if [[ ! -f "$BASE_DIR/$f" || ! -f "${f%.txt}.mrs" ]]; then need=1; fi
    [[ "$need" == 1 ]] && NEEDS+=("$f")
done < "$UPSTREAM_FILE"

# --- Produce working .txt for each needed file (exclusions or raw copy) ---
if [[ ${#NEEDS[@]} -gt 0 ]]; then
    echo "Processing ${#NEEDS[@]} rule-set(s): ${NEEDS[*]}"

    # Parse exclude.conf and apply patterns to needed excluded files, reading
    # the raw source from the cache and writing the working .txt.
    apply_section() {
        [[ -z "$current_target" || ${#patterns[@]} -eq 0 ]] && return 0
        needs_file "$current_target" || return 0
        local src="$CACHE_DIR/$current_target" dst="$BASE_DIR/$current_target"
        [[ -f "$src" ]] || { echo "  Warning: $src missing; skipping $current_target"; return 0; }
        echo "  Excluding ${#patterns[@]} pattern(s) in $current_target..."
        local ss; ss=$(mktemp)
        printf '/%s/d\n' "${patterns[@]}" >> "$ss"
        sed -f "$ss" "$src" > "$dst"
        rm -f "$ss"
    }

    current_target=""; patterns=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(echo "$line" | xargs)
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            apply_section
            current_target="${BASH_REMATCH[1]}"; patterns=()
        else
            patterns+=("$line")
        fi
    done < "$EXCLUDED_FILE"
    apply_section

    # Non-excluded needed files: raw copy from cache.
    for f in "${NEEDS[@]}"; do
        if ! grep -q "^\[$f\]" "$EXCLUDED_FILE" 2>/dev/null; then
            cp -f "$CACHE_DIR/$f" "$BASE_DIR/$f"
        fi
    done
else
    echo "No rule-set changes; skipping exclusions."
fi


update_apple_cn() {
    echo "Updating Apple@cn rules..."
    local config_file="$BASE_DIR/thezion-direct.conf"
    local rules_file="$BASE_DIR/apple_rules.tmp"
    local apple_src="$CACHE_DIR/apple" appletv_src="$CACHE_DIR/apple-tvplus"

    if [[ ! -f "$config_file" ]]; then
        echo "Warning: $config_file not found. Skipping Apple@cn update."
        return
    fi

    # Fall back to a direct fetch if a cached source is missing.
    if [[ ! -f "$apple_src" ]]; then
        echo "  Apple cache missing; fetching $APPLE_URL..."
        if wget -qO- "$APPLE_URL" > "$apple_src" 2>/dev/null; then
            APPLE_CHANGED=1
        else
            echo "Warning: Failed to fetch Apple rules"
            rm -f "$apple_src"
            return
        fi
    fi
    if [[ ! -f "$appletv_src" ]]; then
        echo "  AppleTV+ cache missing; fetching $APPLETV_URL..."
        if wget -qO- "$APPLETV_URL" > "$appletv_src" 2>/dev/null; then
            APPLETV_CHANGED=1
        else
            echo "Warning: Failed to fetch AppleTV+ rules"
            rm -f "$appletv_src"
            return
        fi
    fi

    # Skip if nothing changed and the section already has content.
    if [[ "$APPLE_CHANGED" != 1 && "$APPLETV_CHANGED" != 1 ]]; then
        if section_has_content "# Apple@cn" "$config_file"; then
            echo "Apple@cn unchanged; skipping."
            return
        fi
        echo "Apple@cn section empty; regenerating."
    fi

    local apple_out appletv_out
    apple_out=$(mktemp); appletv_out=$(mktemp)

    # Process Apple CN (filter for @cn) and Apple TV+ in parallel.
    awk '/@cn$/ && !/^#/ {
        sub(/ @cn$/, "", $0);
        if ($0 ~ /^full:/) {
            sub(/^full:/, "", $0);
            printf "  - DOMAIN,%s\n", $0;
        } else {
            printf "  - DOMAIN-SUFFIX,%s\n", $0;
        }
    }' "$apple_src" > "$apple_out" 2>/dev/null || echo "Warning: Failed to process Apple rules" >&2 &
    pid_apple=$!

    awk '!/^#/ && NF {
        sub(/ @.*$/, "", $0);
        if ($0 ~ /^full:/) {
            sub(/^full:/, "", $0);
            printf "  - DOMAIN,%s\n", $0;
        } else {
            printf "  - DOMAIN-SUFFIX,%s\n", $0;
        }
    }' "$appletv_src" > "$appletv_out" 2>/dev/null || echo "Warning: Failed to process AppleTV+ rules" >&2 &
    pid_appletv=$!

    wait "$pid_apple" "$pid_appletv"
    cat "$apple_out" "$appletv_out" | sort -u > "$rules_file"
    rm -f "$apple_out" "$appletv_out"

    if [[ ! -s "$rules_file" ]]; then
        echo "Warning: No rules generated for Apple@cn."
        rm -f "$rules_file"
        return
    fi

    # Update config file using perl for robust multiline handling
    perl -i -e '
        open(F, "'"$rules_file"'") or die $!;
        @rules = <F>;
        close(F);
        while (<>) {
            if (/^# Apple\@cn$/) {
                print;
                print @rules;
                $skip = 1;
                next;
            }
            if ($skip && /^# /) {
                $skip = 0;
            }
            print unless $skip;
        }
    ' "$config_file"

    rm -f "$rules_file"
    echo "Apple@cn rules updated."
}


update_asn_extract() {
    echo "Updating ASN Extract rules..."
    local config_file="$BASE_DIR/thezion-direct.conf"
    local python_bin="$CURRENT_DIR/.venv/bin/python3"
    local extract_script="$CURRENT_DIR/extract_asn.py"
    local rules_file
    rules_file=$(mktemp)

    if [[ ! -f "$config_file" ]]; then
        echo "Warning: $config_file not found. Skipping ASN Extract update."
        rm -f "$rules_file"
        return
    fi

    if [[ ! -f "$ASN_DB" ]]; then
        echo "Warning: ASN database not available. Skipping ASN Extract update."
        rm -f "$rules_file"
        return
    fi

    if [[ ! -f "$python_bin" ]]; then
        echo "Warning: .venv/bin/python3 not found. Run: python3 -m venv .venv && .venv/bin/pip install maxminddb"
        rm -f "$rules_file"
        return
    fi

    # Skip if the DB is unchanged and the section already has content.
    if [[ "$ASN_CHANGED" != 1 ]]; then
        if section_has_content "# ASN Extract" "$config_file"; then
            echo "ASN DB unchanged; skipping."
            rm -f "$rules_file"
            return
        fi
        echo "ASN Extract section empty; regenerating."
    fi

    # DB is already cached by the download phase; extract without --refresh.
    "$python_bin" "$extract_script" --db-path "$ASN_DB" 2> >(
        while IFS= read -r line; do echo "  [asn] $line"; done >&2
    ) | awk 'NF {printf "  - %s\n", $0}' > "$rules_file"

    if [[ ! -s "$rules_file" ]]; then
        echo "Warning: No ASN CIDRs generated. Skipping."
        rm -f "$rules_file"
        return
    fi

    local count
    count=$(wc -l < "$rules_file" | xargs)
    echo "  Inserting $count CIDR entries under '# ASN Extract'..."

    # Replace everything between '# ASN Extract' and the next '# ' section (or EOF)
    perl -i -e '
        open(F, "'"$rules_file"'") or die "Cannot open rules: $!";
        @rules = <F>;
        close(F);
        chomp $rules[-1];
        $skip = 0;
        while (<>) {
            if (/^# ASN Extract$/) {
                print;
                print @rules;
                $skip = 1;
                next;
            }
            if ($skip && /^# /) {
                $skip = 0;
            }
            print unless $skip;
        }
    ' "$config_file"

    rm -f "$rules_file"
    echo "ASN Extract rules updated."
}

convert_to_mrs() {
    if [[ $# -eq 0 ]]; then
        echo "No .txt changes; skipping .mrs conversion."
        return
    fi
    echo "Converting $# rule-set(s) to .mrs format..."

    _convert_one() {
        local txt_file="$1" filename behavior mrs_file
        [[ -f "$txt_file" ]] || return 0

        filename=$(basename "$txt_file")
        mrs_file="${txt_file%.txt}.mrs"

        # Files with "cidr" in the name use the ipcidr behavior; all others use domain
        if [[ "$filename" == *cidr* ]]; then
            behavior="ipcidr"
        else
            behavior="domain"
        fi

        if mihomo convert-ruleset "$behavior" yaml "$txt_file" "$mrs_file"; then
            echo "  ✓ $(basename "$mrs_file") done."
        else
            echo "  ✗ Failed to convert $filename. Skipping."
        fi
    }
    export -f _convert_one

    # Run the independent conversions in parallel across cores
    printf '%s\n' "$@" | xargs -P "$JOBS" -I {} bash -c '_convert_one "$@"' _ {}

    echo "All .mrs conversions complete."
}

# convert_to_mrs only touches *.txt/*.mrs; the conf updaters only touch
# thezion-direct.conf — so run conversions in the background while the
# .conf sections are updated. update_apple_cn and update_asn_extract stay
# sequential relative to each other (both perl -i the same conf file).
NEEDS_PATHS=()
for f in "${NEEDS[@]}"; do NEEDS_PATHS+=("$BASE_DIR/$f"); done

convert_to_mrs "${NEEDS_PATHS[@]}" &
convert_pid=$!

update_apple_cn
update_asn_extract

if ! wait "$convert_pid"; then
    echo "Error: .mrs conversion failed." >&2
    exit 1
fi

# Persist exclude.conf hash for next run's change detection.
echo "EXCLUDE_HASH=$EXCLUDE_HASH" > "$META"

echo "Processing complete."
