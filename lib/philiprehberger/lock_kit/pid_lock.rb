# frozen_string_literal: true

require 'json'
require 'socket'
require 'tmpdir'

module Philiprehberger
  module LockKit
    # PID-file based lock with stale process detection
    #
    # Writes the current process ID, hostname, and timestamp to a file in JSON
    # format. Other processes can check the file to determine if the lock holder
    # is still alive, enabling automatic recovery from crashed processes.
    class PidLock
      # @param name [String] lock name (used as the PID file basename)
      # @param dir [String] directory for the PID file (defaults to system tmpdir)
      def initialize(name, dir: Dir.tmpdir)
        @name = name
        @dir = dir
        @pid_path = File.join(dir, "#{name}.pid")
        @acquired = false
      end

      # Acquire the PID lock
      #
      # Creates a PID file containing metadata (PID, hostname, timestamp) in
      # JSON format. If a PID file already exists, checks whether the owning
      # process is still alive. Stale PID files from dead processes are
      # automatically cleaned up.
      #
      # @param auto_cleanup [Boolean] when true, automatically remove stale locks
      # @param ttl [Numeric, nil] time-to-live in seconds; lock expires after this duration
      # @return [true] when the lock is acquired
      # @raise [LockKit::Error] if the lock is held by a living process
      def acquire(auto_cleanup: false, ttl: nil)
        @ttl = ttl

        if File.exist?(@pid_path)
          # Check TTL expiration first
          if lock_expired?
            FileUtils.rm_f(@pid_path)
          else
            existing_pid = read_pid

            if existing_pid && process_alive?(existing_pid)
              raise Error, "Lock '#{@name}' is held by process #{existing_pid}"
            end

            # Stale PID file — remove it
            FileUtils.rm_f(@pid_path)
          end
        end

        metadata = {
          'pid' => Process.pid,
          'hostname' => Socket.gethostname,
          'acquired_at' => Time.now.iso8601
        }
        metadata['expires_at'] = (Time.now + ttl).iso8601 if ttl
        File.write(@pid_path, JSON.generate(metadata))
        @acquired = true
        true
      end

      # Release the lock by removing the PID file
      #
      # Only removes the file if it was written by this process.
      #
      # @return [void]
      def release
        return unless @acquired

        File.delete(@pid_path) if File.exist?(@pid_path) && read_pid == Process.pid

        @acquired = false
      end

      # Check whether the lock is currently held by a living process
      #
      # Returns false if the lock has expired (TTL elapsed).
      #
      # @return [Boolean]
      def locked?
        return false unless File.exist?(@pid_path)
        return false if expired?

        pid = read_pid
        return false unless pid

        process_alive?(pid)
      end

      # Check whether the PID file references a dead process
      #
      # @return [Boolean]
      def stale?
        return false unless File.exist?(@pid_path)

        pid = read_pid
        return true unless pid

        !process_alive?(pid)
      end

      # Check whether the lock has expired based on its TTL
      #
      # @return [Boolean] true if the lock metadata contains an expires_at time that has passed
      def expired?
        lock_expired?
      end

      # Read lock owner metadata from the PID file
      #
      # @return [Hash, nil] hash with :pid, :hostname, :acquired_at keys or nil
      def owner
        return nil unless File.exist?(@pid_path)

        read_metadata
      rescue Errno::ENOENT
        nil
      end

      private

      def lock_expired?
        return false unless File.exist?(@pid_path)

        content = File.read(@pid_path).strip
        return false if content.empty?

        data = JSON.parse(content)
        return false unless data.is_a?(Hash)

        expires_at = data['expires_at']
        return false unless expires_at

        Time.parse(expires_at) <= Time.now
      rescue JSON::ParserError, Errno::ENOENT
        false
      end

      # @return [Integer, nil]
      def read_pid
        content = File.read(@pid_path).strip
        return nil if content.empty?

        # Try JSON format first
        data = JSON.parse(content)
        data.is_a?(Hash) ? data['pid'] : Integer(data)
      rescue JSON::ParserError
        # Fall back to plain PID format for backwards compatibility
        Integer(content)
      rescue ArgumentError, Errno::ENOENT
        nil
      end

      # @return [Hash, nil] parsed metadata with symbolized keys
      def read_metadata
        content = File.read(@pid_path).strip
        return nil if content.empty?

        data = JSON.parse(content)
        {
          pid: data['pid'],
          hostname: data['hostname'],
          acquired_at: data['acquired_at'] ? Time.parse(data['acquired_at']) : nil
        }
      rescue JSON::ParserError
        # Plain PID format — limited metadata
        pid = Integer(content, exception: false)
        return nil unless pid

        { pid: pid, hostname: nil, acquired_at: nil }
      rescue Errno::ENOENT
        nil
      end

      # @param pid [Integer]
      # @return [Boolean]
      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        # Process exists but we don't have permission to signal it
        true
      end
    end
  end
end
