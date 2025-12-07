#!/bin/bash

KINDLE_PATH="/media/jon/Kindle/koreader/plugins"

echo "Copying opdsbrowser.koplugin to Kindle..."
echo "Source: $(pwd)/opdsbrowser.koplugin"
echo "Target: $KINDLE_PATH/opdsbrowser.koplugin"

# Check if Kindle is mounted
if [ ! -d "$KINDLE_PATH" ]; then
    echo "ERROR: Kindle plugins directory not found at $KINDLE_PATH"
    echo "Please ensure your Kindle is mounted at /media/jon/Kindle/"
    exit 1
fi

# Copy the plugin
cp -rv opdsbrowser.koplugin "$KINDLE_PATH/"

echo ""
echo "Copy complete! The updated files are:"
ls -lh "$KINDLE_PATH/opdsbrowser.koplugin/main.lua"
ls -lh "$KINDLE_PATH/opdsbrowser.koplugin/placeholder_generator.lua"

echo ""
echo "Now restart KOReader on your Kindle to load the updated plugin."
