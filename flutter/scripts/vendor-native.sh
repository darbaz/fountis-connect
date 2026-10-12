#!/bin/sh
# Makes the pub package self-contained by copying the native SDK sources into fountis_connect_mobile.
# Run it before `flutter pub publish`. In this repository the podspec copies the Swift SDK itself and
# Gradle reads ../../../android/connect directly, so you do not need this script for development.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$HERE/fountis_connect_mobile"
SDK="$HERE/.."

rm -rf "$PKG/ios/FountisConnectSDK" "$PKG/android/connect-sdk"
mkdir -p "$PKG/ios/FountisConnectSDK" "$PKG/android/connect-sdk"
cp "$SDK/ios/Sources/FountisConnect/"*.swift "$PKG/ios/FountisConnectSDK/"
cp "$SDK/ios/Sources/FountisConnect/PrivacyInfo.xcprivacy" "$PKG/ios/FountisConnectSDK/"
cp -R "$SDK/ios/Sources/FountisConnect/Engine" "$PKG/ios/FountisConnectSDK/Engine"
cp -R "$SDK/android/connect/src/main" "$PKG/android/connect-sdk/main"
rm -f "$PKG/android/connect-sdk/main/AndroidManifest.xml" # the plugin has its own copy of it
echo "vendored the native SDKs into fountis_connect_mobile"
