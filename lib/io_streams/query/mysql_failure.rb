# frozen_string_literal: true

module IOStreams
  class Query
    # Returns the kind of failure, such as `IOStreams::Errors::Unavailable`, of an error of MySQL, whichever driver
    # raised it, which the failures of each driver ask with its number, or its message when the driver raised it
    # without one, see `IOStreams::Query::Mysql2Stream` and `IOStreams::Query::TrilogyFailure`. The numbers are those of
    # the MySQL server, such as ER_ACCESS_DENIED_ERROR, 1045, and of its client library, such as CR_SERVER_LOST, 2013,
    # which mysql2 raises.
    module MysqlFailure
      # The kind of failure of each error number of MySQL that is one: an access that MySQL denies, including an
      # account that it does not let connect, such as one that is locked, which a retry does not change, or a server
      # that could not be reached, lost the connection, or could not run the query at the time. A host that does not
      # resolve is not one of them, see UNKNOWN_HOST.
      NUMBER_KINDS = {
        1044 => Errors::PermissionDenied, # ER_DBACCESS_DENIED_ERROR
        1045 => Errors::PermissionDenied, # ER_ACCESS_DENIED_ERROR
        1130 => Errors::PermissionDenied, # ER_HOST_NOT_PRIVILEGED, a client host that no account allows
        1142 => Errors::PermissionDenied, # ER_TABLEACCESS_DENIED_ERROR
        1143 => Errors::PermissionDenied, # ER_COLUMNACCESS_DENIED_ERROR
        1227 => Errors::PermissionDenied, # ER_SPECIFIC_ACCESS_DENIED_ERROR
        1370 => Errors::PermissionDenied, # ER_PROCACCESS_DENIED_ERROR, a function that the user may not run
        1698 => Errors::PermissionDenied, # ER_ACCESS_DENIED_NO_PASSWORD_ERROR
        1820 => Errors::PermissionDenied, # ER_MUST_CHANGE_PASSWORD, an expired password, once connected
        1862 => Errors::PermissionDenied, # ER_MUST_CHANGE_PASSWORD_LOGIN, an expired password
        3118 => Errors::PermissionDenied, # ER_ACCOUNT_HAS_BEEN_LOCKED
        3955 => Errors::PermissionDenied, # ER_USER_ACCESS_DENIED_FOR_USER_ACCOUNT_BLOCKED_BY_PASSWORD_LOCK, failed logins
        1040 => Errors::Unavailable,      # ER_CON_COUNT_ERROR, too many connections
        1053 => Errors::Unavailable,      # ER_SERVER_SHUTDOWN
        1205 => Errors::Unavailable,      # ER_LOCK_WAIT_TIMEOUT
        1213 => Errors::Unavailable,      # ER_LOCK_DEADLOCK
        1317 => Errors::Unavailable,      # ER_QUERY_INTERRUPTED
        2002 => Errors::Unavailable,      # CR_CONNECTION_ERROR
        2003 => Errors::Unavailable,      # CR_CONN_HOST_ERROR
        2006 => Errors::Unavailable,      # CR_SERVER_GONE_ERROR
        2013 => Errors::Unavailable,      # CR_SERVER_LOST
        3024 => Errors::Unavailable,      # ER_QUERY_TIMEOUT, of max_execution_time
        4031 => Errors::Unavailable       # ER_CLIENT_INTERACTION_TIMEOUT, of wait_timeout
      }.freeze

      # The number of each error of NUMBER_KINDS that a driver can raise with its message alone, by the start of its
      # message: mysql2 raises every error that ends the rows of a streamed result without its number, such as for a
      # connection that is lost while they are read, as it raises errors of its own, such as "Invalid date in field",
      # which are none of them. The client library of Oracle says "MySQL server" where that of MariaDB, which Debian
      # installs as the MySQL client library, says "server", and the server says its messages in English, unless its
      # `lc_messages` says otherwise.
      MESSAGE_NUMBERS = {
        /\ALost connection to (?:MySQL )?server\b/                            => 2013, # CR_SERVER_LOST
        /\A(?:MySQL server|Server) has gone away\b/                           => 2006, # CR_SERVER_GONE_ERROR
        /\AQuery execution was interrupted, maximum statement execution time/ => 3024, # ER_QUERY_TIMEOUT
        /\AQuery execution was interrupted\b/                                 => 1317, # ER_QUERY_INTERRUPTED
        /\AServer shutdown in progress\b/                                     => 1053, # ER_SERVER_SHUTDOWN
        /\AThe client was disconnected by the server because of inactivity\b/ => 4031 # ER_CLIENT_INTERACTION_TIMEOUT
      }.freeze

      # The error number of the client library for a host that does not resolve, CR_UNKNOWN_HOST, which it raises for
      # every failure to resolve one, with the error of getaddrinfo at the end of its message, such as
      # "Unknown MySQL server host 'db.example.com' (-2)", see .unknown_host_kind.
      UNKNOWN_HOST = 2005

      # Returns [Module] the kind of failure of the error of MySQL of the supplied number, see NUMBER_KINDS, or of the
      # supplied message when the driver raised it without a number, see MESSAGE_NUMBERS, or nil when it is none of them,
      # or `IOStreams::Query::Failure::NONE` for a host that does not resolve, see .unknown_host_kind.
      def self.kind(number, message)
        number ||= MESSAGE_NUMBERS.find { |pattern, _number| pattern.match?(message) }&.last
        return unknown_host_kind(message) if number == UNKNOWN_HOST

        NUMBER_KINDS[number]
      end

      # Returns [Module] `Unavailable` for a temporary failure to resolve the host, `Socket::EAI_AGAIN`, which is how a
      # DNS outage, or a network without DNS, is reported, otherwise `IOStreams::Query::Failure::NONE`, for a host that
      # does not resolve, such as a mistyped host, so that the same request cannot succeed later, as for a path, see
      # `IOStreams::Errors::Unavailable.unknown_host?`.
      def self.unknown_host_kind(message)
        temporary = defined?(::Socket::EAI_AGAIN) && message.end_with?("(#{::Socket::EAI_AGAIN})")
        temporary ? Errors::Unavailable : Failure::NONE
      end
      private_class_method :unknown_host_kind
    end
  end
end
