require 'digest/sha1'

class MemCache
  class ActiveRecord
    DEFAULT_OPTIONS = {
      :autofix_keys        => false,
      :check_size          => true,
      :failover            => false,
      :logger              => nil,
      :multithread         => true,
      :namespace           => nil,
      :namespace_separator => ':',
      :no_reply            => false,
      :readonly            => false,
      :timeout             => nil,
    }

    MAX_KEY_SIZE   = 250
    MAX_VALUE_SIZE = 2 ** 20
    THIRTY_DAYS    = 60 * 60 * 24 * 30

    COLUMN_NAMES = {
      :key    => 'key',
      :value  => 'value',
      :cas    => 'cas',
      :expiry => 'expiry',
    }

    STORED     = "STORED\r\n"
    NOT_STORED = "NOT_STORED\r\n"
    EXISTS     = "EXISTS\r\n"
    DELETED    = "DELETED\r\n"
    NOT_FOUND  = "NOT_FOUND\r\n"

    attr_reader :autofix_keys
    attr_reader :failover
    attr_reader :logger
    attr_reader :multithread
    attr_reader :namespace
    attr_reader :no_reply
    attr_reader :timeout

    def initialize(active_record, options = {})
      @ar = active_record

      [
        :check_size,
        :failover,
        :logger,
        :multithread,
        :timeout,
      ].each do |name|
        if options.key?(name) && options[name] != DEFAULT_OPTIONS[name]
          raise ArgumentError, "#{name} isn't changeable"
        end
      end

      options = DEFAULT_OPTIONS.merge(options)
      @autofix_keys        = options[:autofix_keys]
      @check_size          = options[:check_size]
      @failover            = options[:failover]
      @logger              = options[:logger]
      @multithread         = options[:multithread]
      @namespace           = options[:namespace]
      @namespace_separator = options[:namespace_separator]
      @no_reply            = options[:no_reply]
      @readonly            = options[:readonly]
      @timeout             = options[:timeout]
    end

    def inspect
      '<%s: %s, ns: %p, ro: %p>' %
        [self.class, @ar, @namespace, @readonly]
    end

    def active?
      true
    end

    def readonly?
      @readonly
    end

    def get(key, raw = false)
      cache_key = make_cache_key(key)
      if value = find(__method__, cache_key, :value, true)
        raw ? value : Marshal.load(value)
      end
    end

    def fetch(key, expiry = 0, raw = false, &block)
      value = get(key, raw)

      if value.nil? && block_given?
        value = yield
        add(key, value, expiry, raw)
      end

      value
    end

    def get_multi(*keys)
      cache_keys = keys.inject({}) do |cache_keys, key|
        cache_keys[make_cache_key(key)] = key
        cache_keys
      end
      rows = find_all(__method__, cache_keys.keys, [:key, :value], true)
      rows.inject({}) do |hash, (key, value)|
        hash[cache_keys[key]] = Marshal.load(value)
        hash
      end
    end

    def set(key, value, expiry = 0, raw = false)
      check_readonly!

      cache_key = make_cache_key(key)
      value     = value_to_storable(value, raw)

      unless update(__method__, cache_key, value, expiry)
        # rescue duplicate key error
        insert(__method__, cache_key, value, expiry) rescue nil
      end

      STORED unless @no_reply
    end

    def cas(key, expiry = 0, raw = false, &block)
      check_readonly!
      raise MemCacheError, 'A block is required' unless block_given?

      result = cas_with_reply(__method__, key, expiry, raw, &block)
      result unless @no_reply
    end

    def add(key, value, expiry = 0, raw = false)
      check_readonly!

      cache_key = make_cache_key(key)
      value     = value_to_storable(value, raw)

      old_value, old_expiry =
        find(__method__, cache_key, [:value, :expiry], false)

      if old_value && available?(old_expiry)
        NOT_STORED unless @no_reply

      else
        if old_value
          update(__method__, cache_key, value, expiry)
        else
          # rescue duplicate key error
          insert(__method__, cache_key, value, expiry) rescue nil
        end

        STORED unless @no_reply
      end
    end

    def replace(key, value, expiry = 0, raw = false)
      check_readonly!

      cache_key = make_cache_key(key)
      value     = value_to_storable(value, raw)

      if update(__method__, cache_key, value, expiry, true)
        STORED unless @no_reply
      else
        NOT_STORED unless @no_reply
      end
    end

    def append(key, value)
      append_or_prepend(__method__, key, value)
    end

    def prepend(key, value)
      append_or_prepend(__method__, key, value)
    end

    def incr(key, amount = 1)
      incr_or_decl(__method__, key, amount)
    end

    def decr(key, amount = 1)
      incr_or_decl(__method__, key, amount)
    end

    def delete(key)
      check_readonly!

      cache_key  = make_cache_key(key)
      conditions = { COLUMN_NAMES[:key] => cache_key }

      if @no_reply
        _delete(__method__, conditions)
        nil
      else
        exists = !!find(__method__, cache_key, :key, true)
        _delete(__method__, conditions)
        exists ? DELETED : NOT_FOUND
      end
    end

    def flush_all
      check_readonly!
      truncate(__method__)
    end

    alias_method :[], :get

    def []=(key, value)
      set(key, value)
    end

    def garbage_collection!
      _delete(__method__, ["#{quote_column_name(:expiry)} <= ?", now])
    end

    private
      def check_readonly!
        raise MemCacheError, 'Update of readonly cache' if @readonly
      end

      def make_cache_key(key)
        if @autofix_keys && (key =~ /\s/ ||
          (key.length + (namespace.nil? ? 0 : namespace.length)) > MAX_KEY_SIZE)
          key = "#{Digest::SHA1.hexdigest(key)}-autofixed"
        end

        key = namespace.nil? ?
          key :
          "#{namespace}#{@namespace_separator}#{key}"

        if key =~ /\s/
          raise ArgumentError, "illegal character in key #{key.inspect}"
        end
        if key.length > MAX_KEY_SIZE
          raise ArgumentError, "key too long #{key.inspect}"
        end

        key
      end

      def value_to_storable(value, raw)
        value = raw ? value.to_s : Marshal.dump(value)
        check_value_size!(value)
        value
      end

      def expiry_to_storable(expiry)
        expiry.zero? ?
          nil :
          expiry <= THIRTY_DAYS ?
            now + expiry :
            expiry
      end

      def check_value_size!(value)
        if @check_size && value.size > MAX_VALUE_SIZE
          raise MemCacheError,
            "Value too large, memcached can only store 1MB of data per key"
        end
      end

      def gets(_method_, key, raw)
        cache_key = make_cache_key(key)
        value, cas = find(_method_, cache_key, [:value, :cas], true)
        if cas
          [raw ? value : Marshal.load(value), cas]
        end
      end

      def cas_with_reply(_method_, key, expiry, raw, &block)
        value, cas = gets(_method_, key, raw)
        if cas
          cache_key = make_cache_key(key)
          value     = value_to_storable(yield(value), raw)

          update(_method_, cache_key, value, expiry, true, cas) ?
            STORED : EXISTS
        end
      end

      # TODO: check value size
      def append_or_prepend(_method_, key, value)
        check_readonly!

        cache_key = make_cache_key(key)
        value     = value.to_s

        old = quote_column_name(:value)
        new = quote_value(:value, value)
        pairs = {
          :value => concat_sql(*(_method_ == :append ? [old, new] : [new, old]))
        }

        affected_rows = @ar.connection.update(
          update_sql(cache_key, pairs, true, nil),
          sql_name(_method_)
        )

        affected_rows > 0 ? STORED : NOT_STORED unless @no_reply
      end

      def incr_or_decl(_method_, key, amount)
        check_readonly!

        unless /\A\s*\d+\s*\z/ =~ amount.to_s
          raise MemCacheError, 'invalid numeric delta argument'
        end
        amount = _method_ == :incr ? amount.to_i : - amount.to_i

        value = nil

        count = 0
        begin
          count += 1
          raise MemCacheError, "cannot #{_method_}" if count > 10

          result = cas_with_reply(_method_, key, nil, true) do |old_value|
            unless /\A\s*\d+\s*\z/ =~old_value
              raise MemCacheError,
                'cannot increment or decrement non-numeric value'
            end
            value = [old_value.to_i + amount, 0].max
          end
        end while result == EXISTS

        value unless @no_reply

      rescue MemCacheError
        raise unless @no_reply
      end

      def find(_method_, cache_key, column_keys, only_available)
        result = @ar.connection.send(
          column_keys.is_a?(Array) ? :select_one : :select_value,
          select_sql(
            cache_key,
            quote_column_name(*Array(column_keys)),
            only_available
          ),
          sql_name(_method_)
        )

        (result && column_keys.is_a?(Array)) ?
          column_keys.map {|k| result[COLUMN_NAMES[k]] } :
          result
      end

      def find_all(_method_, cache_keys, column_keys, only_available)
        return [] if cache_keys.empty?

        result = @ar.connection.send(
          column_keys.is_a?(Array) ? :select_all : :select_values,
          select_sql(
            cache_keys,
            quote_column_name(*Array(column_keys)),
            only_available
          ),
          sql_name(_method_)
        )

        column_keys.is_a?(Array) ?
          result.map {|r| column_keys.map {|k| r[COLUMN_NAMES[k]] }} :
          result
      end

      def insert(_method_, cache_key, value, expiry)
        attributes = attributes_for_update(value, expiry).merge(
          :key => cache_key,
          :cas => 0
        )

        column_keys = attributes.keys

        quoted_values = column_keys.map do |column_key|
          quote_value(column_key, attributes[column_key])
        end

        @ar.connection.execute(
          "INSERT INTO #{@ar.quoted_table_name}" +
          " (#{quote_column_name(*column_keys)})" +
          " VALUES(#{quoted_values.join(', ')})",
          sql_name(_method_)
        )
      end

      def update(_method_, cache_key, value, expiry, only_available = false, cas = nil)
        attributes = attributes_for_update(value, expiry)

        pairs = attributes.keys.inject({}) do |pairs, column_key|
          pairs[column_key] = quote_value(column_key, attributes[column_key])
          pairs
        end

        @ar.connection.update(
          update_sql(cache_key, pairs, only_available, cas),
          sql_name(_method_)
        ) > 0
      end

      def _delete(_method_, conditions)
        @ar.connection.execute(
          "DELETE FROM #{@ar.quoted_table_name}" +
          " WHERE #{@ar.send(:sanitize_sql, conditions)}",
          sql_name(_method_)
        )
      end

      def truncate(_method_)
        sql = case @ar.connection.adapter_name
          when 'SQLite'
            "DELETE FROM #{@ar.quoted_table_name}"
          else
            "TRUNCATE TABLE #{@ar.quoted_table_name}"
          end
        @ar.connection.execute(sql, sql_name(_method_))
      end

      def attributes_for_update(value, expiry)
        attributes = { :value => value }
        unless expiry.nil?
          attributes.update(:expiry => expiry_to_storable(expiry))
        end
        attributes
      end

      def select_sql(cache_key, select, only_available)
        conditions = build_conditions(cache_key, nil, only_available)

        "SELECT #{select}" +
        " FROM #{@ar.quoted_table_name}" +
        " WHERE #{@ar.send(:sanitize_sql, conditions)}"
      end

      def update_sql(cache_key, pairs, only_available, cas)
        pairs[:cas] = "#{quote_column_name(:cas)} + 1"
        pairs = pairs.map {|n, v| "#{quote_column_name(n)} = #{v}" }
        conditions = build_conditions(cache_key, cas, only_available)

        "UPDATE #{@ar.quoted_table_name}" +
        " SET #{pairs.join(', ')}" +
        " WHERE #{@ar.send(:sanitize_sql, conditions)}"
      end

      def build_conditions(cache_key, cas, only_available)
        conditions = [
          @ar.send(:attribute_condition, quote_column_name(:key), cache_key),
          cache_key
        ]

        if cas
          conditions.first << " AND #{quote_column_name(:cas)} = ?"
          conditions << cas
        end

        if only_available
          conditions.first << ' AND (' +
            "#{quote_column_name(:expiry)} IS NULL" +
            " OR #{quote_column_name(:expiry)} > ?" +
          ')'
          conditions << now
        end

        conditions
      end

      def concat_sql(a, b)
        case @ar.connection.adapter_name
        when 'MySQL'
          "CONCAT(#{a}, #{b})"
        else
          "#{a} || #{b}"
        end
      end

      def sql_name(_method_)
        "#{self.class.name}##{_method_}"
      end

      def now
        Time.now.to_i
      end

      def quote_column_name(*column_keys)
        column_keys.map do |column_key|
          @ar.connection.quote_column_name(
            column_key.is_a?(Symbol) ? COLUMN_NAMES[column_key] : column_key)
        end.join(', ')
      end

      def quote_value(column_key, value)
        @ar.connection.quote(value, @ar.columns_hash[COLUMN_NAMES[column_key]])
      end

      def available?(expiry)
        expiry.nil? || now < expiry.to_i
      end
  end

  unless const_defined?(:MemCacheError)
    class MemCacheError < RuntimeError; end
  end
end
