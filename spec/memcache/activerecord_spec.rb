require File.expand_path(File.dirname(__FILE__) + '/../spec_helper')

require 'erb'
require 'yaml'
require 'rubygems'
gem 'memcache-client'; require 'memcache'
gem 'activerecord'; require 'active_record'


### start memcached

MEMCACHED_HOST   = 'localhost'
MEMCACHED_PORT   = '31121'
MEMCACHED_SERVER = "#{MEMCACHED_HOST}:#{MEMCACHED_PORT}"

if MEMCACHED_HOST == 'localhost'
  memcached_pid = fork do
    exec 'memcached', '-p', MEMCACHED_PORT
  end

  END {
    Process.kill(:SIGINT, memcached_pid)
  }

  sleep 1
end


### initializing

ROOT_DIR      = File.dirname(__FILE__) + '/../..'
DATABASE_YAML = ROOT_DIR + '/spec/database.yml'
MIGRATION     = ROOT_DIR + '/generators/cache_model/templates/migration.rb'
TABLE_NAME    = 'caches'

ActiveRecord::Base.configurations = YAML.load_file(DATABASE_YAML)
ActiveRecord::Base.logger = Logger.new($stdout) if ENV['LOG']

migration_name = 'CreateCaches'
table_name     = TABLE_NAME
eval(ERB.new(File.read(MIGRATION)).result(binding))

def new_cache_class(adapter)
  cache_class = Class.new(ActiveRecord::Base)
  Object.const_set('Cache' + rand.to_s[2..-1], cache_class)
  cache_class.set_table_name(TABLE_NAME)
  cache_class.establish_connection(adapter)
  cache_class
end

def new_dbcache(adapter, options)
  MemCache::ActiveRecord.new(new_cache_class(adapter), options)
end

class Caches
  def initialize(memcache, dbcache)
    @memcache = memcache
    @dbcache  = dbcache
  end

  def same(*args, &block)
    convert = args.first.is_a?(Symbol) ? lambda {|m| m } : args.shift

    begin
      memcache_result = @memcache.send(*args, &block)
    rescue Exception => memcache_error
    end

    if memcache_error
      begin
        dbcache_result = @dbcache.send(*args, &block)
      rescue Exception => dbcache_error
      end

      dbcache_error.class.should   == memcache_error.class
      dbcache_error.message.should == memcache_error.message

    else
      dbcache_result = @dbcache.send(*args, &block)
      dbcache_result.should == convert.call(memcache_result)
    end

    dbcache_result
  end

  private
    def method_missing(name, *args)
      if @dbcache.respond_to?(name)
        @dbcache.send(name, *args)
        @memcache.send(name, *args)
      else
        super
      end
    end
end


### specs

mem_flusher = MemCache.new(MEMCACHED_SERVER)
mem_flusher.flush_all

ActiveRecord::Base.configurations.each_key do |adapter|
  ActiveRecord::Base.establish_connection(adapter)
  CreateCaches.down rescue nil
  CreateCaches.up
  ActiveRecord::Base.clear_all_connections!
  ActiveRecord::Base.remove_connection

  cache_class = new_cache_class(adapter)

  db_flusher = MemCache::ActiveRecord.new(cache_class)
  db_flusher.flush_all

  flushers = Caches.new(mem_flusher, db_flusher)

