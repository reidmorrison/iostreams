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
    # see `IOStreams::Query::JdbcRows`. Connector/J gives a statement the `defaultFetchSize` of its connection, so the
    # read sets it on the connection of the read, which is one of its own, while the statement starts, see #stream,
    # unless the configuration of the connection sets the `jdbc_fetch_size` of AR-JDBC, which AR-JDBC gives every
    # statement in its place, see #check_fetch_size. The statement runs in a transaction of its own, since AR-JDBC runs
    # a statement again after a failure that Connector/J deems transient, such as a deadlock, which would yield every
    # row again, unless the connection has a transaction open. When the block that the rows are yielded to is left
    # early, the connection is aborted, which ends the query at once, see #discard, since Connector/J reads the rest of
    # a streamed result to close it.
    #
    # Connector/J sets the `net_write_timeout` of the session itself while it streams a result, to its
    # `netTimeoutForStreamingResults`, 600 seconds by default, and afterwards to the value that the session had when it
    # connected, rather than the one that the `variables` of the configuration of the connection set, see
    # https://github.com/jruby/activerecord-jdbc-adapter/issues/1236, so the read turns that off while it streams, and
    # raises the limits of the session itself, as `IOStreams::Query::Mysql2Stream` does.
    class MysqlJdbc < Mysql2Stream
      # The fetch size of a statement that makes Connector/J stream its rows, `Integer.MIN_VALUE` of Java, see
      # https://dev.mysql.com/doc/connector-j/en/connector-j-reference-implementation-notes.html.
      STREAM_FETCH_SIZE = -(2**31)

      # The SQLSTATE of Connector/J for a connection that could not be made, or was lost, as it starts a statement.
      COMMUNICATIONS_LINK_FAILURE = "08S01"
      private_constant :COMMUNICATIONS_LINK_FAILURE

      # Returns [true|false] whether the connection is to MySQL through the MySQL adapter of AR-JDBC, see
      # `IOStreams::Query::Jdbc.adapter?`, which is named "Mysql2", as the adapter of the mysql2 gem is.
      def self.reads?(connection)
        connection.adapter_name == "Mysql2" && Jdbc.adapter?(connection)
      end

      # Returns [Module] the kind of failure that an exception of Connector/J means, or nil when it is none of them, or
      # another driver raised it: as the exceptions of Java that caused it say, see `IOStreams::Query::Jdbc.cause_kind`,
      # such as a connection that could not be made, or was lost while the rows were read, otherwise as MySQL says of
      # the number of its error, see `IOStreams::Query::MysqlFailure`, which Connector/J raises with the number of the
      # server, and otherwise `Unavailable` for COMMUNICATIONS_LINK_FAILURE, which Connector/J raises without a number.
      def self.failure_kind(exception)
        failure = Jdbc.driver_exception(exception, "com.mysql.")
        return unless failure

        Jdbc.cause_kind(failure) || sql_failure_kind(failure)
      end

      # Returns [Module] the kind of failure of a `java.sql.SQLException` of Connector/J, see .failure_kind, or nil for
      # any other exception of it.
      def self.sql_failure_kind(failure)
        return unless failure.is_a?(::Java::JavaSql::SQLException)

        kind = MysqlFailure.kind(failure.error_code.nonzero?, failure.message.to_s)
        kind || (Errors::Unavailable if failure.sql_state == COMMUNICATIONS_LINK_FAILURE)
      end
      private_class_method :sql_failure_kind

      # Yields [Array] each row of the result, its raw values as AR-JDBC returns them, from the row after the last one
      # that it yielded, so that a second traversal continues where the first stopped, as the lines of a file do.
      def each(&)
        return each_read(&) if @rows

        @reader.each(&)
      end

      private

      # Yields itself once the statement streams its result on the raw connection, see `Mysql2Stream#open`, in a
      # transaction of its own, its first row read, and the number of its values checked against the columns that the
      # query was described by, see `IOStreams::Query::JdbcRows#start`, with the limits of the session raised while the
      # rows are read, see `Mysql2Stream#raise_limits`, and set back afterwards, once the transaction is committed, see
      # #set_back. The connection is ended instead, see #discard, when the block is left before every row was read, with
      # `break` or an exception, such as a `Timeout`.
      #
      # Raises ArgumentError, before anything is changed, for a connection whose statements Connector/J cannot stream,
      # see #check_fetch_size and #property.
      def stream(statement, columns)
        raw = @connection.raw_connection
        check_fetch_size
        hold(property(raw, :netTimeoutForStreamingResults), 0) do
          raw.begin
          raise_limits
          @reader = JdbcRows.new(raw)
          hold(property(raw, :defaultFetchSize), STREAM_FETCH_SIZE) { @reader.start(statement, columns) }
          yield self
        ensure
          if @reader&.reading?
            discard
          else
            @reader&.close
            set_back
          end
        end
      end

      # Raises ArgumentError when the configuration of the connection sets the `jdbc_fetch_size` of AR-JDBC, which
      # AR-JDBC gives every statement, in place of the `defaultFetchSize` of Connector/J that makes it stream, see
      # #stream, so that a query is never read whole without a word, suggesting batches.
      def check_fetch_size
        fetch_size = @connection.pool.db_config.configuration_hash[:jdbc_fetch_size]
        return if fetch_size.nil? || Integer(fetch_size).zero?

        raise(ArgumentError, "IOStreams cannot stream a query on MySQL with AR-JDBC on a connection whose " \
                             "jdbc_fetch_size is set, since AR-JDBC then reads every row of it first, so #{IN_BATCHES}")
      end

      # Yields with the supplied property of Connector/J set to the supplied value, see #property, and sets it back
      # afterwards. The `netTimeoutForStreamingResults` at 0 has Connector/J set the `net_write_timeout` of the session
      # neither while it streams the result, nor once it has, which #raise_limits and #set_back do instead, and the
      # `defaultFetchSize` at STREAM_FETCH_SIZE has it stream the statement that the block starts.
      def hold(property, value)
        previous = property.getValue
        property.setValue(value.to_java(::Java::JavaLang::Integer))
        begin
          yield
        ensure
          property.setValue(previous.to_java(::Java::JavaLang::Integer))
        end
      end

      # Returns [com.mysql.cj.conf.RuntimeProperty] the property of the supplied name of the connection of Connector/J of
      # the supplied raw connection of AR-JDBC, which Connector/J lets an application change once it is connected.
      #
      # Raises ArgumentError for a connection whose driver is not Connector/J, such as MariaDB Connector/J, which the
      # MySQL adapter of AR-JDBC can connect with, so that a query is never read whole without a word, suggesting
      # batches.
      def property(raw, name)
        connection = raw.connection.unwrap(::Java::ComMysqlCjJdbc::JdbcConnection.java_class)
        connection.getPropertySet.getIntegerProperty(::Java::ComMysqlCjConf::PropertyKey.public_send(name))
      rescue NameError, ::Java::JavaSql::SQLException
        raise(ArgumentError, "IOStreams streams a query on MySQL with the driver Connector/J, not " \
                             "#{raw.connection.java_class.name}, so #{IN_BATCHES}")
      end

      # Commits the transaction of the read, see #stream, and then sets back the limits of the session, see
      # `Mysql2Stream#set_back`. When the transaction cannot be committed, such as on a connection that was lost, or it
      # is interrupted, such as by a Timeout, the connection is ended instead, so that the pool never keeps a session
      # with a transaction open, and a read whose every row was read does not fail for it.
      def set_back
        committed = false
        begin
          @connection.raw_connection.commit
          committed = true
        ensure
          @connection.disconnect! unless committed
        end
        super
      rescue StandardError
        nil
      end

      # Ends the session of the connection of the read, which is one of its own, by aborting the connection of
      # Connector/J, which closes its socket, rather than read the rest of the result, as closing the statement would,
      # so that the server ends the query, before the statement is closed. Connector/J aborts a connection with the
      # supplied executor, a block that runs each task that it is given, so that the abort runs here and now, rather than
      # on another thread, where it could wait for one to be free while the statement is closed. A read of the driver
      # that already waits for the server, such as for the first row of a slow query, continues until the server
      # answers, which closing the statement waits for. The session needs no limit set back, nor transaction ended, and
      # Active Record reconnects the connection when it is next checked out. Closing the statement on a connection that
      # was aborted can raise, which is not a failure of the read.
      def discard
        @connection.raw_connection.connection.abort(&:run)
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
