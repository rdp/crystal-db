require "http/params"
require "weak_ref"

module DB
  # Acts as an entry point for database access.
  # Connections are managed by a pool.
  # The connection pool can be configured from URI parameters:
  #
  #   - initial_pool_size (default 1)
  #   - max_pool_size (default 1)
  #   - max_idle_pool_size (default 1)
  #   - checkout_timeout (default 5.0)
  #   - retry_attempts (default 1)
  #   - retry_delay (in seconds, default 1.0)
  #
  # It should be created from DB module. See `DB#open`.
  #
  # Refer to `QueryMethods` for documentation about querying the database.
  class Database
    # :nodoc:
    getter driver
    # :nodoc:
    getter pool

    # Returns the uri with the connection settings to the database
    getter uri

    @pool : Pool(Connection)
    @setup_connection : Connection -> Nil
    @statements_cache = StringKeyCache(PoolStatement).new

    # :nodoc:
    def initialize(@driver : Driver, @uri : URI)
      params = HTTP::Params.parse(uri.query || "")
      pool_options = @driver.connection_pool_options(params)

      @setup_connection = ->(conn : Connection) {}
      @pool = uninitialized Pool(Connection) # in order to use self in the factory proc
      @pool = Pool.new(**pool_options) {
        conn = @driver.build_connection(self).as(Connection)
        @setup_connection.call conn
        conn
      }
    end

    def setup_connection(&proc : Connection -> Nil)
      @setup_connection = proc
      @pool.each_resource do |conn|
        @setup_connection.call conn
      end
    end

    # Closes all connection to the database.
    def close
      @statements_cache.each_value &.close
      @statements_cache.clear

      @pool.close
    end

    # :nodoc:
    def prepare(query)
      @statements_cache.fetch(query) { PoolStatement.new(self, query) }
    end

    # :nodoc:
    def checkout_some(candidates : Enumerable(WeakRef(Connection))) : {Connection, Bool}
      @pool.checkout_some candidates
    end

    # :nodoc:
    def return_to_pool(connection)
      @pool.release connection
    end

    # yields a connection from the pool
    # the connection is returned to the pool after
    # when the block ends
    def using_connection
      connection = @pool.checkout
      begin
        yield connection
      ensure
        return_to_pool connection
      end
    end

    # :nodoc:
    def retry
      @pool.retry do
        yield
      end
    end

    include QueryMethods
  end
end
