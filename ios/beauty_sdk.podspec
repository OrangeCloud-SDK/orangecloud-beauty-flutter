#
# beauty_sdk —— iOS 插件 podspec
#
# 注意：本插件的原生美颜引擎（orangecloud-beauty-ios）仅以 SwiftPM 形式分发，
# 没有发布为 CocoaPods Pod。因此 **本插件要求宿主工程启用 Flutter Swift Package Manager
# （Flutter ≥ 3.44，默认已开启）**。保留此 podspec 仅用于 Flutter 工具链识别 iOS 平台，
# 纯 CocoaPods 工程无法解析 BeautySDK 原生符号。
#
Pod::Spec.new do |s|
  s.name             = 'beauty_sdk'
  s.version          = '1.0.0'
  s.summary          = 'Flutter plugin for real-time beauty effects.'
  s.description      = 'A Flutter plugin providing face detection, beauty filters, face deformation, and AR stickers.'
  s.homepage         = 'https://github.com/OrangeCloud-SDK/orangecloud-beauty-flutter'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'OrangeCloud' => 'dev@orangecloud.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'beauty_sdk/Sources/beauty_sdk/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '14.0'
  s.swift_version    = '5.0'
end
