# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

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

      it 'writes metadata file on acquire' do
        lock.acquire
        meta_path = "#{lock_path}.meta"
        expect(File.exist?(meta_path)).to be true

        data = JSON.parse(File.read(meta_path))
        expect(data['pid']).to eq(Process.pid)
        expect(data['hostname']).to be_a(String)
        expect(data['acquired_at']).to be_a(String)
        lock.release
      end

      it 'removes metadata file on release' do
        lock.acquire
        lock.release
        expect(File.exist?("#{lock_path}.meta")).to be false
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

    describe '#owner' do
      it 'returns nil when no lock is held' do
        expect(lock.owner).to be_nil
      end

      it 'returns metadata when lock is held' do
        lock.acquire
        info = lock.owner
        expect(info[:pid]).to eq(Process.pid)
        expect(info[:hostname]).to be_a(String)
        expect(info[:acquired_at]).to be_a(Time)
        lock.release
      end

      it 'returns nil after release' do
        lock.acquire
        lock.release
        expect(lock.owner).to be_nil
      end
    end

    describe 'auto_cleanup option' do
      it 'acquires lock when stale metadata exists' do
        # Create a stale metadata file
        meta_path = "#{lock_path}.meta"
        stale_meta = { 'pid' => 999_999_999, 'hostname' => 'old-host', 'acquired_at' => Time.now.iso8601 }
        File.write(meta_path, JSON.generate(stale_meta))
        FileUtils.touch(lock_path)

        expect(lock.acquire(auto_cleanup: true)).to be true
        lock.release
      end
    end

    describe 'on_wait callback' do
      it 'invokes the callback while waiting for the lock' do
        callbacks = []
        on_wait = ->(elapsed) { callbacks << elapsed }

        # Acquire lock in a thread, then try to acquire with callback
        lock.acquire
        lock2 = described_class.new(lock_path)

        thread = Thread.new do
          sleep 1.2
          lock.release
        end

        lock2.acquire(timeout: 5, on_wait: on_wait)
        thread.join
        lock2.release

        expect(callbacks).not_to be_empty
        expect(callbacks.first).to be_a(Numeric)
      end

      it 'does not invoke callback when lock is immediately available' do
        callbacks = []
        on_wait = ->(elapsed) { callbacks << elapsed }

        lock.acquire(timeout: 5, on_wait: on_wait)
        lock.release

        expect(callbacks).to be_empty
      end
    end

    describe 'TTL support' do
      it 'writes expires_at to metadata when ttl is provided' do
        lock.acquire(ttl: 60)
        meta_path = "#{lock_path}.meta"
        data = JSON.parse(File.read(meta_path))
        expect(data['expires_at']).to be_a(String)
        expect(Time.parse(data['expires_at'])).to be > Time.now
        lock.release
      end

      it 'does not write expires_at when ttl is nil' do
        lock.acquire
        meta_path = "#{lock_path}.meta"
        data = JSON.parse(File.read(meta_path))
        expect(data).not_to have_key('expires_at')
        lock.release
      end

      it 'reports expired? as false before TTL elapses' do
        lock.acquire(ttl: 60)
        expect(lock.expired?).to be false
        lock.release
      end

      it 'reports expired? as true after TTL elapses' do
        lock.acquire(ttl: 0.1)
        sleep 0.2
        expect(lock.expired?).to be true
        lock.release
      end

      it 'reports locked? as false when TTL has elapsed' do
        lock.acquire(ttl: 0.1)
        sleep 0.2
        lock2 = described_class.new(lock_path)
        expect(lock2.locked?).to be false
        lock.release
      end

      it 'cleans up expired locks with auto_cleanup' do
        lock.acquire(ttl: 0.1)
        sleep 0.2
        # Release without cleanup to leave stale metadata
        lock.instance_variable_get(:@file)&.flock(File::LOCK_UN)
        lock.instance_variable_get(:@file)&.close

        lock2 = described_class.new(lock_path)
        expect(lock2.acquire(auto_cleanup: true)).to be true
        lock2.release
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

        data = JSON.parse(File.read(pid_file))
        expect(data['pid']).to eq(Process.pid)
        expect(data['hostname']).to be_a(String)
        expect(data['acquired_at']).to be_a(String)

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
        stale_data = { 'pid' => 999_999_999, 'hostname' => 'old-host', 'acquired_at' => Time.now.iso8601 }
        File.write(pid_file, JSON.generate(stale_data))

        expect(lock.stale?).to be true
      end

      it 'returns false for a living process' do
        lock.acquire
        expect(lock.stale?).to be false
        lock.release
      end
    end

    describe '#owner' do
      it 'returns nil when no lock exists' do
        expect(lock.owner).to be_nil
      end

      it 'returns metadata when lock is held' do
        lock.acquire
        info = lock.owner
        expect(info[:pid]).to eq(Process.pid)
        expect(info[:hostname]).to be_a(String)
        expect(info[:acquired_at]).to be_a(Time)
        lock.release
      end
    end

    describe 'auto_cleanup option' do
      it 'cleans up stale lock and acquires' do
        pid_file = File.join(tmp_dir, "#{lock_name}.pid")
        stale_data = { 'pid' => 999_999_999, 'hostname' => 'old-host', 'acquired_at' => Time.now.iso8601 }
        File.write(pid_file, JSON.generate(stale_data))

        expect(lock.acquire(auto_cleanup: true)).to be true
        lock.release
      end
    end

    describe 'TTL support' do
      it 'writes expires_at to metadata when ttl is provided' do
        lock.acquire(ttl: 60)
        pid_file = File.join(tmp_dir, "#{lock_name}.pid")
        data = JSON.parse(File.read(pid_file))
        expect(data['expires_at']).to be_a(String)
        expect(Time.parse(data['expires_at'])).to be > Time.now
        lock.release
      end

      it 'does not write expires_at when ttl is nil' do
        lock.acquire
        pid_file = File.join(tmp_dir, "#{lock_name}.pid")
        data = JSON.parse(File.read(pid_file))
        expect(data).not_to have_key('expires_at')
        lock.release
      end

      it 'reports expired? as false before TTL elapses' do
        lock.acquire(ttl: 60)
        expect(lock.expired?).to be false
        lock.release
      end

      it 'reports expired? as true after TTL elapses' do
        lock.acquire(ttl: 0.1)
        sleep 0.2
        expect(lock.expired?).to be true
        lock.release
      end

      it 'reports locked? as false when TTL has elapsed' do
        lock.acquire(ttl: 0.1)
        sleep 0.2
        expect(lock.locked?).to be false
        lock.release
      end

      it 'allows acquiring an expired lock' do
        lock.acquire(ttl: 0.1)
        sleep 0.2

        other = described_class.new(lock_name, dir: tmp_dir)
        expect(other.acquire).to be true
        other.release
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
        stale_data = { 'pid' => 999_999_999, 'hostname' => 'old-host', 'acquired_at' => Time.now.iso8601 }
        File.write(pid_file, JSON.generate(stale_data))

        expect(lock.acquire).to be true
        data = JSON.parse(File.read(pid_file))
        expect(data['pid']).to eq(Process.pid)
        lock.release
      end

      it 'handles legacy plain PID format' do
        pid_file = File.join(tmp_dir, "#{lock_name}.pid")
        File.write(pid_file, '999999999')

        expect(lock.acquire).to be true
        lock.release
      end
    end
  end

  describe Philiprehberger::LockKit::ReadWriteLock do
    let(:rw_path) { File.join(tmp_dir, 'rw.lock') }

    subject(:rw_lock) { described_class.new(rw_path) }

    describe 'read lock' do
      it 'acquires and releases a read lock' do
        rw_lock.acquire_read(timeout: 1)
        expect(rw_lock.reader_count).to eq(1)
        rw_lock.release_read
        expect(rw_lock.reader_count).to eq(0)
      end

      it 'allows multiple concurrent readers' do
        lock1 = described_class.new(rw_path)
        lock2 = described_class.new(rw_path)

        lock1.acquire_read(timeout: 1)
        lock2.acquire_read(timeout: 1)

        expect(lock1.reader_count).to eq(2)

        lock1.release_read
        lock2.release_read
        expect(lock1.reader_count).to eq(0)
      end
    end

    describe 'write lock' do
      it 'acquires and releases a write lock' do
        expect(rw_lock.acquire_write(timeout: 1)).to be true
        rw_lock.release_write
      end

      it 'raises when write lock cannot be acquired without timeout' do
        lock1 = described_class.new(rw_path)
        lock2 = described_class.new(rw_path)

        lock1.acquire_write
        expect { lock2.acquire_write }.to raise_error(Philiprehberger::LockKit::Error, /Could not acquire write lock/)
        lock1.release_write
      end
    end

    describe 'read-write interaction' do
      it 'blocks write lock when readers are active' do
        reader = described_class.new(rw_path)
        writer = described_class.new(rw_path)

        reader.acquire_read(timeout: 1)
        expect { writer.acquire_write }.to raise_error(Philiprehberger::LockKit::Error, /readers still active/)
        reader.release_read
      end

      it 'write lock succeeds after readers release' do
        reader = described_class.new(rw_path)
        writer = described_class.new(rw_path)

        reader.acquire_read(timeout: 1)

        thread = Thread.new do
          sleep 0.2
          reader.release_read
        end

        expect(writer.acquire_write(timeout: 2)).to be true
        thread.join
        writer.release_write
      end
    end

    describe '#reader_count' do
      it 'returns 0 when no readers file exists' do
        expect(rw_lock.reader_count).to eq(0)
      end
    end

    describe '#write_locked?' do
      it 'returns false when no write lock is held' do
        expect(rw_lock.write_locked?).to be false
      end

      it 'returns true while a write lock is held' do
        described_class.new(rw_path).acquire_write
        begin
          other = described_class.new(rw_path)
          expect(other.write_locked?).to be true
        ensure
          rw_lock.release_write
        end
      end
    end

    describe '#stats' do
      it 'reports zero readers and no writer on an idle lock' do
        expect(rw_lock.stats).to eq(readers: 0, write_locked: false)
      end

      it 'reports active readers' do
        rw_lock.acquire_read
        begin
          expect(rw_lock.stats).to eq(readers: 1, write_locked: false)
        ensure
          rw_lock.release_read
        end
      end

      it 'reports a held write lock' do
        rw_lock.acquire_write
        begin
          other = described_class.new(rw_path)
          expect(other.stats).to eq(readers: 0, write_locked: true)
        ensure
          rw_lock.release_write
        end
      end
    end
  end

  describe '.with_file_lock' do
    it 'accepts ttl option' do
      result = described_class.with_file_lock(lock_path, ttl: 60) { 'ttl' }
      expect(result).to eq('ttl')
    end

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

    it 'accepts auto_cleanup option' do
      result = described_class.with_file_lock(lock_path, auto_cleanup: true) { 'clean' }
      expect(result).to eq('clean')
    end

    it 'accepts on_wait callback option' do
      callbacks = []
      result = described_class.with_file_lock(lock_path, timeout: 5, on_wait: ->(e) { callbacks << e }) { 'waited' }
      expect(result).to eq('waited')
    end
  end

  describe '.with_pid_lock' do
    it 'accepts ttl option' do
      result = described_class.with_pid_lock("ttl_test_#{Process.pid}", dir: tmp_dir, ttl: 60) { 'pid_ttl' }
      expect(result).to eq('pid_ttl')
    end

    it 'executes the block with a PID lock' do
      result = described_class.with_pid_lock("block_test_#{Process.pid}", dir: tmp_dir) { 99 }
      expect(result).to eq(99)
    end

    it 'cleans up the PID file after the block' do
      name = "cleanup_test_#{Process.pid}"
      described_class.with_pid_lock(name, dir: tmp_dir) { 'work' }
      expect(File.exist?(File.join(tmp_dir, "#{name}.pid"))).to be false
    end

    it 'accepts auto_cleanup option' do
      result = described_class.with_pid_lock("auto_test_#{Process.pid}", dir: tmp_dir, auto_cleanup: true) { 'auto' }
      expect(result).to eq('auto')
    end
  end

  describe '.with_read_lock' do
    it 'executes the block with a shared read lock' do
      rw_path = File.join(tmp_dir, 'rw.lock')
      result = described_class.with_read_lock(rw_path, timeout: 1) { 'reading' }
      expect(result).to eq('reading')
    end

    it 'releases the read lock after the block' do
      rw_path = File.join(tmp_dir, 'rw.lock')
      described_class.with_read_lock(rw_path, timeout: 1) { 'work' }
      rw = Philiprehberger::LockKit::ReadWriteLock.new(rw_path)
      expect(rw.reader_count).to eq(0)
    end

    it 'releases the read lock even if the block raises' do
      rw_path = File.join(tmp_dir, 'rw.lock')
      begin
        described_class.with_read_lock(rw_path, timeout: 1) { raise 'boom' }
      rescue RuntimeError
        nil
      end
      rw = Philiprehberger::LockKit::ReadWriteLock.new(rw_path)
      expect(rw.reader_count).to eq(0)
    end
  end

  describe '.with_write_lock' do
    it 'executes the block with an exclusive write lock' do
      rw_path = File.join(tmp_dir, 'rw.lock')
      result = described_class.with_write_lock(rw_path, timeout: 1) { 'writing' }
      expect(result).to eq('writing')
    end

    it 'releases the write lock after the block' do
      rw_path = File.join(tmp_dir, 'rw.lock')
      described_class.with_write_lock(rw_path, timeout: 1) { 'work' }
      # Should be able to acquire again
      result = described_class.with_write_lock(rw_path, timeout: 1) { 'again' }
      expect(result).to eq('again')
    end
  end

  describe '.with_retry_lock' do
    it 'acquires lock on first try and returns block value' do
      result = described_class.with_retry_lock(lock_path) { 'first_try' }
      expect(result).to eq('first_try')
    end

    it 'retries and succeeds after initial failure' do
      lock = Philiprehberger::LockKit::FileLock.new(lock_path)
      lock.acquire

      attempt = 0
      allow(described_class).to receive(:with_file_lock).and_wrap_original do |method, *args, **kwargs, &blk|
        attempt += 1
        if attempt == 1
          raise Philiprehberger::LockKit::Error, 'lock held'
        end

        method.call(*args, **kwargs, &blk)
      end

      lock.release

      result = described_class.with_retry_lock(lock_path, retries: 3, delay: 0.01) { 'recovered' }
      expect(result).to eq('recovered')
      expect(attempt).to eq(2)
    end

    it 'raises Error when all retries are exhausted' do
      allow(described_class).to receive(:with_file_lock).and_raise(Philiprehberger::LockKit::Error, 'lock held')

      expect do
        described_class.with_retry_lock(lock_path, retries: 3, delay: 0.01) { 'never' }
      end.to raise_error(Philiprehberger::LockKit::Error, 'lock held')
    end

    it 'passes timeout, auto_cleanup, and ttl to with_file_lock' do
      expect(described_class).to receive(:with_file_lock)
        .with(lock_path, timeout: 2, auto_cleanup: false, ttl: 30)
        .and_yield

      described_class.with_retry_lock(lock_path, timeout: 2, auto_cleanup: false, ttl: 30) { 'ok' }
    end

    it 'releases the lock after the block' do
      described_class.with_retry_lock(lock_path, delay: 0.01) { 'work' }
      lock = Philiprehberger::LockKit::FileLock.new(lock_path)
      expect(lock.locked?).to be false
    end
  end

  describe '.locked?' do
    it 'returns false for an unlocked file' do
      expect(described_class.locked?(lock_path)).to be false
    end
  end

  describe '.rw_stats' do
    let(:rw_path) { File.join(tmp_dir, 'rw_stats.lock') }

    it 'reports zero readers and no writer on a fresh path' do
      expect(described_class.rw_stats(rw_path)).to eq(readers: 0, write_locked: false)
    end

    it 'reports active readers and write status' do
      rw = Philiprehberger::LockKit::ReadWriteLock.new(rw_path)
      rw.acquire_read
      begin
        expect(described_class.rw_stats(rw_path)).to eq(readers: 1, write_locked: false)
      ensure
        rw.release_read
      end
    end
  end

  describe '.stale?' do
    it 'returns false when no file exists' do
      expect(described_class.stale?(File.join(tmp_dir, 'nonexistent.pid'))).to be false
    end

    it 'returns true for a dead process PID file (JSON format)' do
      pid_file = File.join(tmp_dir, 'dead.pid')
      data = { 'pid' => 999_999_999, 'hostname' => 'test', 'acquired_at' => Time.now.iso8601 }
      File.write(pid_file, JSON.generate(data))
      expect(described_class.stale?(pid_file)).to be true
    end

    it 'returns true for a dead process PID file (plain format)' do
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

  describe '.expired?' do
    it 'returns false when no lock exists' do
      expect(described_class.expired?(lock_path)).to be false
    end

    it 'returns false for a lock without TTL' do
      meta_path = "#{lock_path}.meta"
      data = { 'pid' => Process.pid, 'hostname' => 'test', 'acquired_at' => Time.now.iso8601 }
      File.write(meta_path, JSON.generate(data))
      expect(described_class.expired?(lock_path)).to be false
    end

    it 'returns false for a lock with future expiry' do
      meta_path = "#{lock_path}.meta"
      data = { 'pid' => Process.pid, 'hostname' => 'test', 'acquired_at' => Time.now.iso8601,
               'expires_at' => (Time.now + 3600).iso8601 }
      File.write(meta_path, JSON.generate(data))
      expect(described_class.expired?(lock_path)).to be false
    end

    it 'returns true for a lock with past expiry' do
      meta_path = "#{lock_path}.meta"
      data = { 'pid' => Process.pid, 'hostname' => 'test', 'acquired_at' => Time.now.iso8601,
               'expires_at' => (Time.now - 10).iso8601 }
      File.write(meta_path, JSON.generate(data))
      expect(described_class.expired?(lock_path)).to be true
    end

    it 'returns true for a PID lock with past expiry' do
      pid_file = File.join(tmp_dir, 'expired.pid')
      data = { 'pid' => Process.pid, 'hostname' => 'test', 'acquired_at' => Time.now.iso8601,
               'expires_at' => (Time.now - 10).iso8601 }
      File.write(pid_file, JSON.generate(data))
      expect(described_class.expired?(pid_file)).to be true
    end
  end

  describe '.owner' do
    it 'returns nil when no lock exists' do
      expect(described_class.owner(lock_path)).to be_nil
    end

    it 'returns metadata for a file lock' do
      lock = Philiprehberger::LockKit::FileLock.new(lock_path)
      lock.acquire
      info = described_class.owner(lock_path)
      expect(info[:pid]).to eq(Process.pid)
      expect(info[:hostname]).to be_a(String)
      expect(info[:acquired_at]).to be_a(Time)
      lock.release
    end

    it 'returns metadata for a PID lock' do
      pid_file = File.join(tmp_dir, 'owner_test.pid')
      data = { 'pid' => Process.pid, 'hostname' => 'test-host', 'acquired_at' => Time.now.iso8601 }
      File.write(pid_file, JSON.generate(data))

      info = described_class.owner(pid_file)
      expect(info[:pid]).to eq(Process.pid)
      expect(info[:hostname]).to eq('test-host')
      expect(info[:acquired_at]).to be_a(Time)
    end

    it 'returns nil after lock is released' do
      lock = Philiprehberger::LockKit::FileLock.new(lock_path)
      lock.acquire
      lock.release
      expect(described_class.owner(lock_path)).to be_nil
    end
  end

  describe '.break!' do
    it 'returns not locked when no lock exists' do
      result = described_class.break!(lock_path)
      expect(result).to eq({ broken: false, reason: 'not locked' })
    end

    it 'breaks a stale PID lock' do
      pid_file = File.join(tmp_dir, 'stale.pid')
      data = { 'pid' => 999_999_999, 'hostname' => 'old-host', 'acquired_at' => Time.now.iso8601 }
      File.write(pid_file, JSON.generate(data))

      result = described_class.break!(pid_file)
      expect(result[:broken]).to be true
      expect(result[:previous_owner][:pid]).to eq(999_999_999)
      expect(result[:previous_owner][:hostname]).to eq('old-host')
      expect(File.exist?(pid_file)).to be false
    end

    it 'raises when breaking a live lock without force' do
      pid_file = File.join(tmp_dir, 'live.pid')
      data = { 'pid' => Process.pid, 'hostname' => 'test', 'acquired_at' => Time.now.iso8601 }
      File.write(pid_file, JSON.generate(data))

      expect { described_class.break!(pid_file) }.to raise_error(
        Philiprehberger::LockKit::Error, /held by living process/
      )
      expect(File.exist?(pid_file)).to be true
    end

    it 'force breaks a live lock' do
      pid_file = File.join(tmp_dir, 'live.pid')
      data = { 'pid' => Process.pid, 'hostname' => 'test', 'acquired_at' => Time.now.iso8601 }
      File.write(pid_file, JSON.generate(data))

      result = described_class.break!(pid_file, force: true)
      expect(result[:broken]).to be true
      expect(result[:previous_owner][:pid]).to eq(Process.pid)
      expect(File.exist?(pid_file)).to be false
    end

    it 'removes metadata file when breaking a file lock' do
      meta_path = "#{lock_path}.meta"
      data = { 'pid' => 999_999_999, 'hostname' => 'test', 'acquired_at' => Time.now.iso8601 }
      File.write(meta_path, JSON.generate(data))
      FileUtils.touch(lock_path)

      result = described_class.break!(lock_path)
      expect(result[:broken]).to be true
      expect(File.exist?(lock_path)).to be false
      expect(File.exist?(meta_path)).to be false
    end
  end
end
