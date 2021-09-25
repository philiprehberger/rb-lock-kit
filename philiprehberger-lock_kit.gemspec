# frozen_string_literal: true

require_relative 'lib/philiprehberger/lock_kit/version'

Gem::Specification.new do |spec|
  spec.name = 'philiprehberger-lock_kit'
  spec.version = Philiprehberger::LockKit::VERSION
  spec.authors = ['Philip Rehberger']
  spec.email = ['me@philiprehberger.com']
  spec.summary = 'File-based and PID locking for process coordination'
  spec.description = 'File locks using flock and PID file locks with stale detection for coordinating ' \
                     'between processes. Timeout support and automatic cleanup.'
  spec.homepage = 'https://philiprehberger.com/open-source-packages/ruby/philiprehberger-lock_kit'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/philiprehberger/rb-lock-kit'
  spec.metadata['changelog_uri'] = 'https://github.com/philiprehberger/rb-lock-kit/blob/main/CHANGELOG.md'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/philiprehberger/rb-lock-kit/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.files = Dir['lib/**/*.rb', 'LICENSE', 'README.md', 'CHANGELOG.md']
  spec.require_paths = ['lib']
end
