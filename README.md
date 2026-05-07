# philiprehberger-lock_kit

[![Tests](https://github.com/philiprehberger/rb-lock-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/philiprehberger/rb-lock-kit/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/philiprehberger-lock_kit.svg)](https://rubygems.org/gems/philiprehberger-lock_kit)
[![Last updated](https://img.shields.io/github/last-commit/philiprehberger/rb-lock-kit)](https://github.com/philiprehberger/rb-lock-kit/commits/main)

File-based and PID locking for process coordination with TTL expiration, stale detection, read-write locks, and lock owner identification

## Requirements

- Ruby >= 3.1

## Installation

Add to your Gemfile:

```ruby
gem 'philiprehberger-lock_kit'
```

Or install directly:

```bash
gem install philiprehberger-lock_kit
```

## Usage

```ruby
require 'philiprehberger/lock_kit'

Philiprehberger::LockKit.with_file_lock('/tmp/my.lock') do
  # exclusive work here
end
```

### File Locking with Timeout

```ruby
Philiprehberger::LockKit.with_file_lock('/tmp/my.lock', timeout: 5) do
  # waits up to 5 seconds for the lock
end
```

### PID File Locking

```ruby
Philiprehberger::LockKit.with_pid_lock('my_worker') do
  # only one process with this name can run at a time
end
```

### Read-Write Locks

```ruby
# Multiple readers can hold the lock concurrently
Philiprehberger::LockKit.with_read_lock('/tmp/data.lock', timeout: 5) do
  # read shared data
end

# Write lock is exclusive — no readers or other writers allowed
Philiprehberger::LockKit.with_write_lock('/tmp/data.lock', timeout: 5) do
  # write shared data
end
```

### Retry Lock

```ruby
# Retries lock acquisition with exponential backoff
Philiprehberger::LockKit.with_retry_lock('/tmp/my.lock', retries: 5, delay: 0.2, backoff: 2) do
  # acquired after retrying if initially contended
end

# With timeout per attempt, TTL, and custom cleanup
Philiprehberger::LockKit.with_retry_lock('/tmp/my.lock', retries: 3, delay: 0.1, backoff: 2, timeout: 5, ttl: 30) do
  # each attempt waits up to 5s; lock expires after 30s
end
```

### Lock with TTL (Time-to-Live)

```ruby
# Lock expires after 30 seconds — treated as stale once elapsed
Philiprehberger::LockKit.with_file_lock('/tmp/my.lock', ttl: 30) do
  # work that should not hold the lock indefinitely
end

# PID locks also support TTL
Philiprehberger::LockKit.with_pid_lock('my_worker', ttl: 60) do
  # expires after 60 seconds
end

# Check if a lock has expired
Philiprehberger::LockKit.expired?('/tmp/my.lock') # => true/false
```

### Automatic Stale Lock Cleanup

```ruby
Philiprehberger::LockKit.with_file_lock('/tmp/my.lock', auto_cleanup: true) do
  # automatically removes stale locks from dead processes
end

Philiprehberger::LockKit.with_pid_lock('my_worker', auto_cleanup: true) do
  # same for PID locks
end
```

### Lock Owner Identification

```ruby
info = Philiprehberger::LockKit.owner('/tmp/my.lock')
# => { pid: 12345, hostname: 'web-01', acquired_at: 2026-03-28 12:00:00 +0000 }
```

### Lock Age

```ruby
# Returns the age in seconds (Float) of an active lock, or nil if not locked
Philiprehberger::LockKit.age('/tmp/my.lock')
# => 12.34
```

### Lock Waiting with Callbacks

```ruby
Philiprehberger::LockKit.with_file_lock('/tmp/my.lock', timeout: 10, on_wait: ->(elapsed) { puts "Waiting #{elapsed}s..." }) do
  # callback fires every 0.5s while waiting
end
```

### Force Break Lock

```ruby
# Break stale locks only (raises if held by a live process)
Philiprehberger::LockKit.break!('/tmp/my.lock')
# => { broken: true, previous_owner: { pid: 12345, hostname: 'web-01', acquired_at: ... } }

# Force break any lock regardless of status
Philiprehberger::LockKit.break!('/tmp/my.lock', force: true)
```

### Manual File Lock

```ruby
lock = Philiprehberger::LockKit::FileLock.new('/tmp/my.lock')
lock.acquire(timeout: 10)
# ... do work ...
lock.release
```

### Manual PID Lock

```ruby
lock = Philiprehberger::LockKit::PidLock.new('my_worker', dir: '/var/run')
lock.acquire
# ... do work ...
lock.release
```

### Checking Lock Status

```ruby
Philiprehberger::LockKit.locked?('/tmp/my.lock')      # => true/false
Philiprehberger::LockKit.stale?('/tmp/my_worker.pid')  # => true/false
```

## API

### `LockKit`

| Method | Description |
|--------|-------------|
| `.with_file_lock(path, timeout: nil, auto_cleanup: false, on_wait: nil, ttl: nil) { }` | Execute block with exclusive file lock |
| `.with_retry_lock(path, retries: 3, delay: 0.1, backoff: 2, timeout: nil, auto_cleanup: true, ttl: nil) { }` | Execute block with file lock, retrying with exponential backoff |
| `.with_pid_lock(name, dir: Dir.tmpdir, auto_cleanup: false, ttl: nil) { }` | Execute block with PID file lock |
| `.with_read_lock(path, timeout: nil) { }` | Execute block with shared read lock |
| `.with_write_lock(path, timeout: nil) { }` | Execute block with exclusive write lock |
| `.locked?(path)` | Check if a file is currently locked |
| `.stale?(pid_file)` | Check if a PID file references a dead process |
| `.expired?(path)` | Check if a lock has expired based on its TTL |
| `.owner(path)` | Get lock owner metadata (pid, hostname, acquired_at) |
| `.age(path)` | Age in seconds of an active lock, or nil if not locked |
| `.break!(path, force: false)` | Break a lock (stale only by default, any with force) |
| `.rw_stats(path)` | Snapshot of a read-write lock as `{ readers:, write_locked: }` |

### `LockKit::FileLock`

| Method | Description |
|--------|-------------|
| `.new(path)` | Create a file lock instance |
| `#acquire(timeout: nil, auto_cleanup: false, on_wait: nil, ttl: nil)` | Acquire exclusive lock with optional timeout, cleanup, wait callback, and TTL |
| `#release` | Release the lock and close the file handle |
| `#locked?` | Check if the file is currently locked (false if expired) |
| `#expired?` | Check if the lock has expired based on its TTL |
| `#owner` | Get lock owner metadata |

### `LockKit::PidLock`

| Method | Description |
|--------|-------------|
| `.new(name, dir: Dir.tmpdir)` | Create a PID lock instance |
| `#acquire(auto_cleanup: false, ttl: nil)` | Acquire PID lock with optional TTL, raises if held by a living process |
| `#release` | Release lock and remove PID file |
| `#locked?` | Check if lock is held by a living process (false if expired) |
| `#expired?` | Check if the lock has expired based on its TTL |
| `#stale?` | Check if PID file references a dead process |
| `#owner` | Get lock owner metadata |

### `LockKit::ReadWriteLock`

| Method | Description |
|--------|-------------|
| `.new(path)` | Create a read-write lock instance |
| `#acquire_read(timeout: nil)` | Acquire shared read lock |
| `#release_read` | Release the read lock |
| `#acquire_write(timeout: nil)` | Acquire exclusive write lock |
| `#release_write` | Release the write lock |
| `#reader_count` | Get current number of active readers |
| `#write_locked?` | Non-blocking check for an active write lock |
| `#stats` | Snapshot as `{ readers:, write_locked: }` |

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## Support

If you find this project useful:

⭐ [Star the repo](https://github.com/philiprehberger/rb-lock-kit)

🐛 [Report issues](https://github.com/philiprehberger/rb-lock-kit/issues?q=is%3Aissue+is%3Aopen+label%3Abug)

💡 [Suggest features](https://github.com/philiprehberger/rb-lock-kit/issues?q=is%3Aissue+is%3Aopen+label%3Aenhancement)

❤️ [Sponsor development](https://github.com/sponsors/philiprehberger)

🌐 [All Open Source Projects](https://philiprehberger.com/open-source-packages)

💻 [GitHub Profile](https://github.com/philiprehberger)

🔗 [LinkedIn Profile](https://www.linkedin.com/in/philiprehberger)

## License

[MIT](LICENSE)
