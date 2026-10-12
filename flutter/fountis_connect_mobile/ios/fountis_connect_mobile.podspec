require 'fileutils'

# CocoaPods cannot read files outside the pod folder, so the Swift SDK is copied into ios/FountisConnectSDK
# when `pod install` reads this file inside the repository (it runs on every `flutter build ios`).
# The pub package already carries that copy (flutter/scripts/vendor-native.sh).
repo_sdk = File.join(__dir__, '..', '..', '..', 'ios', 'Sources', 'FountisConnect')
sdk = 'FountisConnectSDK'
if File.directory?(repo_sdk)
  FileUtils.rm_rf(File.join(__dir__, sdk))
  FileUtils.mkdir_p(File.join(__dir__, sdk))
  FileUtils.cp_r(Dir.glob(File.join(repo_sdk, '*')), File.join(__dir__, sdk))
end

Pod::Spec.new do |s|
  s.name             = 'fountis_connect_mobile'
  s.version          = '1.0.0'
  s.summary          = 'FOUNTIS Connect for Flutter (iOS).'
  s.description      = 'Wraps the native FOUNTIS Connect Swift SDK.'
  s.homepage         = 'https://github.com/darbaz/fountis-connect'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'FOUNTIS' => 'dev@fountis.org' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.static_framework = true

  s.dependency 'Flutter'

  s.source_files = ['Classes/*.swift', "#{sdk}/*.swift"]
  s.resource_bundles = { 'FountisConnect' => ["#{sdk}/Engine", "#{sdk}/PrivacyInfo.xcprivacy"] }
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
