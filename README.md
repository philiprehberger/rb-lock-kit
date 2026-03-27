# philiprehberger-lock_kit

[![Tests](https://github.com/philiprehberger/rb-lock-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/philiprehberger/rb-lock-kit/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/philiprehberger-lock_kit.svg)](https://rubygems.org/gems/philiprehberger-lock_kit)
[![License](https://img.shields.io/github/license/philiprehberger/rb-lock-kit)](LICENSE)
[![Sponsor](https://img.shields.io/badge/sponsor-GitHub%20Sponsors-ec6cb9)](https://github.com/sponsors/philiprehberger)

File-based and PID locking for process coordination

## Requirements

- Ruby >= 3.1

## Installation

Add to your Gemfile:

```ruby
gem "philiprehberger-lock_kit"
```

Or install directly:

```bash
gem install philiprehberger-lock_kit
```

## Usage

```ruby
require "philiprehberger/lock_kit"

Philiprehberger::LockKit.with_file_lock("/tmp/my.lock") do
  # exclusive work here
end
```

### File Locking with Timeout

```ruby
Philiprehberger::LockKit.with_file_lock("/tmp/my.lock", timeout: 5) do
  # waits up to 5 seconds for the lock
end
```

### PID File Locking

```ruby
Philiprehberger::LockKit.with_pid_lock("my_worker") do
  # only one process with this name can run at a time
end
```

### Manual File Lock

```ruby
lock = Philiprehberger::LockKit::FileLock.new("/tmp/my.lock")
lock.acquire(timeout: 10)
# ... do work ...
lock.release
```

### Manual PID Lock

```ruby
lock = Philiprehberger::LockKit::PidLock.new("my_worker", dir: "/var/run")
lock.acquire
# ... do work ...
lock.release
```

### Checking Lock Status

```ruby
Philiprehberger::LockKit.locked?("/tmp/my.lock")    # => true/false
Philiprehberger::LockKit.stale?("/tmp/my_worker.pid") # => true/false
```

## API

### `LockKit`

| Method | Description |
|--------|-------------|
| `.with_file_lock(path, timeout: nil) { }` | Execute block with exclusive file lock |
| `.with_pid_lock(name, dir: Dir.tmpdir) { }` | Execute block with PID file lock |
| `.locked?(path)` | Check if a file is currently locked |
| `.stale?(pid_file)` | Check if a PID file references a dead process |

### `LockKit::FileLock`

| Method | Description |
|--------|-------------|
| `.new(path)` | Create a file lock instance |
| `#acquire(timeout: nil)` | Acquire exclusive lock, optional timeout in seconds |
| `#release` | Release the lock and close the file handle |
| `#locked?` | Check if the file is currently locked |

### `LockKit::PidLock`

| Method | Description |
|--------|-------------|
| `.new(name, dir: Dir.tmpdir)` | Create a PID lock instance |
| `#acquire` | Acquire PID lock, raises if held by a living process |
| `#release` | Release lock and remove PID file |
| `#locked?` | Check if lock is held by a living process |
| `#stale?` | Check if PID file references a dead process |

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

[MIT](LICENSE)
