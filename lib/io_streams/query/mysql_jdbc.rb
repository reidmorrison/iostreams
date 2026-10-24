# frozen_string_literal: true

module IOStreams
  class Query
    # Reads the rows of a query on MySQL one at a time with the MySQL adapter of AR-JDBC, on JRuby, which cannot load the
    # mysql2 gem, a C extension, that `IOStreams::Query::Mysql2Stream` reads with, whose answers about MySQL it shares,
    # such as the limits of the session that it raises while the rows are read, and the whole read of a connection that
    # the read shares with the caller.
    #
    # Its driver, Connector/J, reads every row of a result before the first, unless the fetch size of the statement is
    # STREAM_FETCH_SIZE, when it streams the rows from the server, and AR-JDBC yields each row as the driver reads it,
    # see `IOStreams::Query::JdbcRows`. AR-JDBC gives every statement of a connection the fetch size of its
    # configuration, `jdbc_fetch_size`, so the read sets it on the raw connection of the read, which is one of its own,
    # while the statement starts, see #with_stream_fetch_size. When the block that the rows are yielded to is left
    # early, the connection is aborted, which ends the query at once, see #discard, since Connector/J reads the rest of
    # a streamed result to close it.
    #
    # Connector/J sets the `net_write_timeout` of the session itself while it streams a result, to its
    # `netTimeoutForStreamingResults`, 600 seconds by default, and afterwards to the value that the session had when it
    # connected, rather than the one that the `variables` of the configuration of the connection set, so the read turns
    # that off while it streams, see #without_driver_timeout, and raises the limits of the session itself, as
    # `IOStreams::Query::Mysql2Stream` does.
    class MysqlJdbc < Mysql2Stream
      # The fetch size of a statement that makes Connector/J stream its rows, `Integer.MIN_VALUE` of Java, see
      # https://dev.mysql.com/doc/connector-j/en/connector-j-reference-implementation-notes.html.
      STREAM_FETCH_SIZE = -(2**31)

      # The field of the raw connection of AR-JDBC that holds the fetch size of its statements, see
      # #with_stream_fetch_size.
      FETCH_SIZE = "fetchSize"
      private_constant :FETCH_SIZE

      # The SQLSTATE of Connector/J for a connection that could not be made, or was lost, as it starts a statement.
      COMMUNICATIONS_LINK_FAILURE = "08S01"
      private_constant :COMMUNICATIONS_LINK_FAILURE

      # Returns [true|false] whether the connection is to MySQL through the MySQL adapter of AR-JDBC, see
      # `IOStreams::Query::Jdbc.adapter?`, which is named "Mysql2", as the adapter of the mysql2 gem is.
      def self.reads?(connection)
        connection.adapter_name == "Mysql2" && Jdbc.adapter?(connection)
      end

      # Returns [Module] the kind of failure that an exception of Connector/J means, or nil when it is none of them, or
      # another driver raised it: as for a host that does not resolve, see `IOStreams::Query::Jdbc`, otherwise as
      # MySQL says of the number of its error, see `IOStreams::Query::MysqlFailure`, which Connector/J raises with the
      # number of the server, and otherwise `Unavailable` for a connection that could not be made, or was lost, which
      # Connector/J raises without a number: with COMMUNICATIONS_LINK_FAILURE as a statement starts, and with a failure
      # of input or output as its cause once the rows are read.
      def self.failure_kind(exception)
        sql_exception = Jdbc.sql_exception(exception, "com.mysql.")
        return unless sql_exception

        kind = Jdbc.unknown_host_kind(sql_exception) ||
               MysqlFailure.kind(sql_exception.error_code.nonzero?, sql_exception.message.to_s)
        return kind if kind

        lost = sql_exception.sql_state == COMMUNICATIONS_LINK_FAILURE || Jdbc.io_failure?(sql_exception)
        Errors::Unavailable if lost
      end

      # Yields [Array] each row of the result, its raw values as AR-JDBC returns them, from the row after the last one
      # that it yielded, so that a second traversal continues where the first stopped, as the lines of a file do.
      def each(&)
        return each_read(&) if @rows

        @reader.each(&)
      end

      private

      # Yields itself once the statement streams its result on the raw connection, see `Mysql2Stream#open`, its first
      # row read, and the number of its values checked against the columns that the query was described by, see
      # `IOStreams::Query::Columns#check_width`, with the limits of the session raised while the rows are read, see
      # `Mysql2Stream#raise_limits`, and set back afterwards. The connection is ended instead, see #discard, when the
      # block is left before every row was read, with `break` or an exception.
      def stream(statement, columns)
        raw = @connection.raw_connection
        without_driver_timeout(raw) do
          raise_limits
          @reader = JdbcRows.new(raw)
          with_stream_fetch_size(raw) { statement.instrument { |sql, _values| @reader.start(sql, statement.binds) } }
          columns.check_width(@reader.width) if @reader.width
          yield self
        ensure
          @reader&.reading? ? discard : set_back
        end
      end

      # Yields with the `netTimeoutForStreamingResults` of Connector/J, of the raw connection of the read, set to 0, so
      # that it sets the `net_write_timeout` of the session neither while it streams the result, nor once it has, which
      # #raise_limits and #set_back do instead, and sets it back afterwards.
      #
      # Raises ArgumentError, before anything is changed, for a connection whose driver is not Connector/J, such as
      # MariaDB Connector/J, which the MySQL adapter of AR-JDBC can connect with, so that a query is never read whole
      # without a word, suggesting batches.
      def without_driver_timeout(raw)
        timeout  = driver_timeout(raw)
        previous = timeout.getValue
        timeout.setValue(0.to_java(::Java::JavaLang::Integer))
        begin
          yield
        ensure
          timeout.setValue(previous.to_java(::Java::JavaLang::Integer))
        end
      end

      # Returns [com.mysql.cj.conf.RuntimeProperty] the `netTimeoutForStreamingResults` of the connection of Connector/J
      # of the supplied raw connection of AR-JDBC, see #without_driver_timeout.
      def driver_timeout(raw)
        connection = raw.connection.unwrap(::Java::ComMysqlCjJdbc::JdbcConnection.java_class)
        connection.getPropertySet.getIntegerProperty(::Java::ComMysqlCjConf::PropertyKey.netTimeoutForStreamingResults)
      rescue NameError, ::Java::JavaSql::SQLException
        raise(ArgumentError, "IOStreams streams a query on MySQL with the driver Connector/J, not " \
                             "#{raw.connection.java_class.name}, so #{IN_BATCHES}")
      end

      # Yields with the fetch size of the statements of the raw connection of the read set to STREAM_FETCH_SIZE, so that
      # the statement that the block starts streams its rows, and sets it back afterwards, since AR-JDBC has no way to
      # set the fetch size of one statement.
      #
      # Raises ArgumentError, before the statement starts, when the raw connection has no such field, as for a version
      # of AR-JDBC that renamed it, so that a query is never read whole without a word, suggesting batches.
      def with_stream_fetch_size(raw)
        raw      = raw.to_java
        field    = fetch_size_field(raw)
        previous = field.getInt(raw)
        field.setInt(raw, STREAM_FETCH_SIZE)
        begin
          yield
        ensure
          field.setInt(raw, previous)
        end
      end

      # Returns [java.lang.reflect.Field] the field of the supplied raw connection of AR-JDBC that holds the fetch size
      # of its statements, FETCH_SIZE, which a class above that of the connection of MySQL declares, made accessible.
      def fetch_size_field(raw)
        klass = raw.getClass
        klass = klass.getSuperclass until klass.nil? || klass.getDeclaredFields.any? { |field| field.getName == FETCH_SIZE }
        unless klass
          raise(ArgumentError, "IOStreams cannot stream a query on MySQL with this version of AR-JDBC, whose " \
                               "connections have no #{FETCH_SIZE}, so #{IN_BATCHES}")
        end

        field = klass.getDeclaredField(FETCH_SIZE)
        field.setAccessible(true)
        field
      end

      # Ends the session of the connection of the read, which is one of its own, by aborting the connection of
      # Connector/J, which closes its socket at once, rather than read the rest of the result, as closing the statement
      # would, so that the server ends the query, before the statement is closed. The session needs no limit set back,
      # and Active Record reconnects the connection when it is next checked out. Closing the statement on a connection
      # that was aborted can raise, which is not a failure of the read.
      def discard
        @connection.raw_connection.connection.abort(::Java::JavaUtilConcurrent::ForkJoinPool.commonPool)
      ensure
        begin
          @reader.close
        rescue StandardError
          nil
        ensure
          @connection.disconnect!
        end
      end
    end
  end
end
