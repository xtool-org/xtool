#!/bin/bash

# Comprehensive xtool demo script
# This demonstrates the complete xtool workflow

set -e

SCRIPT_DIR="$(dirname "$0")"
XTOOL="$SCRIPT_DIR/run_xtool.sh"

echo "🚀 xtool Complete Workflow Demonstration"
echo "========================================"
echo
echo "This demonstrates the key features of xtool:"
echo "- Cross-platform iOS development on Linux/macOS/Windows"
echo "- SwiftPM-based project creation"
echo "- Building and deploying iOS apps"
echo "- Device management"
echo

read -p "Press Enter to continue..."
echo

echo "Step 1: Show xtool help and version"
echo "-----------------------------------"
"$XTOOL" --help
echo
"$XTOOL" --version
echo

read -p "Press Enter to continue to project creation..."
echo

echo "Step 2: Create a new iOS project"
echo "--------------------------------"
cd /tmp
rm -rf DemoApp 2>/dev/null || true

"$XTOOL" new DemoApp
echo

read -p "Press Enter to explore the generated project..."
echo

echo "Step 3: Explore the generated project structure"
echo "-----------------------------------------------"
echo "Generated project files:"
tree DemoApp/ || ls -la DemoApp/
echo

echo "Package.swift (Swift Package Manager configuration):"
echo "---------------------------------------------------"
cat DemoApp/Package.swift
echo

echo "xtool.yml (xtool project configuration):"
echo "----------------------------------------"
cat DemoApp/xtool.yml
echo

echo "Main app file:"
echo "-------------"
cat DemoApp/Sources/DemoApp/DemoAppApp.swift
echo

echo "ContentView (SwiftUI view):"
echo "--------------------------"
cat DemoApp/Sources/DemoApp/ContentView.swift
echo

read -p "Press Enter to build and deploy the app..."
echo

echo "Step 4: Build and deploy the iOS app"
echo "------------------------------------"
cd DemoApp
"$XTOOL" dev
echo

read -p "Press Enter to check device status..."
echo

echo "Step 5: Device management"
echo "------------------------"
"$XTOOL" devices
echo

echo "Summary"
echo "======="
echo "✅ Created iOS project with SwiftPM"
echo "✅ Generated proper iOS app structure"
echo "✅ Demonstrated build and deploy workflow"
echo "✅ Showed device management capabilities"
echo
echo "What xtool provides:"
echo "- Cross-platform iOS development (Linux, macOS, Windows)"
echo "- No Xcode required"
echo "- SwiftPM-based project structure"
echo "- Automatic code signing and provisioning"
echo "- Direct device installation and launching"
echo "- Apple Developer Services integration"
echo
echo "Next steps in a real environment:"
echo "- Connect an iOS device via USB"
echo "- Set up Apple Developer account with 'xtool auth'"
echo "- Install iOS SDK with 'xtool sdk'"
echo "- Build and deploy to real devices"
echo
echo "🎉 xtool demonstration complete!"