# frozen_string_literal: true

require 'time'

require_relative 'lock_kit/version'
require_relative 'lock_kit/file_lock'
require_relative 'lock_kit/pid_lock'
require_relative 'lock_kit/read_write_lock'

module Philiprehberger
  module LockKit
    class Error < StandardError; end

    # Execute a block while holding an exclusive file lock
    #
    # @param path [String] path to the lock file
    # @param timeout [Numeric, nil] seconds to wait before raising
    # @param auto_cleanup [Boolean] automatically remove stale locks before acquiring
    # @param on_wait [Proc, nil] callback invoked every 0.5s while waiting; receives elapsed seconds
    # @param ttl [Numeric, nil] time-to-live in seconds; lock expires after this duration
    # @yield block to execute while the lock is held
    # @return [Object] the return value of the block
    # @raise [Error] if the lock cannot be acquired
    def self.with_file_lock(path, timeout: nil, auto_cleanup: false, on_wait: nil, ttl: nil, &block)
      lock = FileLock.new(path)
      lock.acquire(timeout: timeout, auto_cleanup: auto_cleanup, on_wait: on_wait, ttl: ttl)
      begin
        block.call
      ensure
        lock.release
      end
    end

    # Execute a block while holding a PID file lock
    #
    # @param name [String] lock name
    # @param dir [String] directory for the PID file
    # @param auto_cleanup [Boolean] automatically remove stale locks before acquiring
    # @param ttl [Numeric, nil] time-to-live in seconds; lock expires after this duration
    # @yield block to execute while the lock is held
    # @return [Object] the return value of the block
    # @raise [Error] if the lock is held by another process
    def self.with_pid_lock(name, dir: Dir.tmpdir, auto_cleanup: false, ttl: nil, &block)
      lock = PidLock.new(name, dir: dir)
      lock.acquire(auto_cleanup: auto_cleanup, ttl: ttl)
      begin
        block.call
      ensure
        lock.release
      end
    end

    # Execute a block while holding a shared read lock
    #
    # Multiple readers can hold the lock concurrently. Blocks if a write lock
    # is held.
    #
    # @param path [String] base path for the lock files
    # @param timeout [Numeric, nil] seconds to wait before raising
    # @yield block to execute while the read lock is held
    # @return [Object] the return value of the block
    # @raise [Error] if the lock cannot be acquired
    def self.with_read_lock(path, timeout: nil, &block)
      lock = ReadWriteLock.new(path)
      lock.acquire_read(timeout: timeout)
      begin
        block.call
      ensure
        lock.release_read
      end
    end

    # Execute a block while holding an exclusive write lock
    #
    # No readers or other writers are allowed while the write lock is held.
    #
    # @param path [String] base path for the lock files
    # @param timeout [Numeric, nil] seconds to wait before raising
    # @yield block to execute while the write lock is held
    # @return [Object] the return value of the block
    # @raise [Error] if the lock cannot be acquired
    def self.with_write_lock(path, timeout: nil, &block)
      lock = ReadWriteLock.new(path)
      lock.acquire_write(timeout: timeout)
      begin
        block.call
      ensure
        lock.release_write
      end
    end

    # Check if a file is currently locked by another process
    #
    # @param path [String] path to the lock file
    # @return [Boolean]
    def self.locked?(path)
      FileLock.new(path).locked?
    end

    # Check if a PID file references a dead process
    #
    # @param pid_file [String] path to the PID file
    # @return [Boolean]
    def self.stale?(pid_file)
      return false unless File.exist?(pid_file)

      content = File.read(pid_file).strip
      return true if content.empty?

      # Try JSON format first
      pid = begin
        data = JSON.parse(content)
        data.is_a?(Hash) ? data['pid'] : Integer(data)
      rescue JSON::ParserError
        Integer(content)
      end

      Process.kill(0, pid)
      false
    rescue ArgumentError
      true
    rescue Errno::ESRCH
      true
    rescue Errno::EPERM
      false
    end

    # Check if a lock has expired based on its TTL
    #
    # @param path [String] path to the lock file or PID file
    # @return [Boolean] true if the lock metadata contains an expires_at time that has passed
    def self.expired?(path)
      # Check file lock metadata
      meta_path = "#{path}.meta"
      target = if File.exist?(meta_path)
                 meta_path
               elsif File.exist?(path)
                 path
               end

      return false unless target

      content = File.read(target).strip
      return false if content.empty?

      data = JSON.parse(content)
      expires_at = data['expires_at']
      return false unless expires_at

      Time.parse(expires_at) <= Time.now
    rescue JSON::ParserError, Errno::ENOENT
      false
    end

    # Get lock owner metadata
    #
    # @param path [String] path to the lock file or PID file
    # @return [Hash, nil] hash with :pid, :hostname, :acquired_at keys or nil if not locked
    def self.owner(path)
      # Check for file lock metadata
      meta_path = "#{path}.meta"
      if File.exist?(meta_path)
        content = File.read(meta_path).strip
        unless content.empty?
          data = JSON.parse(content)
          return {
            pid: data['pid'],
            hostname: data['hostname'],
            acquired_at: data['acquired_at'] ? Time.parse(data['acquired_at']) : nil
          }
        end
      end

      # Check for PID lock (JSON format)
      if File.exist?(path)
        content = File.read(path).strip
        unless content.empty?
          data = JSON.parse(content)
          return {
            pid: data['pid'],
            hostname: data['hostname'],
            acquired_at: data['acquired_at'] ? Time.parse(data['acquired_at']) : nil
          }
        end
      end

      nil
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    # Force break a lock
    #
    # @param path [String] path to the lock file or PID file
    # @param force [Boolean] when true, break any lock regardless of PID status
    # @return [Hash] result with :broken and :previous_owner or :reason keys
    # @raise [Error] if the lock is held by a live process and force is false
    def self.break!(path, force: false)
      meta_path = "#{path}.meta"

      # Determine the previous owner
      previous_owner = owner(path)

      unless previous_owner || File.exist?(path)
        return { broken: false, reason: 'not locked' }
      end

      # Check if the lock holder is alive
      if previous_owner && previous_owner[:pid]
        alive = begin
          Process.kill(0, previous_owner[:pid])
          true
        rescue Errno::ESRCH
          false
        rescue Errno::EPERM
          true
        end

        if alive && !force
          raise Error, "Lock on #{path} is held by living process #{previous_owner[:pid]}"
        end
      end

      # Break the lock
      FileUtils.rm_f(path)
      FileUtils.rm_f(meta_path)

      if previous_owner
        { broken: true, previous_owner: previous_owner }
      else
        { broken: true, previous_owner: nil }
      end
    end
  end
end
