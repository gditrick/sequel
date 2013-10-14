require 'uri'
require 'sqlanywhere'

Sequel.require %w'shared/sqlanywhere', 'adapters'

module Sequel
  # Module for holding all SqlAnywhere-related classes and modules for Sequel.
  module SqlAnywhere

    class SQLAnywhereException < StandardError
      attr_reader :errno
      attr_reader :sql

      def initialize(message, errno, sql)
        super(message)
        @errno = errno
        @sql = sql
      end
    end

    TYPE_TRANSLATOR = tt = Class.new do
      def blob(s) ::Sequel::SQL::Blob.new(s) unless s.nil? end
      def boolean(s) s.to_i != 0 unless s.nil? end
      def date(s) ::Date.strptime(s) unless s.nil? end
      def decimal(s) ::BigDecimal.new(s) unless s.nil? end
      def time(s) ::Sequel.string_to_time(s) unless s.nil? end
    end.new

    SQLANYWHERE_TYPES = {}
    {
        [0, 484] => tt.method(:decimal),
        [384] => tt.method(:date),
        [388] =>  tt.method(:time),
        [500] => tt.method(:boolean),
        [524, 528] => tt.method(:blob)
    }.each do |k,v|
      k.each{|n| SQLANYWHERE_TYPES[n] = v}
    end

    # Database class for SQLAnywhere databases used with Sequel.
    class Database < Sequel::Database
      include Sequel::SqlAnywhere::DatabaseMethods

      DEFAULT_CONFIG = { :user => 'dba', :password => 'sql' }

      attr_accessor :api

      set_adapter_scheme :sqlanywhere

      def connect(server)
        if opts[:uri].nil?
          connection_string = "ServerName=#{(opts[:server] || opts[:database])};DatabaseName=#{opts[:database]};UserID=#{opts[:user]};Password=#{opts[:password]};"
          connection_string += "CommLinks=#{opts[:commlinks]};" unless opts[:commlinks].nil?
          connection_string += "ConnectionName=#{opts[:connection_name]};" unless opts[:connection_name].nil?
          connection_string += "CharSet=#{opts[:encoding]};" unless opts[:encoding].nil?
          connection_string += "Idle=0" # Prevent the server from disconnecting us if we're idle for >240mins (by default)
        else
          uri = URI(opts[:uri])
          connection_string = (uri.path.nil? or uri.path == "") ? "" : "DBN=#{File.basename(uri.path)};"
          connection_string += uri.query
        end

        conn = @api.sqlany_new_connection

        ret = @api.sqlany_connect(conn, connection_string)
        if ret != 1
          raise LoadError, "Could not connect" if conn.nil?
        end

        if Sequel.application_timezone == :utc
          @api.sqlany_execute_immediate(conn, "SET TEMPORARY OPTION time_zone_adjustment=0")
        end

        conn
      end

      # Closes given database connection.
      def disconnect_connection(c)
        @api.sqlany_disconnect(c)
      end

      # Returns number of rows affected
      def execute_dui(sql, opts={})
        synchronize do |conn|
          begin
            rs = log_yield(sql){ @api.sqlany_execute_direct(conn, sql)}
            if rs.nil?
              result, errstr = @api.sqlany_error(conn)
              raise_error(SQLAnywhereException.new(errstr, result, sql))
            end
            affected_rows = @api.sqlany_affected_rows(rs)
            @api.sqlany_commit(conn) unless in_transaction?
            affected_rows
          ensure
            @api.sqlany_free_stmt(rs) unless rs.nil?
          end
        end
      end

      def execute(sql, opts={})
        synchronize do |conn|
          begin
            rs = log_yield(sql){ @api.sqlany_execute_direct(conn, sql)}
            if rs.nil?
              result, errstr = @api.sqlany_error(conn)
              raise_error(SQLAnywhereException.new(errstr, result, sql))
            end
            yield rs if block_given?
            @api.sqlany_commit(conn) unless in_transaction?
          ensure
            @api.sqlany_free_stmt(rs) unless rs.nil?
          end
        end
      end

      def execute_insert(sql, opts={})
        execute(sql, opts)
        last_insert_id(opts)
      end

      private

      def adapter_initialize
        @conversion_procs = SQLANYWHERE_TYPES.dup
        @conversion_procs[392] = method(:to_application_timestamp_sa)
        @api = SQLAnywhere::SQLAnywhereInterface.new
        raise LoadError, "Could not load SQLAnywhere DBCAPI library" if SQLAnywhere::API.sqlany_initialize_interface(@api) == 0
        raise LoadError, "Could not initialize SQLAnywhere DBCAPI library" if @api.sqlany_init == 0
      end

      def log_connection_execute(conn, sql)
        log_yield(sql){ execute(sql)}
      end

      def last_insert_id(opts={})
        sql = 'SELECT @@IDENTITY'
        id = nil
        execute(sql) do |rs|
          if @api.sqlany_fetch_next(rs) == 1
            id = @api.sqlany_get_column(rs, 0)[1]
          end unless rs.nil?
        end
        id
      end

    end

    # Dataset class for SqlAnywhere datasets accessed via the native driver.
    class Dataset < Sequel::Dataset
      include Sequel::SqlAnywhere::DatasetMethods

      Database::DatasetClass = self

      # Yield all rows matching this dataset.  If the dataset is set to
      # split multiple statements, yield arrays of hashes one per statement
      # instead of yielding results for all statements as hashes.
      def fetch_rows(sql)
        db = @db
        cps = db.conversion_procs
        execute(sql) do |rs|
          max_cols = db.api.sqlany_num_cols(rs)
          col_map = {}
          columns = []
          max_cols.times do |cols|
            col = db.api.sqlany_get_column_info(rs, cols)[2]
            columns << col_map[col] = output_identifier(col)
          end

          @columns  = columns
          convert = (convert_smallint_to_bool and db.convert_smallint_to_bool)

          while db.api.sqlany_fetch_next(rs) == 1
            max_cols = db.api.sqlany_num_cols(rs)
            h2 = {}
            max_cols.times do |cols|
              h2[col_map[db.api.sqlany_get_column_info(rs, cols)[2]]||db.api.sqlany_get_column_info(rs, cols)[2]] =
                cps[db.api.sqlany_get_column_info(rs, cols)[4]].nil? ?
                    db.api.sqlany_get_column(rs, cols)[1] :
                      db.api.sqlany_get_column_info(rs, cols)[4] != 500 ?
                        cps[db.api.sqlany_get_column_info(rs, cols)[4]].call(db.api.sqlany_get_column(rs, cols)[1]) :
                          convert ? cps[db.api.sqlany_get_column_info(rs, cols)[4]].call(db.api.sqlany_get_column(rs, cols)[1]) :
                            db.api.sqlany_get_column(rs, cols)[1]
            end
            yield h2
          end unless rs.nil?
        end
        self
      end
    end
  end
end
