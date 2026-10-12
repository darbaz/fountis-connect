require 'json'
require 'fileutils'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

# CocoaPods cannot read files outside the pod folder, so the Swift SDK is copied into ios/FountisConnectSDK
# when `pod install` reads this file inside the repository (re-run `pod install` after changing the SDK).
# The npm package already carries that copy (scripts/vendor-native.sh runs on `npm pack`).
repo_sdk = File.join(__dir__, '..', '..', 'ios', 'Sources', 'FountisConnect')
sdk = 'FountisConnectSDK'
if File.directory?(repo_sdk)
  FileUtils.rm_rf(File.join(__dir__, sdk))
  FileUtils.mkdir_p(File.join(__dir__, sdk))
  FileUtils.cp_r(Dir.glob(File.join(repo_sdk, '*')), File.join(__dir__, sdk))
end

Pod::Spec.new do |s|
  s.name           = 'FountisConnectReactNative'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = 'FOUNTIS'
  s.homepage       = 'https://github.com/darbaz/fountis-connect'
  s.platforms      = { :ios => '15.1' }
  s.swift_version  = '5.9'
  s.source         = { :git => 'https://github.com/darbaz/fountis-connect.git' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.source_files = ['*.swift', "#{sdk}/*.swift"]
  s.resource_bundles = { 'FountisConnect' => ["#{sdk}/Engine", "#{sdk}/PrivacyInfo.xcprivacy"] }
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
