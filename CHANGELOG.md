# Changelog

All notable changes to this gem will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.3] - 2026-04-09

### Fixed
- CI: split long gemspec summary line to satisfy RuboCop Layout/LineLength.

## [0.2.2] - 2026-04-08

### Changed
- Align gemspec summary with README description.

## [0.2.1] - 2026-03-31

### Changed
- Standardize README badges, support section, and license format

## [0.2.0] - 2026-03-28

### Added
- `LockKit.owner(path)` for inspecting lock holder metadata (PID, hostname, timestamp)
- `auto_cleanup:` option for automatic stale lock removal
- `LockKit.with_read_lock` and `LockKit.with_write_lock` for shared/exclusive locking
- `on_wait:` callback option for monitoring lock contention
- `LockKit.break!(path, force:)` for manual lock recovery

## [0.1.1] - 2026-03-26

### Added

- Add GitHub funding configuration

## [0.1.0] - 2026-03-26

### Added
- Initial release
- `FileLock` class with exclusive file locking via `flock(2)`
- `PidLock` class with PID file locking and stale process detection
- `with_file_lock` convenience method with optional timeout
- `with_pid_lock` convenience method with automatic cleanup
- `locked?` and `stale?` module-level query methods
