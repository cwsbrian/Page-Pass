require "xcodeproj"

project_path = File.expand_path("../PagePassControlSpike.xcodeproj", __dir__)
project = Xcodeproj::Project.open(project_path)
app_target = project.targets.find { |target| target.name == "PagePassControlSpike" }
abort "PagePassControlSpike target not found" unless app_target

report_target = project.targets.find { |target| target.name == "PagePassControlReport" }
unless report_target
  report_target = project.new_target(
    :app_extension,
    "PagePassControlReport",
    :ios,
    "17.4"
  )
end

report_group = project.main_group.find_subpath("PagePassControlReport", true)
report_group.set_source_tree("<group>")
report_group.set_path("PagePassControlReport")

swift_reference = report_group.files.find { |file| file.path == "PagePassDeviceActivityReport.swift" }
swift_reference ||= report_group.new_file("PagePassDeviceActivityReport.swift")
unless report_target.source_build_phase.files_references.include?(swift_reference)
  report_target.add_file_references([swift_reference])
end

%w[Info.plist PagePassControlReport.entitlements].each do |path|
  report_group.new_file(path) unless report_group.files.any? { |file| file.path == path }
end

app_group = project.main_group.find_subpath("PagePassControlSpike", false)
diagnostic_reference = app_group.files.find { |file| file.path == "UsageDiagnosticView.swift" }
diagnostic_reference ||= app_group.new_file("UsageDiagnosticView.swift")
unless app_target.source_build_phase.files_references.include?(diagnostic_reference)
  app_target.add_file_references([diagnostic_reference])
end

report_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
  settings["CODE_SIGN_ENTITLEMENTS"] = "PagePassControlReport/PagePassControlReport.entitlements"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["CURRENT_PROJECT_VERSION"] = "1"
  settings["DEVELOPMENT_TEAM"] = "2VL68NBQ25"
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["INFOPLIST_FILE"] = "PagePassControlReport/Info.plist"
  settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.4"
  settings["MARKETING_VERSION"] = "1.0"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.pagepass.controlspike.DeviceActivityReport"
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["SDKROOT"] = "iphoneos"
  settings["SKIP_INSTALL"] = "YES"
  settings["SUPPORTED_PLATFORMS"] = "iphoneos iphonesimulator"
  settings["SWIFT_VERSION"] = "5.0"
  settings["TARGETED_DEVICE_FAMILY"] = "1"
end

unless app_target.dependencies.any? { |dependency| dependency.target == report_target }
  app_target.add_dependency(report_target)
end

embed_phase = app_target.copy_files_build_phases.find { |phase| phase.name == "Embed App Extensions" }
abort "Embed App Extensions phase not found" unless embed_phase
unless embed_phase.files_references.include?(report_target.product_reference)
  build_file = embed_phase.add_file_reference(report_target.product_reference, true)
  build_file.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }
end

project.save
