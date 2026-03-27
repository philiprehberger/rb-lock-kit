# frozen_string_literal: true

require 'tmpdir'

module Philiprehberger
  module LockKit
    # PID-file based lock with stale process detection
    #
    # Writes the current process ID to a file. Other processes can check the
    # file to determine if the lock holder is still alive, enabling automatic
    # recovery from crashed processes.
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
      # Creates a PID file containing the current process ID. If a PID file
      # already exists, checks whether the owning process is still alive. Stale
      # PID files from dead processes are automatically cleaned up.
      #
      # @return [true] when the lock is acquired
      # @raise [LockKit::Error] if the lock is held by a living process
      def acquire
        if File.exist?(@pid_path)
          existing_pid = read_pid

          if existing_pid && process_alive?(existing_pid)
            raise Error, "Lock '#{@name}' is held by process #{existing_pid}"
          end

          # Stale PID file — remove it
          FileUtils.rm_f(@pid_path)
        end

        File.write(@pid_path, Process.pid.to_s)
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
      # @return [Boolean]
      def locked?
        return false unless File.exist?(@pid_path)

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

      private

      # @return [Integer, nil]
      def read_pid
        content = File.read(@pid_path).strip
        return nil if content.empty?

        Integer(content)
      rescue ArgumentError, Errno::ENOENT
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
