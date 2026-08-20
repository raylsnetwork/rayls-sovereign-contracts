#!/bin/bash

# Check if the destination directory is provided as an argument
if [ "$#" -ne 1 ]; then
  echo "Usage: npm run bindings:move -- absolute/path/to/destination/repo/folder/contracts"
  exit 1
fi

destination=$1

# Ensure the destination directory exists
if [ ! -d "$destination" ]; then
  echo "Destination directory does not exist. Please create it first."
  exit 2
fi
# Navigate to the bindings directory
cd bindings || exit

# Copy each folder in the bindings directory to the specified destination
for dir in */; do
  path="$destination/$dir"
  echo "Copying $dir to $path"
  mkdir -p "$path"
  cp -rf "$dir"* "$path"
  if [ $? -ne 0 ]; then
    echo "Failed to copy $dir to $destination. Check permissions and disk space."
    exit 3
  fi
done

echo "All bindings have been copied to $destination."