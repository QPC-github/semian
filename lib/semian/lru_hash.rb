class LRUHash
  # This LRU (Least Recently Used) hash will allow
  # the cleaning of resources as time goes on.
  # The goal is to remove the least recently used resources
  # everytime we set a new resource. A default window of
  # 5 minutes will allow empty item to stay in the hash
  # for a maximum of 5 minutes
  extend Forwardable
  def_delegators :@table, :size, :count, :empty?, :values
  attr_reader :table

  class NoopMutex
    def synchronize(*)
      yield
    end

    def try_lock
      true
    end

    def unlock
      true
    end

    def locked?
      true
    end

    def owned?
      true
    end
  end

  def keys
    @lock.synchronize { @table.keys }
  end

  def clear
    @lock.synchronize { @table.clear }
  end

  # Create an LRU hash
  #
  # Arguments:
  #   +max_size+ The maximum size of the table
  #   +min_time+ The minimum time a resource can live in the cache
  #
  # Note:
  #   The +min_time+ is a stronger guarantee than +max_size+. That is, if there are
  #   more than +max_size+ entries in the cache, but they've all been updated more
  #   recently than +min_time+, the garbage collection will not remove them and the
  #   cache can grow without bound. This usually means that you have many active
  #   circuits to disparate endpoints (or your circuit names are bad).
  #   If the max_size is 0, the garbage collection will be very aggressive and
  #   potentially computationally expensive.
  def initialize(max_size: Semian.maximum_lru_size, min_time: Semian.minimum_lru_time)
    @max_size = max_size
    @min_time = min_time
    @table = {}
    @lock =
      if Semian.thread_safe?
        Mutex.new
      else
        NoopMutex.new
      end
  end

  def set(key, resource)
    @lock.synchronize do
      @table.delete(key)
      @table[key] = resource
      resource.updated_at = Time.now
    end
    clear_unused_resources if @table.length > @max_size
  end

  # This method uses the property that "Hashes enumerate their values in the
  # order that the corresponding keys were inserted." Deleting a key and
  # re-inserting it effectively moves it to the front of the cache.
  # Update the `updated_at` field so we can use it later do decide if the
  # resource is "in use".
  def get(key)
    @lock.synchronize do
      found = @table.delete(key)
      if found
        @table[key] = found
        found.updated_at = Time.now
      end
      found
    end
  end

  def delete(key)
    @lock.synchronize do
      @table.delete(key)
    end
  end

  def []=(key, resource)
    set(key, resource)
  end

  def [](key)
    get(key)
  end

  private

  def clear_unused_resources
    payload = {
        size: @table.size,
        examined: 0,
        cleared: 0,
        elapsed: nil,
    }
    timer_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    ran = try_synchronize do
      # Clears resources that have not been used in the last 5 minutes.

      stop_time = Time.now - @min_time # Don't process resources updated after this time
      @table.each do |_, resource|
        payload[:examined] += 1

        # The update times of the resources in the LRU are monotonically increasing,
        # time, so we can stop looking once we find the first resource with an
        # update time after the stop_time.
        break if resource.updated_at > stop_time

        next if resource.in_use?

        resource = @table.delete(resource.name)
        if resource
          payload[:cleared] += 1
          resource.destroy
        end
      end
    end

    if ran
      payload[:elapsed] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - timer_start
      Semian.notify(:lru_hash_gc, self, nil, nil, payload)
    end
  end

  EXCEPTION_NEVER = {Exception => :never}.freeze
  EXCEPTION_IMMEDIATE = {Exception => :immediate}.freeze
  private_constant :EXCEPTION_NEVER
  private_constant :EXCEPTION_IMMEDIATE

  def try_synchronize
    Thread.handle_interrupt(EXCEPTION_NEVER) do
      begin
        return false unless @lock.try_lock
        Thread.handle_interrupt(EXCEPTION_IMMEDIATE) { yield }
        true
      ensure
        @lock.unlock if @lock.owned?
      end
    end
  end
end