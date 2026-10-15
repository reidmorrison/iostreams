---
layout: default
title: Errors
description: >-
  Rescue a missing file, a file that cannot be accessed, a server that cannot
  be reached, or a file whose data is corrupt, the same way wherever the file is
  stored and however it is compressed or encrypted, keeping the exception that
  was raised, and the other exceptions that IOStreams raises.
---

**Contents**

* TOC
{:toc}

When a path's storage fails, for example because the file does not exist, the path raises the exception that its
storage raised, such as `Errno::ENOENT` for a local file or `Aws::S3::Errors::NoSuchKey` for S3. It tags that
exception with the kind of failure: `IOStreams::Errors::NotFound`, `PermissionDenied` or `Unavailable`.

Likewise, when a stream cannot read the data of a file, for example because a file named `.gz` is not gzip data, or a
zip file does not contain the file to read, the stream raises the exception of its gem, such as
`Zlib::GzipFile::Error`, tagged with the kind of failure: `IOStreams::Errors::Corrupt`, `MissingEntry` or
`MissingKey`.

Rescue the kind of failure, rather than the exception from one storage or one gem, so that the same code keeps working
when the path changes, for example from a local file in development to S3 in production, or from `.gz` to `.zip`. See
[Paths are configuration](config#paths-are-configuration). It also keeps working when IOStreams replaces the gem that
reads a stream with a newer or better one, or reads it with another library on another platform, as JRuby reads zip
files with Java.

## Rescue the kind of failure

~~~ruby
path = IOStreams.path(ENV.fetch("IMPORT_PATH"))

begin
  path.each(:hash) { |record| Order.import(record) }
rescue IOStreams::Errors::NotFound => e
  logger.info("Nothing to import yet: #{e.display_name}")
end
~~~

The same rescue handles the missing file whether `IMPORT_PATH` is `~/imports/orders.csv`,
`sftp://sftp.example.org/~/orders.csv`, `s3://my-bucket/imports/orders.csv` or
`https://example.org/orders.csv`.

Rescuing the exception of one storage only works for that storage:

~~~ruby
# Avoid: misses a file that does not exist on S3, SFTP or HTTP.
rescue Errno::ENOENT

# Avoid: has to know every storage, and also rescues SFTP and HTTP failures that are not a missing file.
rescue Errno::ENOENT, Aws::S3::Errors::NoSuchKey, IOStreams::Errors::CommunicationsFailure
~~~

## Rescue a file that cannot be read, whatever its streams

~~~ruby
path = IOStreams.path(ENV.fetch("IMPORT_PATH"))

begin
  path.each(:hash) { |record| Order.import(record) }
rescue IOStreams::Errors::Corrupt => e
  logger.error("#{path.display_name} cannot be read, ask for it to be sent again", e)
end
~~~

The same rescue handles a file that is damaged, cut short, or not what its file name says at all, whether `IMPORT_PATH` is
`orders.csv.gz`, `orders.csv.bz2`, `orders.csv.zst`, `orders.zip`, `orders.csv.enc`, `orders.csv.pgp` or `orders.xlsx`.

Rescuing the exception of one gem only works for that stream:

~~~ruby
# Avoid: misses a corrupt file once the file name changes to .bz2 or .zip.
rescue Zlib::GzipFile::Error
~~~

A key that is missing, or a passphrase that is wrong, is a problem of the configuration rather than of the file, so it
raises `IOStreams::Errors::MissingKey` instead, which sending the file again will not fix:

~~~ruby
begin
  path.each(:hash) { |record| Order.import(record) }
rescue IOStreams::Errors::MissingKey => e
  raise(ConfigurationError, "Check the PGP keys and passphrase for #{e.display_name || path.display_name}")
end
~~~

## The exception tree

The kinds of failure are modules that tag the exception that the storage, or the gem of a stream, raised:

* `IOStreams::Errors::StorageError`: the storage of a path failed. Every kind of failure of the storage includes it.
  * `IOStreams::Errors::NotFound`: the file, a directory that it is in, or its S3 bucket, does not exist.
  * `IOStreams::Errors::PermissionDenied`: the storage does not permit the access, or the credentials for it are
    missing or not valid.
  * `IOStreams::Errors::Unavailable`: the storage could not be reached, or could not handle the request at the time,
    so that the same request can succeed when it is made again later.
* `IOStreams::Errors::StreamError`: a stream, such as gzip or zip, cannot read the data of the file. Every kind of
  failure of a stream includes it.
  * `IOStreams::Errors::Corrupt`: the data is not valid in the format of its stream: it is damaged, cut short, or
    not in that format at all, such as a text file named `.gz`, or it uses a part of the format that the stream does
    not support, such as a zip file encrypted with a password.
  * `IOStreams::Errors::MissingEntry`: the file does not contain the entry to read, such as a zip file without the
    file named by `entry_file_name`, or without any file at all.
  * `IOStreams::Errors::MissingKey`: a key that reading the data needs is missing, or cannot be used: the secret key
    that decrypts a PGP file is not in the keyring, or its passphrase is missing or wrong, the public key that checks
    its signature is not in the keyring, or the cipher of the version that encrypted an `.enc` file is not configured.

A failure of the storage is never a failure of a stream, so rescuing `NotFound` does not rescue a zip file without
the file to read, which reading again will not fix.

IOStreams raises these classes itself:

* `IOStreams::Errors::Error`, a `StandardError`:
  * `IOStreams::Errors::AccessDenied`: the path is not within the allowed paths, see
    [Allowed paths](security#allowed-paths). It is not a `PermissionDenied`, see below.
  * `IOStreams::Errors::CommunicationsFailure`: an SFTP or HTTP request failed. It is also tagged with the kind
    of failure when the failure is known, such as a `404 Not Found` response.
  * `IOStreams::Errors::StreamFailure`: a stream found that it cannot read the data, such as a zip file that does not
    contain the file to read, or a file within a zip file whose CRC32 is not the one that the zip file records. It is
    tagged with the kind of failure, `Corrupt` or `MissingEntry`.
  * `IOStreams::Errors::MissingHeader`: the columns are needed, but are not known: to write a header row when they
    are not set, or, with a schema, to read a row of a file with a header row before the header row is read.
  * `IOStreams::Errors::InvalidHeader`: the columns of a file do not match its [schema](formats#fieldsmatch): when
    reading, a header row, or the keys of a JSON record, has columns that `fieldsMatch` does not allow, or is missing
    a required field, or a row has values after its last column that the schema does not skip, and when writing, the
    keys of a record, or the columns or values of a row, that the schema does not skip.
  * `IOStreams::Errors::TypeMismatch`: a row or record cannot be converted to the format, such as, with a schema, a
    row written that is neither a Hash nor an Array, or a JSON line that is not an object.
  * `IOStreams::Errors::DelimiterNotFound`: no line delimiter was found within the maximum line length.
  * `IOStreams::Errors::InvalidValue`: a value is not of the type of its field in the schema, or a field that is
    required has no value, see [Schema](formats#schema).
  * `IOStreams::Errors::InvalidLineLength`: a fixed width line does not have the length of its schema.
  * `IOStreams::Errors::ValueTooLong`: a value does not fit within its fixed width field.
  * `IOStreams::Errors::InvalidLayout`: the layout of a fixed width file, set with the deprecated `#format_options`,
    is not valid. It is raised when the layout is set, see
    [Upgrading](upgrading#format_options-is-replaced-by-schema).
* `IOStreams::Errors::MalformedDataError`, a `RuntimeError`: a quoted value is not closed. Its `#line_number`
  is the line that the value starts on.
* `IOStreams::Errors::InvalidEncoding`, an `Encoding::UndefinedConversionError`: the data is not valid in the
  encoding that it is read or written in, such as UTF-8. Its `#byte_offset` is the offset of the first invalid byte
  within the data after any decompression or decryption, and its `#line_number` is the line that it is on, when it
  is read a line at a time, such as with `each(:line)` or `each(:hash)`, where the lines before it are read first.
  For example `"\xE9" is not valid UTF-8 at byte offset 1043 on line 12`. As an `Encoding::UndefinedConversionError`,
  its `#error_char` is the invalid bytes, and its `#source_encoding` and `#destination_encoding` the encodings that
  they were read and checked as.
* `IOStreams::Pgp::Failure`, a `StandardError`: gpg failed, for example to decrypt a file or to check its signature,
  or could not be run. When gpg reports why it could not read a file, it is tagged with the kind of failure, see
  [What each stream raises](#what-each-stream-raises).

## What each storage raises

The exception that each storage raises, which is tagged with the kind of failure:

| Kind of failure | Local file | S3 | SFTP | HTTP |
|-----------------|------------|----|------|------|
| `NotFound` | `Errno::ENOENT`, or `Errno::ENOTDIR` below a file | `Aws::S3::Errors::NoSuchKey`, `NoSuchBucket`, `NoSuchVersion`, or `NotFound` from a HEAD request | `IOStreams::Errors::CommunicationsFailure` when reading or writing, or `Net::SFTP::StatusException` | `IOStreams::Errors::CommunicationsFailure` for `404 Not Found` or `410 Gone` |
| `PermissionDenied` | `Errno::EACCES` or `Errno::EPERM` | `Aws::S3::Errors::AccessDenied`, `InvalidAccessKeyId`, `SignatureDoesNotMatch`, `ExpiredToken` and the like, `Forbidden` from a HEAD request, or `Aws::Errors::MissingCredentialsError` | `IOStreams::Errors::CommunicationsFailure` when reading or writing, `Net::SFTP::StatusException`, or `Net::SSH::AuthenticationFailed` | `IOStreams::Errors::CommunicationsFailure` for `401 Unauthorized`, `403 Forbidden` or `407 Proxy Authentication Required` |
| `Unavailable` | Never | `Seahorse::Client::NetworkingError` when S3 cannot be reached, or `Aws::S3::Errors::SlowDown`, `InternalError`, `ServiceUnavailable`, `RequestTimeout`, or a `429`, `500`, `502`, `503` or `504` response, once the AWS SDK has retried the request | `IOStreams::Errors::CommunicationsFailure` when reading or writing, a connection error such as `Errno::ECONNREFUSED` or `SocketError`, or `Net::SSH::Disconnect` | A connection error such as `Errno::ECONNREFUSED`, `SocketError` or `Net::ReadTimeout`, or `IOStreams::Errors::CommunicationsFailure` for `408`, `429`, `500`, `502`, `503` or `504` |

A host name that does not resolve, such as a mistyped host, is not `Unavailable`, see [Notes](#notes).

SFTP reads and writes files with the `sftp` program, and uses the `net-sftp` gem for everything else, such as
`#each_child`, `#exist?` and `#delete`.

A failure that is none of these kinds raises its exception without a tag, such as an SFTP host key that does not
match, or an HTTPS certificate that is not trusted.

## What each stream raises

The exception that each stream raises when it cannot read the data, which is tagged with the kind of failure:

| Stream | `Corrupt` | `MissingEntry` | `MissingKey` |
|--------|-----------|----------------|--------------|
| `.gz`, `.gzip` | `Zlib::GzipFile::Error`, such as its `Zlib::GzipFile::CRCError` or `NoFooter`, or `Zlib::DataError` | Never | Never |
| `.bz2` | `Bzip2::FFI::Error::DataError`, such as its `MagicDataError`, or `Bzip2::FFI::Error::UnexpectedEofError`, or `IOStreams::Errors::StreamFailure` for empty data | Never | Never |
| `.zst` | `RuntimeError` | Never | Never |
| `.zip` | `IOStreams::Errors::StreamFailure` for a file whose size or CRC32 is not the one that the zip file records. For a file that is not a zip file, or data that cannot be decompressed, `Zip::Error` from rubyzip on MRI, such as `Zip::DecompressionError`, or, from rubyzip 3.7, `NoMethodError`, `TypeError` or `ArgumentError` for a zip file whose end record is cut short, and `IOStreams::Errors::StreamFailure` on JRuby, which reads zip files with Java | `IOStreams::Errors::StreamFailure` | Never |
| `.enc` | `OpenSSL::Cipher::CipherError`, or the exceptions of `.gz` for compressed data, or `IOStreams::Errors::StreamFailure` for empty data | Never | `SymmetricEncryption::CipherError` for a version of the cipher that is not configured |
| `.xlsx`, `.xlsm` | `Zip::Error` from rubyzip, which reads the spreadsheet, or `Errno::ENOENT` for a zip file without the parts of a spreadsheet | Never | Never |
| `.pgp`, `.gpg` | `IOStreams::Pgp::Failure` for data that is not PGP data, is cut short, or was changed, such as integrity protection or a signature that does not match it, or for data without integrity protection, unless `ignore_mdc_error: true` is supplied | Never | `IOStreams::Pgp::Failure` for a secret key that is not in the keyring, a passphrase that is missing or wrong, or the public key of a signature that is not in the keyring |

The PGP stream tells why gpg failed from gpg's status, which does not depend on the locale. A PGP file that was not
signed by the `signer`, or that gpg does not trust, raises `IOStreams::Pgp::Failure` without a kind of failure, since
only PGP checks who signed a file.

Rescue the kind of failure rather than these exceptions: they belong to the gem of the stream, which a newer
version of IOStreams can replace with another, and the zip stream already raises different ones on MRI and JRuby.

## The exception is kept

The tag does not replace the exception, so its class and attributes stay the same, and code that rescues it by its
own class still works:

~~~ruby
begin
  IOStreams.path("s3://my-bucket/imports/orders.csv").read
rescue IOStreams::Errors::NotFound => e
  e.class        # => Aws::S3::Errors::NoSuchKey
  e.code         # => "NoSuchKey"
  e.display_name # => "s3://my-bucket/imports/orders.csv"
  e.message      # => "s3://my-bucket/imports/orders.csv: The specified key does not exist."
end
~~~

* `#display_name` is the path that failed, without any user name, password or query, which can hold credentials,
  see [Operations on the name](path#operations-on-the-name). For a failure of a stream, it is the file whose data the
  stream could not read, when the stream knows its name, as the zip and spreadsheet streams do. It is `nil` for the
  other streams, whose message is that of the gem, such as `not in gzip format`.
* The message starts with the display name, unless it already includes it, so that a log of the exception names
  the file. For example the message from S3 does not name the key, while that of `Errno::ENOENT` already names the file.

The same holds for the failure of a stream, which keeps the class that the gem raised, as in v2.1:

~~~ruby
begin
  IOStreams.path("orders.csv.gz").read
rescue IOStreams::Errors::Corrupt => e
  e.class   # => Zlib::GzipFile::Error
  e.message # => "not in gzip format"
end
~~~

## Examples

Skip a file that has not arrived yet, and process it on the next run:

~~~ruby
def import(path)
  path.each(:hash) { |record| Order.import(record) }
  path.delete
rescue IOStreams::Errors::NotFound
  logger.info("Waiting for #{path.display_name}")
end
~~~

Check that a file exists before reading it. `#exist?` returns `false` for a file that does not exist on every
storage, instead of raising. It still raises `PermissionDenied` when the storage does not permit the check:

~~~ruby
path.read if path.exist?
~~~

Likewise `#size` raises `NotFound` for a file that does not exist, like `File.size`, while `#size?` returns `nil`,
like `File.size?`:

~~~ruby
path.size  # raises IOStreams::Errors::NotFound when the file does not exist
path.size? # => nil when the file does not exist, or is empty
~~~

Report a problem with the credentials or permissions, which retrying will not fix:

~~~ruby
begin
  IOStreams.path(ENV.fetch("EXPORT_PATH")).write(report)
rescue IOStreams::Errors::PermissionDenied => e
  raise(ConfigurationError, "Check the credentials and permissions for #{e.display_name}")
end
~~~

The exception from the storage is the `#cause` of the `ConfigurationError`, so it is still logged with it.

Retry when the storage is unavailable, such as a server that is restarting:

~~~ruby
attempts = 0
begin
  IOStreams.path(ENV.fetch("EXPORT_PATH")).write(report)
rescue IOStreams::Errors::Unavailable => e
  attempts += 1
  raise if attempts >= 3

  logger.warn("Retrying in #{2**attempts} seconds: #{e.message}")
  sleep(2**attempts)
  retry
end
~~~

Writing again is safe: S3 and HTTP only store a file once it has been written completely, a local file that fails
part way is removed, and SFTP uploads the whole file again, replacing the part that an interrupted upload left on the
server. Retry only on `Unavailable`, and not on `NotFound` or `PermissionDenied`, which retrying will not fix, or on a
host name that does not resolve, which is not `Unavailable`.

Log any failure of the storage, with the path that failed:

~~~ruby
begin
  IOStreams.join("exports", "daily.csv").write(report)
rescue IOStreams::Errors::StorageError => e
  logger.error("Export to #{e.display_name} failed", e)
  raise
end
~~~

## AccessDenied is not a PermissionDenied

IOStreams raises `IOStreams::Errors::AccessDenied` itself, before it accesses the storage, when a path is not within
the allowed paths of the application, see [Allowed paths](security#allowed-paths).
`IOStreams::Errors::PermissionDenied` is a failure of the storage, such as a file that the credentials cannot read.

They are kept apart, so that rescuing `PermissionDenied`, for example to report a configuration problem, does not
also rescue an attempt to access a path that the application does not allow, such as a file name supplied by a user.

## Notes

* Only the failure of a path's own request of its storage is tagged. An exception raised by the block that you
  supply, such as `Errno::ENOENT` when it reads a configuration file within `path.reader { ... }`, is not tagged,
  so it is not mistaken for a failure of the path.
* An exception keeps the tag and display name of the path that failed first. For example, when the block reading one
  path reads another path that does not exist, the display name is that of the other path.
* On S3, a key that does not exist raises `PermissionDenied`, rather than `NotFound`, when the credentials do not
  have the `s3:ListBucket` permission for the bucket, since S3 then responds `403 Forbidden` instead of
  `404 Not Found`. Grant `s3:ListBucket` to tell a missing file apart from one that cannot be read.
* When copying within S3 with `convert: false`, a source that does not exist is tagged with the display name of
  the source, and any other failure with that of the target. When a local file cannot be moved because the target
  directory cannot be written to, the failure is tagged with the display name of the target.
* A local file is never `Unavailable`.
* The AWS SDK retries a request that S3 could not handle, or that could not reach it, before it raises `Unavailable`.
* A host name that does not resolve, such as a mistyped host, is not `Unavailable`, since the same request will fail
  again: a `Socket::ResolutionError`, or a `Seahorse::Client::NetworkingError` caused by one, is `Unavailable` only
  when its `error_code` is `Socket::EAI_AGAIN`, a temporary failure of name resolution, which is how Linux, with glibc
  or musl, reports a DNS server that cannot be reached, or a network without DNS. The `sftp` program's
  `ssh: Could not resolve hostname` is likewise `Unavailable` only for "Temporary failure in name resolution", or
  musl's "Try again". JRuby has no `Socket::ResolutionError`, so a `SocketError` there is always `Unavailable`. A host
  that resolves only on a private network, such as over a VPN, does not resolve while that network is down, so it is
  not `Unavailable` then either.
* Reading an HTTP path reads the response as the block reads it, so a connection that fails part way through raises
  from within the block, once some of the data has been processed. A connection that closes before the whole body
  has been received raises `IOStreams::Errors::CommunicationsFailure` tagged as `Unavailable`, as does a body that is
  shorter than its `Content-Length`. A failure raised by the block itself is not tagged.
* An HTTP response that cannot be decompressed, see [Reading a url](path#http-reading), raises
  `IOStreams::Errors::CommunicationsFailure` without a tag, since the whole response was received, so sending the
  request again returns the same response.
* A frozen exception cannot be tagged. The tag is kept when the exception is marshaled, but not by `#dup`.
* Likewise a stream tags only the exceptions of its gem. An exception raised by the block that
  you supply, such as a `Zlib::GzipFile::Error` from another gzip file that it reads, is not tagged.
* The failure of a stream that reads another stream keeps its tag. For example, data that cannot be decrypted within
  `orders.csv.gz.enc` raises the exception of `.enc`, which the gzip stream reading it does not tag again.
* A key for `.enc` that is not the one that the data was encrypted with also raises `Corrupt`, since the cipher
  cannot tell it apart from corrupt data, while a version of the cipher that is not configured raises `MissingKey`.
  For PGP, gpg tells them apart: a session key that does not decrypt with the key that it names is a damaged packet,
  which raises `Corrupt`.
* A stream can only report the corruption that it, or its gem, detects. A damaged frame of `.zst` data without the
  checksum of its content, which `.zst` written on MRI does not have, is not detected. rubyzip, which reads the parts of a spreadsheet, does not check their CRC32.

## Storage registered with `IOStreams.register_scheme`

A path class registered with `IOStreams.register_scheme` can tag the failures of its storage the same way, see
[Failures of the store](extending#failures-of-the-store).

## Formats registered with `IOStreams.register_extension`

A reader registered with `IOStreams.register_extension` can tag the failures of the library that reads its format the
same way, see [Failures of the format](extending#failures-of-the-format).
