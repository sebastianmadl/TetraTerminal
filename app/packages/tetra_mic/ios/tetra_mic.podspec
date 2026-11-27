Pod::Spec.new do |s|
  s.name             = 'tetra_mic'
  s.version          = '1.0.0'
  s.summary          = 'Microphone capture for TETRA Terminal.'
  s.description      = 'AVAudioEngine microphone capture that rebuilds itself on audio hardware changes.'
  s.homepage         = 'https://github.com/sebastianmadl/TetraTerminal'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'TETRA Terminal' => 'none' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
