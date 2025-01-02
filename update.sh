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

echo "Processing complete."
