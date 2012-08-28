require 'socket'
require "uri"

class SshHammer

  # = Statsd: A Statsd client (https://github.com/etsy/statsd)
  #
  # @example Set up a global Statsd client for a server on localhost:9125
  #   $statsd = Statsd.new 'localhost', 8125
  # @example Send some stats
  #   $statsd.increment 'garets'
  #   $statsd.timing 'glork', 320
  #   $statsd.gauge 'bork', 100
  # @example Use {#time} to time the execution of a block
  #   $statsd.time('account.activate') { @account.activate! }
  # @example Create a namespaced statsd client and increment 'account.activate'
  #   statsd = Statsd.new('localhost').tap{|sd| sd.namespace = 'account'}
  #   statsd.increment 'activate'
  #
  # Statsd instances are thread safe for general usage, by using a thread local
  # UDPSocket and carrying no state. The attributes are stateful, and are not
  # mutexed, it is expected that users will not change these at runtime in
  # threaded environments. If users require such use cases, it is recommend that
  # users either mutex around their Statsd object, or create separate objects for
  # each namespace / host+port combination.
  #
  # @see https://github.com/reinh/statsd/blob/master/lib/statsd.rb
  class Stats
    PORT       = 8125
    CONF_FILES = ['./statsd.url',
                  '~/.ssh-hammer/statsd.url',
                  '/etc/ssh-hammer/statsd.url'].freeze
    # A namespace to prepend to all statsd calls.
    attr_reader :namespace

    # StatsD host. Defaults to 127.0.0.1.
    attr_reader :host

    # StatsD port. Defaults to 8125.
    attr_reader :port

    class << self
      def namespace(ns, opts = {})
        opts = {:host => '127.0.0.1', :port => PORT}.merge(opts)
        new(opts[:host], opts[:port]).tap {|n| n.namespace = ns }
      end

      def host=(host)
        instance.host = host
      end

      def host
        instance.host
      end

      def port=(port)
        instance.port = port
      end

      def port
        instance.port
      end

      def incr(stat, sample_rate = 1)
        instance.incr(stat, sample_rate)
      end

      def decr(stat, sample_rate = 1)
        instance.decr(stat, sample_rate)
      end

      def count(stat, count, sample_rate = 1)
        instance.count(stat, count, sample_rate)
      end

      def gauge(stat, value, sample_rate = 1)
        instance.gauge(stat, value, sample_rate)
      end

      def timing(stat, ms, sample_rate = 1)
        instance.timing(stat, ms, sample_rate)
      end

      def time(stat, sample_rate = 1, &blk)
        instance.time(stat, sample_rate, &blk)
      end

      def flush
        instance.flush
      end

      # @api private
      def instance
        @instance ||= new
      end

      def auto_configure
        if(conf = Stats::CONF_FILES.map{|f| File.expand_path(f) }.find{|f| File.exists?(f) })
          u = URI.parse(IO.read(conf).strip)
          @instance = new(u.host || '127.0.0.1', u.port || Stats::PORT)
        end
      end
    end

    # @param [String] host your statsd host
    # @param [Integer] port your statsd port
    def initialize(host = '127.0.0.1', port = PORT)
      self.host, self.port = host, port
      @prefix = nil
      @queue  = []
    end

    # @attribute [w] namespace
    #   Writes are not thread safe.
    def namespace=(namespace)
      @namespace = namespace
      @prefix = "#{namespace}."
    end

    # @attribute [w] host
    #   Writes are not thread safe.
    def host=(host)
      @host = host || '127.0.0.1'
    end

    # @attribute [w] port
    #   Writes are not thread safe.
    def port=(port)
      @port = port || PORT
    end

    # Sends an increment (count = 1) for the given stat to the statsd server.
    #
    # @param [String] stat stat name
    # @param [Numeric] sample_rate sample rate, 1 for always
    # @see #count
    def incr(stat, sample_rate=1)
      count stat, 1, sample_rate
    end

    # Sends a decrement (count = -1) for the given stat to the statsd server.
    #
    # @param [String] stat stat name
    # @param [Numeric] sample_rate sample rate, 1 for always
    # @see #count
    def decr(stat, sample_rate=1)
      count stat, -1, sample_rate
    end

    # Sends an arbitrary count for the given stat to the statsd server.
    #
    # @param [String] stat stat name
    # @param [Integer] count count
    # @param [Numeric] sample_rate sample rate, 1 for always
    def count(stat, count, sample_rate=1)
      send_stats stat, count, :c, sample_rate
    end

    # Sends an arbitary gauge value for the given stat to the statsd server.
    #
    # This is useful for recording things like available disk space,
    # memory usage, and the like, which have different semantics than
    # counters.
    #
    # @param [String] stat stat name.
    # @param [Numeric] gauge value.
    # @param [Numeric] sample_rate sample rate, 1 for always
    # @example Report the current user count:
    #   $statsd.gauge('user.count', User.count)
    def gauge(stat, value, sample_rate=1)
      send_stats stat, value, :g, sample_rate
    end

    # Sends a timing (in ms) for the given stat to the statsd server. The
    # sample_rate determines what percentage of the time this report is sent. The
    # statsd server then uses the sample_rate to correctly track the average
    # timing for the stat.
    #
    # @param [String] stat stat name
    # @param [Integer] ms timing in milliseconds
    # @param [Numeric] sample_rate sample rate, 1 for always
    def timing(stat, ms, sample_rate=1)
      send_stats stat, ms, :ms, sample_rate
    end

    # Reports execution time of the provided block using {#timing}.
    #
    # @param [String] stat stat name
    # @param [Numeric] sample_rate sample rate, 1 for always
    # @yield The operation to be timed
    # @see #timing
    # @example Report the time (in ms) taken to activate an account
    #   $statsd.time('account.activate') { @account.activate! }
    def time(stat, sample_rate = 1)
      return Timer.new(stat, stample_rate, self) unless block_given?
      start = Time.now
      result = yield
      timing(stat, ((Time.now - start) * 1000).round, sample_rate)
      result
    end

    # Immediately send any pending stats.
    def flush
      send_to_socket
    end

  private

    def send_stats(stat, delta, type, sample_rate=1)
      if sample_rate == 1 or rand < sample_rate
        # Replace Ruby module scoping with '.' and reserved chars (: | @) with underscores.
        stat = stat.to_s.gsub('::', '.').tr(':|@', '_')
        rate = "|@#{sample_rate}" unless sample_rate == 1
        @queue << "#{@prefix}#{stat}:#{delta}|#{type}#{rate}"
        @timer = (EM::Timer.new(0.5) { send_to_socket }) rescue nil unless @timer
      end
    rescue => boom
      warn("failed to schedule stats send: #{boom}")
      nil
    end

    def send_to_socket
      return if @queue.empty?
      socket.send(@queue.join("\n"), 0, @host, @port)
    rescue => boom
      warn("failed to send stats: #{boom}")
    ensure
      @queue.clear
      @timer, _ = nil, @timer.cancel unless @timer.nil?
    end

    def socket
      Thread.current[:statsd_socket] ||= UDPSocket.new
    end
  end

  # A simple class for keeping track of the time some operation took.
  # Timers are returned by Stats#time when no block is provided.
  class Timer
    def new(stat, sample_rate, parent)
      @stat        = stat
      @sample_rate = sample_rate
      @start       = Time.now
      @parent      = parent
    end

    # Stop the timer and report the elapsed time between creation of this timer and
    # the call to #stop. Subsequent calls to #stop will be ignored.
    def stop
      return unless @parent
      @parent.timing(@stat, ((Time.now - @start) * 1000).round, @sample_rate)
      @parent = nil
    end
  end
end

SshHammer::Stats.auto_configure

