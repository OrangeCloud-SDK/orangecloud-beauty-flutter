Pod::Spec.new do |s|
  s.name             = 'beauty_sdk'
  s.version          = '1.0.0'
  s.summary          = 'Flutter plugin for real-time beauty effects.'
  s.description      = 'A Flutter plugin providing face detection, beauty filters, face deformation, and AR stickers.'
  s.homepage         = 'https://orangecloud.com'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'OrangeCloud' => 'dev@orangecloud.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
end
