Pod::Spec.new do |s|
  s.name             = 'thermal_printer_kit'
  s.version          = '0.1.0'
  s.summary          = 'Bluetooth LE receipt printers for the thermal_printer_kit Flutter plugin.'
  s.description      = <<-DESC
Finds Bluetooth LE thermal printers and sends them ready-made printer commands.
                       DESC
  s.homepage         = 'https://github.com/sumonwd/thermal_printer_kit'
  s.license          = { :file => '../LICENSE' }
  s.authors          = 'Sumon Mia'
  s.source           = { :path => '.' }
  s.source_files = 'thermal_printer_kit/Sources/thermal_printer_kit/**/*.swift'
  s.dependency 'Flutter'
  s.frameworks = 'CoreBluetooth'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
