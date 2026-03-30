#!/bin/bash

# Exit on error
set -e

# Use the directory where the script is located
CURRENT_DIR=$(dirname "${BASH_SOURCE[0]}")
cd "$CURRENT_DIR" || exit 1

EXCLUDED_FILE="exclude.conf"
UPSTREAM_FILE="upstream"
BASE_DIR="."

# Check prerequisites
if [[ ! -f "$UPSTREAM_FILE" ]]; then
    echo "Error: $UPSTREAM_FILE not found."
    exit 1
fi

echo "Starting update process..."

# Create a temporary directory for downloads; clean it up on exit (success or error)
DOWNLOAD_DIR=$(mktemp -d)
echo "Downloading files to temporary directory: $DOWNLOAD_DIR"
trap 'echo "Cleaning up $DOWNLOAD_DIR..."; rm -rf "$DOWNLOAD_DIR"' EXIT

# Download files in parallel
# Using xargs with wget. -P 10 for parallel downloads.
if grep -v '^\s*$' "$UPSTREAM_FILE" | xargs -n 1 -P 10 wget -q -P "$DOWNLOAD_DIR"; then
    echo "Download successful."
else
    echo "Error: Download failed. Aborting."
    exit 1
fi

# Move downloaded files to current directory, overwriting existing ones
echo "Updating local files..."
cp "$DOWNLOAD_DIR"/* "$BASE_DIR/"

# Process exclusions
if [[ -f "$EXCLUDED_FILE" ]]; then
    echo "Processing exclusions from $EXCLUDED_FILE..."

    current_target=""
    declare -a patterns

    # Read exclude.conf
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim whitespace
        line=$(echo "$line" | xargs)

        if [[ -z "$line" ]]; then continue; fi

        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            # Process previous section
            if [[ -n "$current_target" && ${#patterns[@]} -gt 0 ]]; then
                target_file="$BASE_DIR/$current_target"
                if [[ -f "$target_file" ]]; then
                     echo "  Applying ${#patterns[@]} exclusions to $current_target..."
                     # Create sed script
                     sed_script=$(mktemp)
                     for p in "${patterns[@]}"; do
                         echo "/$p/d" >> "$sed_script"
                     done

                     if [[ "$OSTYPE" == "darwin"* ]]; then
                        sed -i '' -f "$sed_script" "$target_file"
                     else
                        sed -i -f "$sed_script" "$target_file"
                     fi
                     rm "$sed_script"
                else
                    echo "  Warning: $target_file does not exist. Skipping..."
                fi
            fi

            # Start new section
            current_target="${BASH_REMATCH[1]}"
            patterns=()
        else
            patterns+=("$line")
        fi
    done < "$EXCLUDED_FILE"

    # Process the last section
    if [[ -n "$current_target" && ${#patterns[@]} -gt 0 ]]; then
        target_file="$BASE_DIR/$current_target"
        if [[ -f "$target_file" ]]; then
             echo "  Applying ${#patterns[@]} exclusions to $current_target..."
             sed_script=$(mktemp)
             for p in "${patterns[@]}"; do
                 echo "/$p/d" >> "$sed_script"
             done

             if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' -f "$sed_script" "$target_file"
             else
                sed -i -f "$sed_script" "$target_file"
             fi
             rm "$sed_script"
        else
             echo "  Warning: $target_file does not exist. Skipping..."
        fi
    fi
else
    echo "Warning: $EXCLUDED_FILE not found."
fi



update_apple_cn() {
    echo "Updating Apple@cn rules..."
    local apple_url="https://raw.githubusercontent.com/v2fly/domain-list-community/refs/heads/master/data/apple"
    local appletv_url="https://raw.githubusercontent.com/v2fly/domain-list-community/refs/heads/master/data/apple-tvplus"
    local rules_file="$BASE_DIR/apple_rules.tmp"
    local config_file="$BASE_DIR/thezion-direct.conf"

    if [[ ! -f "$config_file" ]]; then
        echo "Warning: $config_file not found. Skipping Apple@cn update."
        return
    fi

    # Fetch and process both Apple CN and Apple TV+ rules
    {
        # Process Apple CN (filter for @cn)
        wget -qO- "$apple_url" | awk '/@cn$/ && !/^#/ {
            sub(/ @cn$/, "", $0);
            if ($0 ~ /^full:/) {
                sub(/^full:/, "", $0);
                printf "  - DOMAIN,%s\n", $0;
            } else {
                printf "  - DOMAIN-SUFFIX,%s\n", $0;
            }
        }' || echo "Warning: Failed to download/process Apple rules" >&2

        # Process Apple TV+ (no @cn filter, strip tags)
        wget -qO- "$appletv_url" | awk '!/^#/ && NF {
            sub(/ @.*$/, "", $0);
            if ($0 ~ /^full:/) {
                sub(/^full:/, "", $0);
                printf "  - DOMAIN,%s\n", $0;
            } else {
                printf "  - DOMAIN-SUFFIX,%s\n", $0;
            }
        }' || echo "Warning: Failed to download/process AppleTV+ rules" >&2
    } | sort -u > "$rules_file"

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
    local db_path="$DOWNLOAD_DIR/GeoLite2-ASN.mmdb"  # lives in the shared tmp dir
    local rules_file
    rules_file=$(mktemp)

    if [[ ! -f "$config_file" ]]; then
        echo "Warning: $config_file not found. Skipping ASN Extract update."
        rm -f "$rules_file"
        return
    fi

    if [[ ! -f "$python_bin" ]]; then
        echo "Warning: .venv/bin/python3 not found. Run: python3 -m venv .venv && .venv/bin/pip install maxminddb"
        rm -f "$rules_file"
        return
    fi

    # Download DB (--refresh) into the shared tmp dir; stream progress to console
    "$python_bin" "$extract_script" --refresh --db-path "$db_path" 2>&1 1>/dev/null | while IFS= read -r line; do
        echo "  [asn] $line"
    done

    # Now extract CIDRs (DB already present, no re-download) and format as YAML list items
    "$python_bin" "$extract_script" --db-path "$db_path" 2>/dev/null \
        | awk '{printf "  - %s\n", $0}' > "$rules_file"

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


update_apple_cn
update_asn_extract

echo "Processing complete."