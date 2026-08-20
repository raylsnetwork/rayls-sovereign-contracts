#!/bin/bash

# Check if the destination directory is provided as an argument
if [ "$#" -ne 1 ]; then
  echo "Usage: npm run bindings:delete -- absolute/path/to/destination/repo/folder/contracts"
  exit 1
fi

destination=$1

# Ensure the destination directory exists
if [ ! -d "$destination" ]; then
  echo "Destination directory does not exist: $destination"
  exit 2
fi

# Delete subdirectories and their contents, but keep files in root
echo "Deleting subdirectories and their contents from $destination"
for dir in "$destination"/*/; do
  if [ -d "$dir" ]; then
    echo "Deleting directory $(basename "$dir") and its contents"
    rm -rf "$dir"
    if [ $? -ne 0 ]; then
      echo "Failed to delete directory $dir. Check permissions."
      exit 3
    fi
  fi
done

echo "All subdirectories have been deleted while preserving root files."