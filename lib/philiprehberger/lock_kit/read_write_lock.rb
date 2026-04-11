# frozen_string_literal: true

module Philiprehberger
  module LockKit
    # Read-write lock supporting shared reads and exclusive writes
    #
    # Read locks are shared — multiple readers can hold the lock concurrently.
    # Write locks are exclusive — no readers or other writers are allowed.
    # Uses a `.readers` counter file alongside the lock file to track state.
    class ReadWriteLock
      # @param path [String] base path for the lock files
      def initialize(path)
        @path = path
        @write_lock_path = "#{path}.write"
        @readers_path = "#{path}.readers"
        @write_file = nil
      end

      # Acquire a shared read lock
      #
      # @param timeout [Numeric, nil] seconds to wait before raising
      # @return [true] when the lock is acquired
      # @raise [LockKit::Error] if a write lock is held and timeout expires
      def acquire_read(timeout: nil)
        deadline = timeout ? Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout : nil

        loop do
          # Check if a write lock is held
          unless write_locked?
            increment_readers
            # Double-check no writer snuck in
            unless write_locked?
              return true
            end

            decrement_readers
          end

          raise Error, "Could not acquire read lock on #{@path}" unless deadline

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            raise Error, "Timeout acquiring read lock on #{@path} after #{timeout}s"
          end

          sleep [0.05, remaining].min
        end
      end

      # Release the shared read lock
      #
      # @return [void]
      def release_read
        decrement_readers
      end

      # Acquire an exclusive write lock
      #
      # @param timeout [Numeric, nil] seconds to wait before raising
      # @return [true] when the lock is acquired
      # @raise [LockKit::Error] if the lock cannot be acquired
      def acquire_write(timeout: nil)
        @write_file = File.open(@write_lock_path, File::CREAT | File::RDWR)
        deadline = timeout ? Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout : nil

        # First, acquire the write file lock
        loop do
          break if @write_file.flock(File::LOCK_EX | File::LOCK_NB)

          if deadline
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              close_write_file
              raise Error, "Timeout acquiring write lock on #{@path} after #{timeout}s"
            end

            sleep [0.05, remaining].min
          else
            close_write_file
            raise Error, "Could not acquire write lock on #{@path}"
          end
        end

        # Then, wait for all readers to finish
        loop do
          break if reader_count.zero?

          if deadline
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              @write_file.flock(File::LOCK_UN)
              close_write_file
              raise Error, "Timeout acquiring write lock on #{@path} after #{timeout}s — readers still active"
            end

            sleep [0.05, remaining].min
          else
            @write_file.flock(File::LOCK_UN)
            close_write_file
            raise Error, "Could not acquire write lock on #{@path} — readers still active"
          end
        end

        true
      end

      # Release the exclusive write lock
      #
      # @return [void]
      def release_write
        return unless @write_file

        @write_file.flock(File::LOCK_UN)
        close_write_file
      end

      # Return the current number of active readers
      #
      # @return [Integer]
      def reader_count
        return 0 unless File.exist?(@readers_path)

        count = File.read(@readers_path).strip.to_i
        count.negative? ? 0 : count
      rescue Errno::ENOENT
        0
      end

      # Non-blocking check for whether a write lock is currently held.
      #
      # @return [Boolean]
      def write_locked?
        return false unless File.exist?(@write_lock_path)

        f = File.open(@write_lock_path, File::CREAT | File::RDWR)
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

      # Snapshot of the current lock state: readers and writer presence.
      #
      # @return [Hash] `{ readers: Integer, write_locked: Boolean }`
      def stats
        { readers: reader_count, write_locked: write_locked? }
      end

      def increment_readers
        update_reader_count(1)
      end

      def decrement_readers
        update_reader_count(-1)
      end

      def update_reader_count(delta)
        lock_path = "#{@readers_path}.lock"
        File.open(lock_path, File::CREAT | File::RDWR) do |f|
          f.flock(File::LOCK_EX)
          current = begin
            File.read(@readers_path).strip.to_i
          rescue Errno::ENOENT
            0
          end
          new_count = [current + delta, 0].max
          File.write(@readers_path, new_count.to_s)
          f.flock(File::LOCK_UN)
        end
      end

      def close_write_file
        @write_file&.close
        @write_file = nil
      end
    end
  end
end
