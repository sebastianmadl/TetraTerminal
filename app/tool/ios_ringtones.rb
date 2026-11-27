# Puts the ring tones (ios_ringtones/*.wav) into the Runner app bundle, where
# the system call screen looks for them. Idempotent.
# Usage: ruby tool/ios_ringtones.rb <ios dir> <ring tone dir>
require 'fileutils'
require 'xcodeproj'

ios, src = ARGV
project = Xcodeproj::Project.open(File.join(ios, 'Runner.xcodeproj'))
runner = project.targets.find { |t| t.name == 'Runner' } or abort('no Runner target')
group = project.main_group['Runner'] or abort('no Runner group')

added = 0
Dir[File.join(src, '*.wav')].sort.each do |file|
  name = File.basename(file)
  FileUtils.cp(file, File.join(ios, 'Runner', name))
  next if group.files.any? { |r| r.path == name }
  runner.resources_build_phase.add_file_reference(group.new_reference(name))
  added += 1
end
project.save
puts "ring tones: #{added} added to the app bundle"
