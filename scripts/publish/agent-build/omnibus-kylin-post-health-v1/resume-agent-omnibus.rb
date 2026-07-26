#!/usr/bin/env ruby
# Continue the exact Omnibus project pipeline after the pinned v9 build has
# completed all software and stopped only because old Omnibus does not list
# Kylin as an ldd-capable Linux platform.

require "fileutils"
require "ffi_yajl"
require "digest"
require "omnibus"

EXPECTED_BUILD_DIR = "/home/dbdog/work/dbdog-agent-4c39489b-build1".freeze
EXPECTED_INSTALL_DIR = "/opt/dbdog-agent".freeze
EXPECTED_CONFIG_DIR = "#{EXPECTED_BUILD_DIR}/stage-config".freeze
EXPECTED_OMNIBUS_BASE_DIR = "#{EXPECTED_BUILD_DIR}/omnibus".freeze
EXPECTED_SOURCE_OMNIBUS_DIR = "#{EXPECTED_BUILD_DIR}/src/omnibus".freeze
EXPECTED_CACHE_DIR = "/home/dbdog/cache/dbdog-agent/omnibus/sources".freeze
EXPECTED_NATIVE_PLATFORM = "kylin".freeze
EXPECTED_HOST_DISTRIBUTION = "rhel".freeze
EXPECTED_HEALTH_CHECK_SHA256 = "25119e8341ef27469b5e74a365efb12fe140bfd60512a3519b19d822d783b073".freeze
EXPECTED_DYNAMIC_STRIP_EXCLUDES = [
  "#{EXPECTED_INSTALL_DIR}/embedded/share/system-probe/ebpf/*.o",
  "#{EXPECTED_INSTALL_DIR}/embedded/share/system-probe/ebpf/co-re/*.o",
].freeze

def fail_control(message)
  warn("[resume-agent-omnibus] ERROR: #{message}")
  exit(1)
end

unless ARGV == ["resume-after-v9-healthcheck"]
  fail_control("usage: resume-agent-omnibus.rb resume-after-v9-healthcheck")
end

fail_control("must run as dbdog") unless Process.uid == 1001 && Process.euid == 1001
fail_control("wrong working directory") unless Dir.pwd == EXPECTED_SOURCE_OMNIBUS_DIR
fail_control("INSTALL_DIR mismatch") unless ENV["INSTALL_DIR"] == EXPECTED_INSTALL_DIR
fail_control("OUTPUT_CONFIG_DIR mismatch") unless ENV["OUTPUT_CONFIG_DIR"] == EXPECTED_CONFIG_DIR
fail_control("SKIP_PKG_COMPRESSION must be true") unless ENV["SKIP_PKG_COMPRESSION"] == "true"

Omnibus.load_configuration(File.join(EXPECTED_SOURCE_OMNIBUS_DIR, "omnibus.rb"))
Omnibus::Config.base_dir(EXPECTED_OMNIBUS_BASE_DIR)
Omnibus::Config.cache_dir(EXPECTED_CACHE_DIR)
Omnibus::Config.host_distribution(EXPECTED_HOST_DISTRIBUTION)

project = Omnibus::Project.load("agent")
fail_control("unexpected project name") unless project.name == "agent"
fail_control("unexpected project install directory") unless project.install_dir == EXPECTED_INSTALL_DIR
fail_control("project is not configured to strip its Linux build") unless project.strip_build
fail_control("unexpected extended packages") unless project.extended_packages.empty?
fail_control("partial strip output already exists") if File.exist?(File.join(EXPECTED_INSTALL_DIR, ".debug"))

native_platform = Omnibus::Ohai["platform"]
fail_control("expected native platform kylin, found #{native_platform.inspect}") unless native_platform == EXPECTED_NATIVE_PLATFORM

# Omnibus 5b00eea recognizes only a short fixed list of Linux distribution
# names in HealthCheck#run!. The pinned one-line patch adds Kylin to that list,
# selecting the existing health_check_ldd implementation and default Linux
# allowlist without pretending the host is a different distribution.
health_check_path = File.join(Omnibus.source_root, "lib", "omnibus", "health_check.rb")
health_check_sha256 = Digest::SHA256.file(health_check_path).hexdigest
unless health_check_sha256 == EXPECTED_HEALTH_CHECK_SHA256
  fail_control("Omnibus Kylin health-check patch digest mismatch: #{health_check_sha256}")
