# frozen_string_literal: true

require_relative 'lock_kit/version'
require_relative 'lock_kit/file_lock'
require_relative 'lock_kit/pid_lock'

module Philiprehberger
  module LockKit
    class Error < StandardError; end

    # Execute a block while holding an exclusive file lock
    #
    # @param path [String] path to the lock file
    # @param timeout [Numeric, nil] seconds to wait before raising
    # @yield block to execute while the lock is held
    # @return [Object] the return value of the block
    # @raise [Error] if the lock cannot be acquired
    def self.with_file_lock(path, timeout: nil, &block)
      lock = FileLock.new(path)
      lock.acquire(timeout: timeout)
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
    # @yield block to execute while the lock is held
    # @return [Object] the return value of the block
    # @raise [Error] if the lock is held by another process
    def self.with_pid_lock(name, dir: Dir.tmpdir, &block)
      lock = PidLock.new(name, dir: dir)
      lock.acquire
      begin
        block.call
      ensure
        lock.release
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

      pid = Integer(content)
      Process.kill(0, pid)
      false
    rescue ArgumentError
      true
    rescue Errno::ESRCH
      true
    rescue Errno::EPERM
      false
    end
  end
end
