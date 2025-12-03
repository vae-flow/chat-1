#!/bin/bash

echo "Configuring Android project for AI财..."

GRADLE_FILE="android/app/build.gradle"
MANIFEST_FILE="android/app/src/main/AndroidManifest.xml"

# 1. Update minSdkVersion to 23 and change applicationId
if [ -f "$GRADLE_FILE" ]; then
    echo "Updating minSdkVersion in $GRADLE_FILE..."
    # Replace variable usage with explicit version 23
    sed -i 's/minSdkVersion flutter.minSdkVersion/minSdkVersion 23/g' "$GRADLE_FILE"
    # Also try to replace explicit numbers if they exist and are lower
    sed -i 's/minSdkVersion [0-9]\{1,2\}/minSdkVersion 23/g' "$GRADLE_FILE"
    
    # Update applicationId to new package name
    echo "Updating applicationId..."
    sed -i 's/applicationId "com.example.aicai_assistant"/applicationId "com.aicai.app.aicai_assistant"/g' "$GRADLE_FILE"
else
    echo "Error: $GRADLE_FILE not found!"
    exit 1
fi

# 2. Add Permissions to AndroidManifest.xml
if [ -f "$MANIFEST_FILE" ]; then
    echo "Adding permissions to $MANIFEST_FILE..."
    
    PERMISSIONS='    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>'
    
    # Check if permissions already exist to avoid duplication (simple check)
    if ! grep -q "android.permission.INTERNET" "$MANIFEST_FILE"; then
        # Insert permissions before the <application> tag
        awk -v perms="$PERMISSIONS" '/<application/ {print perms; print $0; next} 1' "$MANIFEST_FILE" > "$MANIFEST_FILE.tmp" && mv "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"
        echo "Permissions added."
    else
        echo "Permissions appear to be present already."
    fi
    
    # Update android:label to new app name
    echo "Updating app label..."
    sed -i 's/android:label="[^"]*"/android:label="AI财"/g' "$MANIFEST_FILE"
    
else
    echo "Error: $MANIFEST_FILE not found!"
    exit 1
fi

echo "Configuration complete."
