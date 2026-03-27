# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Philiprehberger::LockKit do
  let(:tmp_dir) { Dir.mktmpdir('lock_kit_test') }
  let(:lock_path) { File.join(tmp_dir, 'test.lock') }

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  it 'has a version number' do
    expect(Philiprehberger::LockKit::VERSION).not_to be_nil
  end

  describe Philiprehberger::LockKit::FileLock do
    subject(:lock) { described_class.new(lock_path) }

    describe '#acquire and #release' do
      it 'acquires and releases a file lock' do
        expect(lock.acquire).to be true
        lock.release
      end

      it 'creates the lock file on acquire' do
        lock.acquire
        expect(File.exist?(lock_path)).to be true
        lock.release
      end
    end

    describe '#locked?' do
      it 'returns false when no lock is held' do
        expect(lock.locked?).to be false
      end

      it 'returns false after lock is released' do
        lock.acquire
        lock.release
        expect(lock.locked?).to be false
      end
    end

    describe 'concurrent access' do
      it 'allows re-acquiring after release' do
        lock.acquire
        lock.release

        lock2 = described_class.new(lock_path)
        expect(lock2.acquire).to be true
        lock2.release
      end
    end
  end

  describe Philiprehberger::LockKit::PidLock do
    let(:lock_name) { "test_lock_#{Process.pid}" }

    subject(:lock) { described_class.new(lock_name, dir: tmp_dir) }

    describe '#acquire and #release' do
      it 'acquires and releases a PID lock' do
        expect(lock.acquire).to be true
        pid_file = File.join(tmp_dir, "#{lock_name}.pid")
        expect(File.exist?(pid_file)).to be true
        expect(File.read(pid_file).strip).to eq(Process.pid.to_s)

        lock.release
        expect(File.exist?(pid_file)).to be false
      end
    end

    describe '#locked?' do
      it 'returns false when no lock exists' do
        expect(lock.locked?).to be false
      end

      it 'returns true when lock is held by current process' do
        lock.acquire
        expect(lock.locked?).to be true
        lock.release
      end
    end

    describe '#stale?' do
      it 'returns false when no PID file exists' do
        expect(lock.stale?).to be false
      end

      it 'detects a stale PID file from a dead process' do
        pid_file = File.join(tmp_dir, "#{lock_name}.pid")
        File.write(pid_file, '999999999')

        expect(lock.stale?).to be true
      end

      it 'returns false for a living process' do
        lock.acquire
        expect(lock.stale?).to be false
        lock.release
      end
    end

    describe 'concurrent lock attempts' do
      it 'raises Error when lock is held by current process' do
        lock.acquire

        other = described_class.new(lock_name, dir: tmp_dir)
        expect { other.acquire }.to raise_error(
          Philiprehberger::LockKit::Error, /held by process/
        )

        lock.release
      end

      it 'acquires lock after stale PID is cleaned up' do
        pid_file = File.join(tmp_dir, "#{lock_name}.pid")
        File.write(pid_file, '999999999')

        expect(lock.acquire).to be true
        expect(File.read(pid_file).strip).to eq(Process.pid.to_s)
        lock.release
      end
    end
  end

  describe '.with_file_lock' do
    it 'executes the block and returns its value' do
      result = described_class.with_file_lock(lock_path) { 42 }
      expect(result).to eq(42)
    end

    it 'releases the lock after the block' do
      described_class.with_file_lock(lock_path) { 'work' }
      lock = Philiprehberger::LockKit::FileLock.new(lock_path)
      expect(lock.locked?).to be false
    end

    it 'releases the lock even if the block raises' do
      begin
        described_class.with_file_lock(lock_path) { raise 'boom' }
      rescue RuntimeError
        nil
      end

      lock = Philiprehberger::LockKit::FileLock.new(lock_path)
      expect(lock.locked?).to be false
    end
  end

  describe '.with_pid_lock' do
    it 'executes the block with a PID lock' do
      result = described_class.with_pid_lock("block_test_#{Process.pid}", dir: tmp_dir) { 99 }
      expect(result).to eq(99)
    end

    it 'cleans up the PID file after the block' do
      name = "cleanup_test_#{Process.pid}"
      described_class.with_pid_lock(name, dir: tmp_dir) { 'work' }
      expect(File.exist?(File.join(tmp_dir, "#{name}.pid"))).to be false
    end
  end

  describe '.locked?' do
    it 'returns false for an unlocked file' do
      expect(described_class.locked?(lock_path)).to be false
    end
  end

  describe '.stale?' do
    it 'returns false when no file exists' do
      expect(described_class.stale?(File.join(tmp_dir, 'nonexistent.pid'))).to be false
    end

    it 'returns true for a dead process PID file' do
      pid_file = File.join(tmp_dir, 'dead.pid')
      File.write(pid_file, '999999999')
      expect(described_class.stale?(pid_file)).to be true
    end

    it 'returns false for a living process PID file' do
      pid_file = File.join(tmp_dir, 'alive.pid')
      File.write(pid_file, Process.pid.to_s)
      expect(described_class.stale?(pid_file)).to be false
    end
  end
end
