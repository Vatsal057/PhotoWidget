#!/usr/bin/env ruby
# Regenerates PhotoWidget.xcodeproj from the source dirs.
# Run from repo root: ruby scripts/gen_project.rb
require 'xcodeproj'
require 'fileutils'

ROOT = Dir.pwd
proj_path = File.join(ROOT, 'PhotoWidget.xcodeproj')
FileUtils.rm_rf(proj_path)
project = Xcodeproj::Project.new(proj_path)

DEPLOY = '14.0'
# Bundle IDs must be unique to YOUR team. Override with env when reusing.
PREFIX = ENV['PW_BUNDLE_PREFIX'] || 'com.kvaghasiya.photowidget'

# Fresh build version every regen: chronod caches widget descriptors keyed by
# bundle version — identical versions mean stale (even wrong-type) descriptors.
BUILD_VERSION = Time.now.strftime('%Y%m%d.%H%M%S')

def common(bc, extra = {})
  s = bc.build_settings
  s['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  s['SWIFT_VERSION'] = '5.0'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['MARKETING_VERSION'] = '1.0'
  s['CURRENT_PROJECT_VERSION'] = BUILD_VERSION
  # No CODE_SIGN_IDENTITY override: App Group entitlements need a real
  # Apple Development cert, so let automatic signing pick it. Pass
  # DEVELOPMENT_TEAM + -allowProvisioningUpdates on the xcodebuild line.
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['ENABLE_HARDENED_RUNTIME'] = 'YES'
  extra.each { |k, v| s[k] = v }
end

# --- Widget extension target (build/embed first) ---
ext = project.new_target(:app_extension, 'PhotoWidgetExtension', :osx, DEPLOY)
ext.build_configurations.each do |bc|
  common(bc,
    'PRODUCT_BUNDLE_IDENTIFIER' => "#{PREFIX}.widget",
    'INFOPLIST_FILE' => 'PhotoWidgetExtension/Info.plist',
    'CODE_SIGN_ENTITLEMENTS' => 'PhotoWidgetExtension/PhotoWidgetExtension.entitlements',
    'INFOPLIST_KEY_CFBundleDisplayName' => 'PhotoWidget')
end
ext_group = project.new_group('PhotoWidgetExtension', 'PhotoWidgetExtension')
ext.add_file_references([ext_group.new_reference('PhotoWidget.swift')])

# --- Main app target ---
app = project.new_target(:application, 'PhotoWidget', :osx, DEPLOY)
app.build_configurations.each do |bc|
  common(bc,
    'PRODUCT_BUNDLE_IDENTIFIER' => PREFIX,
    'CODE_SIGN_ENTITLEMENTS' => 'PhotoWidget/PhotoWidget.entitlements',
    'INFOPLIST_KEY_NSHumanReadableCopyright' => '',
    'INFOPLIST_KEY_LSApplicationCategoryType' => 'public.app-category.utilities')
end
app_group = project.new_group('PhotoWidget', 'PhotoWidget')
app.add_file_references([app_group.new_reference('PhotoWidgetApp.swift')])

# --- Embed the appex into the app's PlugIns ---
app.add_dependency(ext)
embed = app.new_copy_files_build_phase('Embed App Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
embed.add_file_reference(ext.product_reference).tap do |bf|
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

project.save
puts "Generated #{proj_path}"