end
Omnibus::HealthCheck.run!(project)
puts("KYLIN_LDD_HEALTHCHECK_OK")

# This is the exact next operation in Omnibus::Project#build after the health
# check. It strips runtime ELFs and writes detached symbols below .debug; the
# separately pinned runtime finalizer removes .debug after validating the
# stripped runtime.
#
# The two eBPF exclusions are declared inside datadog-agent-finalize's dynamic
# build block. They existed in retry6's original Ruby process, but a fresh
# post-health process only reloads the recipe and does not re-execute completed
# build blocks. Rehydrate those exact upstream exclusions before stripping.
unless project.strip_exclude_paths.empty?
  fail_control("unexpected pre-existing project strip exclusions")
end
EXPECTED_DYNAMIC_STRIP_EXCLUDES.each do |pattern|
  fail_control("dynamic strip exclusion matches no file: #{pattern}") if Dir.glob(pattern).empty?
  project.strip_exclude(pattern)
end
unless project.strip_exclude_paths == EXPECTED_DYNAMIC_STRIP_EXCLUDES
  fail_control("effective dynamic strip exclusions differ from the pinned pair")
end
Omnibus::Stripper.run!(project)
puts("KYLIN_STRIP_OK")

# The pinned build is staging-only. Both RHEL packagers are configured with
# skip_packager=true and SKIP_PKG_COMPRESSION selects the null compressor.
# Prove those conditions before executing the same final no-op packaging calls
# that Project#build would have executed after stripping.
probe_packagers = Omnibus::Packager.for_current_system.map { |klass| klass.new(project) }
probe_packagers.each do |packager|
  project.packagers[packager.id].each { |block| packager.evaluate(&block) }
  fail_control("packager #{packager.id} is unexpectedly enabled") unless packager.skip_packager
end
fail_control("unexpected compressor") unless project.compressor.is_a?(Omnibus::Compressor::Null)

project.package_me
project.compress_me

# Omnibus::CLI writes this only after Project#build returns. Reproduce that
# final deterministic side effect now that the interrupted post-build sequence
# has completed.
pkg_dir = File.join(EXPECTED_SOURCE_OMNIBUS_DIR, "pkg")
FileUtils.mkdir_p(pkg_dir)
manifest_path = File.join(pkg_dir, "version-manifest.json")
manifest_tmp = "#{manifest_path}.post-health.#{$$}"
File.open(manifest_tmp, "wb", 0o644) do |file|
  file.write(FFI_Yajl::Encoder.encode(project.built_manifest.to_hash))
end
File.rename(manifest_tmp, manifest_path)

# A fresh Ruby process cannot reconstruct the original process's per-software
# timing counters. Preserve the retry6 log as their authority and write an
# explicit resume record instead of emitting a misleading zero-duration
# build-summary.json.
resume_record = {
  "format" => "dbdog-agent-post-health-resume-v1",
  "resume_from" => "omnibus-v9-retry6-post-healthcheck",
  "source_log" => "#{EXPECTED_BUILD_DIR}/omnibus-v9-retry6.log",
  "source_log_sha256" => "523564f9ab78e82b6d74ff9b2e501ea2f692aa3755bd30878de7a553773b3b38",
  "healthcheck_platform" => EXPECTED_NATIVE_PLATFORM,
  "healthcheck_implementation" => "health_check_ldd",
  "dynamic_strip_excludes" => EXPECTED_DYNAMIC_STRIP_EXCLUDES,
  "strip" => "completed",
  "packaging" => "all packagers skipped; null compressor",
}
resume_record_path = File.join(pkg_dir, "post-health-resume.json")
resume_record_tmp = "#{resume_record_path}.#{$$}"
File.open(resume_record_tmp, "wb", 0o644) do |file|
  file.write(FFI_Yajl::Encoder.encode(resume_record, pretty: true))
end
File.rename(resume_record_tmp, resume_record_path)
puts("KYLIN_POST_HEALTH_RESUME_OK")
