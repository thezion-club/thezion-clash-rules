#!/bin/bash

# Use the directory where the script is located
CURRENT_DIR="$(pwd)"  # or use "${BASH_SOURCE[0]%/*}" for the directory containing the script

EXCLUDED_FILE="$CURRENT_DIR/exclude.conf"
BASE_DIR="$CURRENT_DIR"

# Remove all .txt files in the current directory
rm "$BASE_DIR"/*.txt

# Use the URL from "upstream" to download files
cat "$BASE_DIR/upstream" | xargs -n 1 -P 10 wget -q

# Check if exclude.conf exists
if [[ ! -f "$EXCLUDED_FILE" ]]; then
    echo "Error: exclude.conf does not exist."
    exit 1
fi

current_file=""

# Read each line in exclude.conf
while IFS= read -r line
do
    # Check if the line is a file indicator
    if [[ $line =~ ^\[(.*)\]$ ]]; then
        current_file="${BASH_REMATCH[1]}"
        continue
    fi

    # If we have a current file and the line is not empty
    if [[ -n "$current_file" && -n "$line" ]]; then
        target_file="$BASE_DIR/$current_file"
        
        # Check if the target file exists
        if [[ -f "$target_file" ]]; then
            # Use sed to delete lines containing the current keyword
            sed -i '' "/$line/d" "$target_file"
            echo "Deleted lines containing '$line' from $current_file"
        else
            echo "Warning: $current_file does not exist. Skipping..."
        fi
    fi
done < "$EXCLUDED_FILE"


update_apple_cn() {
    echo "Updating Apple@cn rules..."
    local apple_url="https://raw.githubusercontent.com/v2fly/domain-list-community/refs/heads/master/data/apple"
    local rules_file="$BASE_DIR/apple_rules.tmp"
    local config_file="$BASE_DIR/thezion-direct.conf"

    # Fetch and process
    wget -qO- "$apple_url" | awk '/@cn$/ {
        sub(/ @cn$/, "", $0);
        if ($0 ~ /^full:/) {
            sub(/^full:/, "", $0);
            printf "  - DOMAIN,%s\n", $0;
        } else {
            printf "  - DOMAIN-SUFFIX,%s\n", $0;
        }
    }' | sort -u > "$rules_file"

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
