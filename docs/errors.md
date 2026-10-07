---
layout: default
title: Errors
description: >-
  Rescue a missing file the same way wherever it is stored, keeping the exception
  that the storage raised, and the other exceptions that IOStreams raises.
---

When a path's storage fails, for example because the file does not exist, the path raises the exception that its
storage raised, such as `Errno::ENOENT` for a local file or `Aws::S3::Errors::NoSuchKey` for S3. It tags that
exception with the kind of failure, such as `IOStreams::Errors::NotFound`.

Rescue the kind of failure, rather than the exception from one storage, so that the same code keeps working when the
path changes, for example from a local file in development to S3 in production. See
[Paths are configuration](config#paths-are-configuration).

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

## The exception tree

The kinds of failure are modules that tag the exception that the storage raised:

* `IOStreams::Errors::StorageError`: the storage of a path failed. Every kind of failure includes it.
  * `IOStreams::Errors::NotFound`: the file, a directory that it is in, or its S3 bucket, does not exist.

IOStreams raises these classes itself:

* `IOStreams::Errors::Error`, a `StandardError`:
  * `IOStreams::Errors::AccessDenied`: the path is not within the allowed paths, see
    [allowed paths](path#restricting-access-with-allowed-paths).
  * `IOStreams::Errors::CommunicationsFailure`: an SFTP or HTTP request failed. It is also tagged with the kind
    of failure when the failure is known, such as a `404 Not Found` response.
  * `IOStreams::Errors::UnknownFormat`: the tabular format cannot be inferred from the file name.
  * `IOStreams::Errors::MissingHeader`: the header columns are needed to write the header, but are not set.
  * `IOStreams::Errors::InvalidHeader`: the header has columns that are not allowed, or is missing required columns.
  * `IOStreams::Errors::TypeMismatch`: a row or record cannot be converted to the format.
  * `IOStreams::Errors::DelimiterNotFound`: no line delimiter was found within the maximum line length.
  * `IOStreams::Errors::InvalidLineLength`: a fixed width line does not have the length of its layout.
  * `IOStreams::Errors::ValueTooLong`: a value does not fit within its fixed width column.
  * `IOStreams::Errors::InvalidLayout`: the layout of a fixed width format is not valid.
* `IOStreams::Errors::MalformedDataError`, a `RuntimeError`: a quoted value is not closed. Its `#line_number`
  is the line that the value starts on.
* `IOStreams::Pgp::Failure`, a `StandardError`: gpg failed, for example to decrypt a file or to check its signature.

## What each storage raises

The exception that each storage raises, which is tagged with the kind of failure:

| Kind of failure | Local file | S3 | SFTP | HTTP |
|-----------------|------------|----|------|------|
| `NotFound` | `Errno::ENOENT`, or `Errno::ENOTDIR` below a file | `Aws::S3::Errors::NoSuchKey`, `NoSuchBucket`, `NoSuchVersion`, or `NotFound` from a HEAD request | `IOStreams::Errors::CommunicationsFailure` when reading or writing, or `Net::SFTP::StatusException` | `IOStreams::Errors::CommunicationsFailure` for `404 Not Found` or `410 Gone` |

SFTP reads and writes files with the `sftp` program, and uses the `net-sftp` gem for everything else, such as
`#each_child`, `#exist?` and `#delete`.

A failure that is not one of these kinds raises its exception without a tag.

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
  see `IOStreams::Path#display_name`.
* The message starts with the display name, unless it already includes it, so that a log of the exception names
  the file. For example the message from S3 does not name the key, while that of `Errno::ENOENT` already names the file.

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
storage, instead of raising:

~~~ruby
path.read if path.exist?
~~~

Log any failure of the storage, with the path that failed:

~~~ruby
begin
  IOStreams.join("exports", "daily.csv").write(report)
rescue IOStreams::Errors::StorageError => e
  logger.error("Export to #{e.display_name} failed", e)
  raise
end
~~~

## Notes

* Only the failure of a path's own request of its storage is tagged. An exception raised by the block that you
  supply, such as `Errno::ENOENT` when it reads a configuration file within `path.reader { ... }`, is not tagged,
  so it is not mistaken for a failure of the path.
* An exception keeps the tag and display name of the path that failed first. For example, when the block reading one
  path reads another path that does not exist, the display name is that of the other path.
* When copying within S3 with `convert: false`, a source that does not exist is tagged with the display name of
  the source.
* A frozen exception cannot be tagged. The tag is kept when the exception is marshaled, but not by `#dup`.

## Storage registered with `IOStreams.register_scheme`

A path class registered with `IOStreams.register_scheme` tags the failures of its storage the same way. Implement
the private method `#failure_kind`, which returns the kind of failure that an exception from the storage means, or
`nil`, and make each request of the storage within the private method `#tag_failure`:

~~~ruby
class MyStoragePath < IOStreams::Path
  def exist?
    tag_failure { MyStorage.exist?(path) }
  end

  private

  def failure_kind(exception)
    IOStreams::Errors::NotFound if exception.is_a?(MyStorage::NoSuchFile)
  end
end
~~~

Never call the block that the caller supplied within `#tag_failure`, since an exception that it raises is not a
failure of the path. To tag an exception directly, such as one that the path raises itself, call
`IOStreams::Errors::NotFound.tag(exception, display_name)`.
