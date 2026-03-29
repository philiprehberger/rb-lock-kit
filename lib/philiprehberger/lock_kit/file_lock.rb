# frozen_string_literal: true

require 'json'
require 'socket'

module Philiprehberger
  module LockKit
    # Exclusive file lock using flock(2)
    #
    # Provides process-level mutual exclusion via the filesystem. The lock is
    # advisory and relies on all participants using the same lock file path.
    class FileLock
      # @param path [String] path to the lock file
      def initialize(path)
        @path = path
        @meta_path = "#{path}.meta"
        @file = nil
      end

      # Acquire an exclusive lock on the file
      #
      # @param timeout [Numeric, nil] seconds to wait before raising; nil means non-blocking single attempt
      # @param auto_cleanup [Boolean] when true, check for stale locks and remove them
      # @param on_wait [Proc, nil] callback invoked every 0.5s while waiting; receives elapsed seconds
      # @return [true] when the lock is acquired
      # @raise [LockKit::Error] if the lock cannot be acquired
      def acquire(timeout: nil, auto_cleanup: false, on_wait: nil)
        if auto_cleanup
          cleanup_stale_lock
        end

        @file = File.open(@path, File::CREAT | File::RDWR)

        if timeout.nil?
          unless @file.flock(File::LOCK_EX | File::LOCK_NB)
            close_file
            raise Error, "Could not acquire lock on #{@path}"
          end
        else
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          last_callback = start_time

          until @file.flock(File::LOCK_EX | File::LOCK_NB)
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            remaining = deadline - now

            if remaining <= 0
              close_file
              raise Error, "Timeout acquiring lock on #{@path} after #{timeout}s"
            end

            if on_wait && (now - last_callback) >= 0.5
              elapsed = (now - start_time).round(1)
              on_wait.call(elapsed)
              last_callback = now
            end

            sleep [0.05, remaining].min
          end
        end

        write_metadata
        true
      end

      # Release the lock and close the file handle
      #
      # @return [void]
      def release
        return unless @file

        remove_metadata
        @file.flock(File::LOCK_UN)
        close_file
      end

      # Check whether the file is currently locked by another process
      #
      # Opens the file, attempts a non-blocking exclusive lock, and immediately
      # releases it. Returns true if the lock attempt fails (file is locked).
      #
      # @return [Boolean]
      def locked?
        return false unless File.exist?(@path)

        f = File.open(@path, File::CREAT | File::RDWR)
        got_lock = f.flock(File::LOCK_EX | File::LOCK_NB)
        if got_lock
          f.flock(File::LOCK_UN)
          f.close
          false
        else
          f.close
          true
        end
      end

      # Read lock owner metadata
      #
      # @return [Hash, nil] hash with :pid, :hostname, :acquired_at keys or nil
      def owner
        return nil unless File.exist?(@meta_path)

        content = File.read(@meta_path).strip
        return nil if content.empty?

        data = JSON.parse(content)
        {
          pid: data['pid'],
          hostname: data['hostname'],
          acquired_at: data['acquired_at'] ? Time.parse(data['acquired_at']) : nil
        }
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end

      private

      def write_metadata
        metadata = {
          'pid' => Process.pid,
          'hostname' => Socket.gethostname,
          'acquired_at' => Time.now.iso8601
        }
        File.write(@meta_path, JSON.generate(metadata))
      end

      def remove_metadata
        FileUtils.rm_f(@meta_path)
      rescue Errno::ENOENT
        nil
      end

      def cleanup_stale_lock
        return unless File.exist?(@path)

        meta_path = "#{@path}.meta"
        return unless File.exist?(meta_path)

        content = File.read(meta_path).strip
        return if content.empty?

        data = JSON.parse(content)
        pid = data['pid']
        return unless pid

        unless process_alive?(pid)
          FileUtils.rm_f(meta_path)
        end
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def close_file
        @file&.close
        @file = nil
      end
    end
  end
end
