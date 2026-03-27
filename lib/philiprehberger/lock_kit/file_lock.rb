# frozen_string_literal: true

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
        @file = nil
      end

      # Acquire an exclusive lock on the file
      #
      # @param timeout [Numeric, nil] seconds to wait before raising; nil means non-blocking single attempt
      # @return [true] when the lock is acquired
      # @raise [LockKit::Error] if the lock cannot be acquired
      def acquire(timeout: nil)
        @file = File.open(@path, File::CREAT | File::RDWR)

        if timeout.nil?
          unless @file.flock(File::LOCK_EX | File::LOCK_NB)
            close_file
            raise Error, "Could not acquire lock on #{@path}"
          end
        else
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

          until @file.flock(File::LOCK_EX | File::LOCK_NB)
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              close_file
              raise Error, "Timeout acquiring lock on #{@path} after #{timeout}s"
            end

            sleep [0.05, remaining].min
          end
        end

        true
      end

      # Release the lock and close the file handle
      #
      # @return [void]
      def release
        return unless @file

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

      private

      def close_file
        @file&.close
        @file = nil
      end
    end
  end
end
