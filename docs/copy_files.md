---
layout: default
title: Copying and Moving Files
description: >-
  Copying and moving files between storage locations with copy_from, copy_to and
  move_to, converting their compression, encryption and format on the way.
---

`#copy_from` copies a file into the path, and `#copy_to` copies the path into another file. Both read the source a
block at a time while they write the target, so a file of any size can be copied, and both apply the streams of each
file name, so a copy can also convert the file:

* from one storage location to another, such as from SFTP to S3;
* from one compression or encryption to another, such as from `.gz` to `.pgp`;
* from one tabular format to another, such as from CSV to JSON or Parquet.

## Copying a file

Decompress `example.csv.gz` into `example.csv`:

~~~ruby
IOStreams.path("example.csv").copy_from("example.csv.gz")
~~~

The source can be a file name, a path, or an IO. Encrypt a file with PGP so that only `receiver@example.org` can
read it:

~~~ruby
target = IOStreams.path("example.csv.pgp").option(:pgp, recipient: "receiver@example.org")
target.copy_from(IOStreams.path("example.csv"))
~~~

Copy a file from SFTP to S3, decrypting it on the way:

~~~ruby
source = IOStreams.path("sftp://sftp.example.org/outbound/orders.csv.pgp").option(:pgp, passphrase: ENV.fetch("PGP_PASSPHRASE"))
source.copy_to("s3://my-bucket/imports/orders.csv")
~~~

When a file name has no extensions to say how it is stored, set its streams with `#stream`. Here `CUSTOMER_DATA` was
encrypted with Symmetric Encryption, and is encrypted for `receiver@example.org` with PGP instead:

~~~ruby
input = IOStreams.path("CUSTOMER_DATA").stream(:enc)
IOStreams.path("xyz.csv.pgp").option(:pgp, recipient: "receiver@example.org").copy_from(input)
~~~

A copy without a mode returns the number of bytes copied, as written to the target before its streams.

## Copying as stored

`convert: false` copies the data as it is stored, without applying the streams of either file name, such as to
download a zip file without unzipping it:

~~~ruby
IOStreams.path("downloads/sample.json.zip").copy_from("https://example.com/files/sample.json.zip", convert: false)
~~~

A copy as stored takes no other options, so any other option raises `ArgumentError`. A copy between two S3 paths with
`convert: false` asks S3 to copy the object itself, without reading it, for an object smaller than 5GB.

## Converting rows and records

With a mode, a copy reads the source, and writes the target, a line, a row or a record at a time, so that it converts
the tabular format too. Copy a CSV file into JSON, parsing and rendering each record:

~~~ruby
IOStreams.path("target_file.json").copy_from("source_file.csv", mode: :hash)
~~~

The mode is one of:

* `:line`, which copies each line;
* `:array`, which copies each row, after the header row of the source, which gives the target the columns of its
  rows;
* `:hash`, which copies each record, so that the target writes the value of each key in its column.

Use `:hash` to copy between formats whose records are keyed, such as JSON and Parquet, and those with a header row,
such as CSV. A blank line of the source is skipped.

## Choosing the columns

The other options of a copy are used to write the target, and the source is read with the settings of its own path,
so describe each file on its own path: its format, encoding and [schema](formats#schema). To choose the columns that
are written, and their order, set a schema on the target, whose fields are the columns written:

~~~ruby
target = IOStreams.path("people.json").schema(fieldsMatch: "subset", fields: [{name: "name"}, {name: "age"}])
target.copy_from("people.csv", mode: :hash)
~~~

`fieldsMatch: "subset"` skips the other columns of the source. A CSV file without a header row is described by a
schema with `header: false` on its path, whose fields are its columns, in order:

~~~ruby
source = IOStreams.path("people.csv").schema(header: false, fields: [{name: "name"}, {name: "age", type: "integer"}])
IOStreams.path("people.json").copy_from(source, mode: :hash)
~~~

An option that only applies when reading, such as `buffer_size:`, raises `ArgumentError` for a copy, rather than being
ignored, see [Settings on the path, options for each call](streams#settings-on-the-path-options-for-each-call).

## Moving a file

`#move_to` copies the file as it is stored, see `convert: false` above, and then deletes it, so the file keeps its
name's format, compression and encryption, and returns the target path:

~~~ruby
IOStreams.path("uploads/orders.csv.pgp").move_to("s3://my-bucket/archive/orders.csv.pgp")
~~~

It creates the directories of the target first, and moving onto the same file raises `ArgumentError`, rather than
deleting it. A move within S3 copies the object within S3, and a move between local files renames the file.

## When a copy fails

* The source is opened before the target, so a source that does not exist, or cannot be read, raises before the target
  is changed. A missing source raises `IOStreams::Errors::NotFound`, wherever it is stored, see [Errors](errors).
* When the copy fails part way, the target is not left with part of the file: a local file is removed, an S3 upload
  is aborted, and an SFTP or HTTP file is not uploaded. An existing target is only replaced once the copy completes on
  S3 and HTTP.
* A move only deletes the source once the copy completed.

## Copying a directory

`#each_child` lists the files of a directory, and `#relative_path_from` names each one relative to the directory, to
copy them into another store:

~~~ruby
source = IOStreams.path("/var/exports")
target = IOStreams.path("s3://my-bucket/exports")

source.each_child("**/*") do |file|
  target.join(file.relative_path_from(source)).copy_from(file, convert: false)
end
~~~
