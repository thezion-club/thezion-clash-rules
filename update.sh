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

# Create a temporary directory for downloads
DOWNLOAD_DIR=$(mktemp -d)
echo "Downloading files to temporary directory: $DOWNLOAD_DIR"

# Download files in parallel
# Using xargs with wget. -P 10 for parallel downloads.
if grep -v '^\s*$' "$UPSTREAM_FILE" | xargs -n 1 -P 10 wget -q -P "$DOWNLOAD_DIR"; then
    echo "Download successful."
else
    echo "Error: Download failed. Aborting."
    rm -rf "$DOWNLOAD_DIR"
    exit 1
fi

# Move downloaded files to current directory, overwriting existing ones
echo "Updating local files..."
cp "$DOWNLOAD_DIR"/* "$BASE_DIR/"
rm -rf "$DOWNLOAD_DIR"

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

update_apple_cn

echo "Processing complete."
