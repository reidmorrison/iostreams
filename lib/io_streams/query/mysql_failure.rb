# frozen_string_literal: true

module IOStreams
  class Query
    # Returns the kind of failure, such as `IOStreams::Errors::Unavailable`, of an error of MySQL, whichever driver
    # raised it, which the failures of each driver ask with its number, see `IOStreams::Query::Mysql2Stream` and
    # `IOStreams::Query::TrilogyFailure`. The numbers are those of the MySQL server, such as ER_ACCESS_DENIED_ERROR,
    # 1045, and of its client library, such as CR_SERVER_LOST, 2013, which mysql2 raises.
    module MysqlFailure
      # The kind of failure of each error number of MySQL that is one: an access that MySQL denies, or a server that
      # could not be reached, lost the connection, or could not run the query at the time. A host that does not resolve,
      # CR_UNKNOWN_HOST, 2005, is none of them, as for a path, see `IOStreams::Errors::Unavailable.unknown_host?`.
      NUMBER_KINDS = {
        1044 => Errors::PermissionDenied, # ER_DBACCESS_DENIED_ERROR
        1045 => Errors::PermissionDenied, # ER_ACCESS_DENIED_ERROR
        1142 => Errors::PermissionDenied, # ER_TABLEACCESS_DENIED_ERROR
        1143 => Errors::PermissionDenied, # ER_COLUMNACCESS_DENIED_ERROR
        1227 => Errors::PermissionDenied, # ER_SPECIFIC_ACCESS_DENIED_ERROR
        1040 => Errors::Unavailable,      # ER_CON_COUNT_ERROR, too many connections
        1053 => Errors::Unavailable,      # ER_SERVER_SHUTDOWN
        1205 => Errors::Unavailable,      # ER_LOCK_WAIT_TIMEOUT
        1213 => Errors::Unavailable,      # ER_LOCK_DEADLOCK
        1317 => Errors::Unavailable,      # ER_QUERY_INTERRUPTED
        2002 => Errors::Unavailable,      # CR_CONNECTION_ERROR
        2003 => Errors::Unavailable,      # CR_CONN_HOST_ERROR
        2006 => Errors::Unavailable,      # CR_SERVER_GONE_ERROR
        2013 => Errors::Unavailable,      # CR_SERVER_LOST
        3024 => Errors::Unavailable       # ER_QUERY_TIMEOUT, of max_execution_time
      }.freeze

      # Returns [Module] the kind of failure of the error of MySQL of the supplied number, see NUMBER_KINDS, or nil when
      # it is none of them.
      def self.kind(number)
        NUMBER_KINDS[number]
      end
    end
  end
end
