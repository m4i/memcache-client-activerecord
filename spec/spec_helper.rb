$LOAD_PATH.unshift(File.dirname(__FILE__))
$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
require 'memcache-client-activerecord'
require 'spec'
require 'spec/autorun'

Spec::Runner.configure do |config|
  
end

class PGconn
  def self.quote_ident(name)
    %("#{name}")
  end
end