describe "#{adapter}:" do
  after do
    flushers.flush_all
  end

  [
    {},
    { :namespace => 'ns' },
    { :no_reply  => true },
  ].each do |options|
    memcache = MemCache.new(MEMCACHED_SERVER, options)
    dbcache  = MemCache::ActiveRecord.new(cache_class, options)
    caches   = Caches.new(memcache, dbcache)

    describe MemCache::ActiveRecord, " when options are #{options.inspect}" do
      if options.empty?
        it 'should be case-sensitive' do
          caches.same(:set, 'foo', 1)
          caches.same(:set, 'FOO', 2)

          caches.same(:get, 'foo').should == 1
          caches.same(:get, 'FOO').should == 2
        end

        it 'should support a number of seconds starting from current time' do
          [
            1,
            MemCache::ActiveRecord::THIRTY_DAYS,
          ].each do |expiry|
            dbcache.set('foo', 1, expiry)
            cache_class.find_by_key('foo').expiry.should ==
              Time.now.to_i + expiry
          end
        end

        it 'should support an unix time expiry' do
          [
            MemCache::ActiveRecord::THIRTY_DAYS + 1,
            Time.now.to_i,
          ].each do |expiry|
            dbcache.set('foo', 1, expiry)
            cache_class.find_by_key('foo').expiry.should == expiry
          end
        end

        unless ENV['LOG']
          it 'should behave like MemCache with over 64KB value' do
            value = 'a' * (2 ** 16 + 1)
            caches.same(:set, 'foo', value, 0, true)
            caches.same(:get, 'foo', true).should == value
          end

          it 'should behave like MemCache with over 1MB value' do
            value = 'a' * (2 ** 20 + 1)
            caches.same(:set, 'foo', value, 0, true)
            caches.same(:get, 'foo', true).should be_nil
          end
        end

        unless ENV['WITHOUT_SLEEP']
          it 'should be able to collect garbage' do
            dbcache.set('foo', 1)
            dbcache.set('bar', 1, 1)
            dbcache.set('baz', 1, 2)

            cache_class.count.should == 3

            sleep 1
            dbcache.garbage_collection!

            cache_class.count.should == 2
          end
        end
      end

      describe '#get' do
        it 'should behave like MemCache#get' do
          caches.same(:get, 'foo')
        end

        if options.empty?
          unless ENV['WITHOUT_SLEEP']
            it 'should behave like MemCache#get with expiry' do
              3.times do |expiry|
                if expiry > 0
                  caches.same(:delete, 'foo')
                end

                caches.same(:set, 'foo', 1, expiry)

                3.times do |i|
                  sleep 1 if i > 0
                  caches.same(:get, 'foo')
                end
              end
            end
          end
        end
      end

      describe '#fetch' do
        it 'should behave like MemCache#fetch' do
          caches.same(:fetch, 'foo') { 1 }.should == 1
          caches.same(:fetch, 'foo') { 2 }.should == 1
          caches.same(:fetch, 'foo')      .should == 1
        end
      end

      describe '#get_multi' do
        it 'should behave like MemCache#get_multi' do
          caches.same(:get_multi, 'foo', 'bar', 'baz')

          caches.same(:set, 'foo', 1)
          caches.same(:set, 'bar', nil)

          caches.same(:get_multi, 'foo', 'bar', 'baz')
        end
      end

      describe '#set' do
        it 'should behave like MemCache#set' do
          caches.same(:set, 'foo', 1)
          caches.same(:get, 'foo').should == 1

          caches.same(:set, 'foo', 2)
          caches.same(:get, 'foo').should == 2
        end

        it 'should work in multithread' do
          thread = Thread.new do
            dbcache2 = new_dbcache(adapter, options)
            def dbcache2.insert(*args)
              sleep 0.2
              super
            end
            dbcache2.set('foo', 2)
          end

          sleep 0.1
          dbcache.set('foo', 1)

          thread.join

          dbcache.get('foo').should == 1
        end

        if options.empty?
          it 'should behave like MemCache#set with negative expiry' do
            caches.same(:set, 'foo', 1, -1)
            caches.same(:get, 'foo').should be_nil
          end
        end
      end

      describe '#cas' do
        it 'should behave like MemCache#cas' do
          caches.same(:cas, 'foo') {|v| v + 1 }
          caches.same(:get, 'foo').should be_nil

          caches.same(:set, 'foo', 1)
          caches.same(:cas, 'foo') {|v| v + 1 }
          caches.same(:get, 'foo').should == 2
        end

        it 'should behave like MemCache#cas without block' do
          caches.same(:cas, 'foo')
        end

        it 'should work in multithread' do
          dbcache.set('foo', 0)

          thread = Thread.new do
            dbcache2 = new_dbcache(adapter, options)
            dbcache2.cas('foo') {|v| sleep 0.2; v + 1 }.should(
              options[:no_reply] ? be_nil : eql(MemCache::ActiveRecord::EXISTS))
          end

          sleep 0.1
          dbcache.set('foo', 2)

          thread.join

          dbcache.get('foo').should == 2
        end
      end

      describe '#add' do
        it 'should behave like MemCache#add' do
          caches.same(:add, 'foo', 1)
          caches.same(:get, 'foo').should == 1

          caches.same(:add, 'foo', 2)
          caches.same(:get, 'foo').should == 1
        end
      end

      describe '#replace' do
        it 'should behave like MemCache#replace' do
          caches.same(:replace, 'foo', 1)
          caches.same(:get, 'foo').should be_nil

          caches.same(:set, 'foo', 1)
          caches.same(:replace, 'foo', 2)
          caches.same(:get, 'foo').should == 2
        end

        it 'should work in multithread' do
          dbcache.set('foo', 0)

          thread = Thread.new do
            dbcache2 = new_dbcache(adapter, options)
            def dbcache2.update(*args)
              sleep 0.2
              super
            end
            dbcache2.replace('foo', 2)
          end

          sleep 0.1
          dbcache.delete('foo')

          thread.join

          dbcache.get('foo').should be_nil
        end

        if options.empty?
          unless ENV['WITHOUT_SLEEP']
            it 'should behave like MemCache#replace with expiry' do
              caches.same(:set, 'foo', 1, 1)
              sleep 2
              caches.same(:replace, 'foo', 2)
              caches.same(:get, 'foo').should be_nil
            end
          end
        end
      end

      describe '#append' do
        it 'should behave like MemCache#append' do
          caches.same(:append, 'foo', 1)
          caches.same(:get, 'foo', true).should be_nil

          caches.same(:set, 'foo', 0, 0, true)
          caches.same(:append, 'foo', 1)
          caches.same(:get, 'foo', true).should == '01'
        end
      end

      describe '#prepend' do
        it 'should behave like MemCache#prepend' do
          caches.same(:prepend, 'foo', 1)
          caches.same(:get, 'foo', true).should be_nil

          caches.same(:set, 'foo', 0, 0, true)
          caches.same(:prepend, 'foo', 1)
          caches.same(:get, 'foo', true).should == '10'
        end
      end

      describe '#incr' do
        it 'should behave like MemCache#incr' do
          caches.same(:incr, 'foo').should be_nil
          caches.same(:get, 'foo', true).should be_nil

          caches.same(:set, 'foo', 1, 0, true)
          caches.same(:incr, 'foo').should(options[:no_reply] ? be_nil : eql(2))
          caches.same(:get, 'foo', true).should == '2'

          caches.same(:incr, 'foo', 0).should(options[:no_reply] ? be_nil : eql(2))
          caches.same(:get, 'foo', true).should == '2'

          caches.same(:incr, 'foo', 2).should(options[:no_reply] ? be_nil : eql(4))
          caches.same(:get, 'foo', true).should == '4'
        end

        it 'should work in multithread' do
          dbcache.set('foo', 1, 0, true)

          thread = Thread.new do
            dbcache2 = new_dbcache(adapter, options)
            5.times { dbcache2.incr('foo') }
          end

          5.times { dbcache.incr('foo') }

          thread.join

          dbcache.get('foo', true).should == '11'
        end

        if options.empty?
          it 'should behave like MemCache#incr with string amount' do
            caches.same(:set, 'foo', ' 1 ', 0, true)
            caches.same(:incr, 'foo', '1')
            caches.same(lambda {|m| m.sub(/  \z/, '') }, :get, 'foo', true)

            caches.same(:incr, 'foo', '1 ')
            caches.same(lambda {|m| m.sub(/  \z/, '') }, :get, 'foo', true)

            caches.same(:incr, 'foo', ' 1')
            caches.same(lambda {|m| m.sub(/  \z/, '') }, :get, 'foo', true)

            caches.same(:incr, 'foo', ' 1 ')
            caches.same(lambda {|m| m.sub(/  \z/, '') }, :get, 'foo', true)
          end

          it 'should behave like MemCache#incr with non-raw value' do
            caches.same(:set, 'foo', 1)
            caches.same(:incr, 'foo')
          end

          it 'should behave like MemCache#incr with non-numeric value' do
            [1.5, -1, 'qux'].each do |value|
              caches.same(:set, 'foo', value, 0, true)
              caches.same(:incr, 'foo')
            end
          end

          it 'should behave like MemCache#incr with invalid numeric delta argument' do
            caches.same(:set, 'foo', 1, 0, true)
            [1.5, -1, 'qux'].each do |amount|
              caches.same(:incr, 'foo', amount)
            end
          end

          unless ENV['WITHOUT_SLEEP']
            it 'should behave like MemCache#incr with expiry' do
              caches.same(:set, 'foo', 1, 1, true)
              caches.same(:incr, 'foo')
              sleep 2
              caches.same(:get, 'foo', true)

              caches.same(:set, 'foo', 1, 1, true)
              sleep 2
              caches.same(:incr, 'foo')
              caches.same(:get, 'foo', true)
            end
          end
        end
      end

      describe '#decr' do
        it 'should behave like MemCache#decr' do
          caches.same(:decr, 'foo')
          caches.same(:get, 'foo', true)

          caches.same(:set, 'foo', 9, 0, true)
          caches.same(:decr, 'foo')
          caches.same(:get, 'foo', true)

          caches.same(:decr, 'foo', 0)
          caches.same(:get, 'foo', true)

          caches.same(:decr, 'foo', 2)
          caches.same(:get, 'foo', true)
        end

        if options.empty?
          it 'should behave like MemCache#decr (1 - 2 => 0)' do
            caches.same(:set, 'foo', 1, 0, true)
            caches.same(:decr, 'foo', 2)
            caches.same(:get, 'foo', true)
          end

          it 'should behave like MemCache#decr with decrement digit' do
            caches.same(:set, 'foo', 10, 0, true)
            caches.same(:decr, 'foo')
            caches.same(lambda {|m| m.sub(/ \z/, '') }, :get, 'foo', true)
          end

          it 'should behave like MemCache#decr with non-raw value' do
            caches.same(:set, 'foo', 1)
            caches.same(:decr, 'foo')
          end

          it 'should behave like MemCache#decr with non-numeric value' do
            [1.5, -1, 'qux'].each do |value|
              caches.same(:set, 'foo', value, 0, true)
              caches.same(:decr, 'foo')
            end
          end

          it 'should behave like MemCache#decr with invalid numeric delta argument' do
            caches.same(:set, 'foo', 1, 0, true)

            [1.5, -1, 'qux'].each do |amount|
              caches.same(:decr, 'foo', amount)
            end
          end
        end
      end

      describe '#delete' do
        it 'should behave like MemCache#delete' do
          caches.same(:set, 'foo', 1)
          caches.same(:get, 'foo')

          caches.same(:delete, 'foo')
          caches.same(:get, 'foo')
        end
      end

      if options.empty?
        describe '#flush_all' do
          it 'should behave like MemCache#delete' do
            caches.same(:set, 'foo', 1)
            caches.same(:get, 'foo')

            # don't use same, because MemCache#flush_all returns @servers.
            caches.flush_all

            caches.same(:get, 'foo')
          end
        end
      end
    end
  end

  [
    {},
    { :namespace => 'n' },
  ].each do |options|
    options.update(:autofix_keys => true)

    memcache = MemCache.new(MEMCACHED_SERVER, options)
    dbcache  = MemCache::ActiveRecord.new(cache_class, options)
    caches   = Caches.new(memcache, dbcache)

    describe MemCache::ActiveRecord, " when options are #{options.inspect}" do
      it 'should behave like MemCache' do
        (248..251).each do |length|
          caches.same(:set, 'a' * length, length)
          caches.same(:get, 'a' * length)
        end
      end
    end
  end

  [
    { :readonly => true },
  ].each do |options|
    memcache = MemCache.new(MEMCACHED_SERVER, options)
    dbcache  = MemCache::ActiveRecord.new(cache_class, options)
    caches   = Caches.new(memcache, dbcache)

    describe MemCache::ActiveRecord, " when options are #{options.inspect}" do
      it 'should behave like MemCache' do
        caches.same(:set, 'foo', 1)
      end
    end
  end

end
end
