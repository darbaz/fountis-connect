#!/bin/sh
# Makes the npm tarball self-contained by copying the native SDK sources into this package.
# Runs on `npm pack` / `npm publish` (prepack). In this repository the podspec copies the Swift SDK itself
# and Gradle reads ../../android/connect directly, so you do not need this script for development.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$HERE/.."

rm -rf "$HERE/ios/FountisConnectSDK" "$HERE/android/connect-sdk"
mkdir -p "$HERE/ios/FountisConnectSDK" "$HERE/android/connect-sdk"
cp "$SDK/ios/Sources/FountisConnect/"*.swift "$HERE/ios/FountisConnectSDK/"
cp "$SDK/ios/Sources/FountisConnect/PrivacyInfo.xcprivacy" "$HERE/ios/FountisConnectSDK/"
cp -R "$SDK/ios/Sources/FountisConnect/Engine" "$HERE/ios/FountisConnectSDK/Engine"
cp -R "$SDK/android/connect/src/main" "$HERE/android/connect-sdk/main"
rm -f "$HERE/android/connect-sdk/main/AndroidManifest.xml" # this package has its own copy of it
echo "vendored the native SDKs into ios/FountisConnectSDK and android/connect-sdk"
