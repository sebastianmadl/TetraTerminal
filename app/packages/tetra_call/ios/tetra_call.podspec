Pod::Spec.new do |s|
  s.name             = 'tetra_call'
  s.version          = '1.0.0'
  s.summary          = 'Incoming calls for TETRA Terminal.'
  s.description      = 'Shows incoming private calls on the system call screen (CallKit).'
  s.homepage         = 'https://github.com/sebastianmadl/tetra-client-ios'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'TETRA Terminal' => 'none' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks       = 'CallKit', 'AVFoundation'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
