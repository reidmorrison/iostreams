---
layout: default
title: Upgrading
heading: Upgrading IOStreams
description: >-
  What changes when upgrading IOStreams to v2.2, v2.1 or v2.0, how to prepare
  for v3.0, and the security settings to review in your application when upgrading.
---

This page covers the changes that may need updates to your application when upgrading IOStreams,
and the security issues to check. For every change in each release, see the
[CHANGELOG](https://github.com/reidmorrison/iostreams/blob/main/CHANGELOG.md).

## Upgrading to v2.2

v2.2 prepares applications for v3.0, and changes no existing behavior, apart from its deprecation warnings and the
[changes in behavior](#changes-in-behavior) below. It adds the methods that replace those that v3.0 deprecates or
removes, and reports a deprecation warning when the application uses one of those, so that it can move to the
replacement while it still runs v2.2, and then upgrade to v3.0 with fewer changes:

* `#raw` reads and writes the data as it is stored, in place of `stream(:none)`, see [Raw](streams#raw).
* `#encoding` sets the encoding of the text, in place of `option(:encode, ...)` and `stream(:encode, ...)`, see
  [Character encoding](extensions#character-encoding).
* `#schema` describes the rows and records of a file, as v3.0 does: the type of each field, the columns that the file
  must and can have, and the position of each field of a fixed width file, in place of `#format_options` and the
  column options of each call, see [Schema](formats#schema). A schema in v2.2 reads and writes as one in v3.0 does,
  apart from the differences that v3.0 makes to every file, such as its encoding, see
  [Schemas in IOStreams 2.2 and 3.0](formats#schemas-in-iostreams-22-and-30).
* `IOStreams.tabular_formats` returns the formats that `#format` accepts.

What is deprecated still works as before. Apart from the [changes in behavior](#changes-in-behavior) below, the only
change to existing behavior is the deprecation warnings themselves, which Ruby shows only while `Warning[:deprecated]` is on: it is off by default, so production stays
quiet, but Minitest and test-unit turn it on, so most test runs show them on `$stderr`, including for the calls
that another gem makes, such as Rocket Job 7.0, see [Seeing deprecation warnings](#seeing-deprecation-warnings).

To prepare for v3.0: upgrade to v2.2, run your tests, which show the deprecation warnings, see below, and move each
use to what replaces it. Then read the changes that v3.0 makes in its own
[upgrading guide](https://github.com/reidmorrison/iostreams/blob/main/docs/upgrading.md#upgrading-to-v30), since it
also changes behavior that cannot be reported as a deprecation, such as reading text as UTF-8 by default.

### Seeing deprecation warnings

IOStreams reports the use of a deprecated method or option as a Ruby deprecation warning, the same way that Ruby
reports its own, which names the line of your application that used it, and what to use instead:

~~~
app/jobs/export_job.rb:12: warning: IOStreams: stream(:none) is deprecated, use #raw to read or write the data as it is stored, or #file_name to read a file that is not named for its format
~~~

Ruby only shows deprecation warnings while `Warning[:deprecated]` is true, which it is not by default, so production
stays quiet without any configuration:

| Where | Deprecation warnings |
|-------|----------------------|
| Tests run with Minitest or test-unit | On, since both turn them on |
| Tests run with RSpec | Off, unless run with `rspec --warnings`, or `Warning[:deprecated] = true` is set in `spec_helper.rb` |
| Development | Off, unless `RUBYOPT=-W:deprecated` is set in the environment, or `Warning[:deprecated] = true` in code that only runs in development, such as `config/environments/development.rb` |
| Production | Off |

Rails settings such as `config.active_support.deprecation` only apply to the deprecation warnings of Rails, not to
those that Ruby reports.

Ruby writes each warning to `$stderr`. To send them elsewhere, such as to your log, or to raise them in your tests so
that each use is found, extend `Warning` with your own `warn`:

~~~ruby
module IOStreamsDeprecations
  def warn(message, *, **)
    return super unless message.include?("IOStreams: ")

    Rails.logger.warn(message.chomp)
  end
end
Warning.extend(IOStreamsDeprecations)
~~~

### Deprecated, and what replaces it

Each of these still works as before in v2.2, and reports a deprecation warning:

| Deprecated | Use instead |
|------------|-------------|
| `stream(:none)` | `#raw` to read or write the data as it is stored, or `#file_name` to read a file that is not named for its format, such as `file_name("data.csv")` for a CSV file named `data.txt` |
| `option(:encode, ...)` and `option_or_stream(:encode, ...)` | `#encoding`, with the same options and the same results, see [Character encoding](extensions#character-encoding) |
| `stream(:encode, ...)` | `#encoding`, with the same options. Like any stream set with `#stream`, `stream(:encode, ...)` stops the streams being taken from the file name, while `#encoding` keeps them, so `IOStreams.path("data.csv.gz").encoding("BINARY")` reads the decompressed data. To read or write the data as it is stored, as `stream(:encode, encoding: "BINARY")` does for such a file name, use `#raw`, and to read a file that is not named for its format, set the file name that names its format with `#file_name`, then `#encoding` |
| `embedded_within:` with `each(:array)` or `each(:hash)` | `#format`, since the format of the file decides where the lines of its rows and records are split, such as `format(:psv)` for values that are not quoted |
| `#format_options`, and `format_options:` supplied to each call | `#schema`, which gives the `width` of each field of a fixed width file, see [Moving a layout to a schema](#moving-a-layout-to-a-schema) |
| `columns:`, `allowed_columns:`, `required_columns:` and `skip_unknown:`, unless they are nil, and `cleanse_header:`, even when it is nil | `#schema`, which describes the columns of the file on its path, see [Moving the column options to a schema](#moving-the-column-options-to-a-schema) |

`IOStreams.enforce_column_restrictions=` is not deprecated in v2.2, which still follows it, so keep setting it to
true as [v2.1 recommends](#column-restrictions-on-uploaded-files) until the column options are replaced with a
schema, to which it does not apply.

v3.0 removes these, or raises `ArgumentError` for them, so in v2.2 each still works as before, and reports a
deprecation warning:

| Deprecated | Use instead |
|------------|-------------|
| `format:`, `file_name:`, `original_file_name:` or `default_format:` supplied to `#each`, `#reader`, `#writer` or a copy, such as `each(:hash, format: :json)`, even when they are nil | `#format`, which sets the format on the path, so that every reader and writer of the path uses it: `format(:json).each(:hash)`. A file name supplied to a call only chooses the format, when the path has none, and not the streams, as `#file_name` does, so set the format that it names instead, such as `format(:json)` for `file_name: "data.json"`. `default_format:` only applies when the path has no format, so set it only then: `path.format(:json) unless path.format` |
| `allowed_columns:`, `required_columns:` or `skip_unknown:` supplied to `#writer` or a copy, which ignores them, even when they are nil | A schema, which describes the columns that are written, such as with `fieldsMatch: "subset"` to skip the other keys of each record |
| Options supplied to `#writer` when the stream is a line, row or record writer that is already open, such as the one that `writer(:line)` yields, handed to `IOStreams.stream`, which writes with its own settings, and ignores them | Set them where that writer is opened, or remove them |
| Options supplied to the `:stream` mode, the default of `#reader` and `#writer`, to a copy without a `mode:`, or to a copy with `convert: false`, including `mode:` | Remove them, since they are ignored |
| The Zip writer's `zip_file_name`, even when it is nil | `entry_file_name` |
| An option of `.bz2` that neither reading nor writing takes, which BZip2 ignores | Remove it |
| A file name ending in `.encode` | `#encoding`, which applies the encode stream whatever the file name, so the file need not be renamed |
| `#path=` | `#join` or `#directory`, which return a new path without the streams, options, format and schema set on the path, which `#path=` keeps, so set them again, or `IOStreams.path` with the new name |
| `#builder=` | `IOStreams.path`, to start again without the streams and options set with `#stream` or `#option` |

### Moving a layout to a schema

`#format_options` is deprecated. It still works, and still reads and writes the file with its layout, as before, so
no change is needed yet. A schema gives the type of each field of every format, and can be held in a JSON file, see
[Schema](formats#schema). Each column of a layout is a field of the schema:

| Layout | Schema |
|--------|--------|
| `key:` | `name` |
| `size:` | `width` |
| `size: :remainder` | `width: "remainder"` |
| A column without a `key:`, a filler | `start` on the field after it, or the `width` of the schema at the end of the line |
| `type: :string` | `type: "string"`, with `truncate: true` unless the layout has `truncate: false` |
| `type: :integer` | `type: "integer"` |
| `type: :float` and `decimals:` | `type: "number"`, with `floatNumber: true` and `decimals:`, without `decimals` for a column with `size: :remainder`, which writes the digits that the value has |
| A record written with keys that the layout does not have, which are skipped | `fieldsMatch: "subset"` |

~~~ruby
# Before (deprecated)
path.format(:fixed).format_options(
  layout: [
    {size: 23, key: "name"},
    {size: 2},
    {size: 5, key: "zip", type: :integer}
  ]
)

# After
path.format(:fixed).schema(
  fieldsMatch: "subset",
  fields:      [
    {name: "name", type: "string",  width: 23, truncate: true},
    {name: "zip",  type: "integer", width: 5,  start: 26}
  ]
)
~~~

`IOStreams::Schema.from_layout` returns the schema of a layout as a Hash, to set with `#schema` or to save as a JSON
file, such as `IOStreams::Schema.from_layout(layout: layout)`, with `truncate: false` too when the layout has it. The
columns of the layout can have String keys, such as a layout read from JSON. A column after the column with
`size: :remainder` is left out, since the layout never reads it. It is only for moving off a layout: v3.0 removes it,
with `#format_options`, so keep the schema that it returns rather than call it each time.

The keys of the records read are the names of the fields, so a layout with Symbol keys, such as `key: :name`, reads
Symbol keys, as does a schema whose field is named with that Symbol. A schema saved as a JSON file, or in a database
such as MongoDB, names its fields with Strings, so when every key of the layout is a Symbol, `from_layout` adds
`keyType: "symbol"`, which keeps the keys of its records Symbols, see
[Keys of the records read](formats#keys-of-the-records-read). Without `fieldsMatch: "subset"`, a schema has
`"exact"`, so that writing a record with a key that is not a field raises `IOStreams::Errors::InvalidHeader`, rather
than skip it as a layout does. A schema and a layout cannot both be set on a path: reading or writing it raises
`ArgumentError`.

The schema reads and writes the file as v3.0 does, which is not always as the layout does, so check that it reads
the files of the application before it replaces the layout. What reads differently:

* The `width` of each field counts the characters of the line, which is read as UTF-8, while the layout counts its
  bytes. So a line with a character that is not ASCII, such as `é`, raises `IOStreams::Errors::InvalidLineLength`
  when the program that wrote it counted bytes, and text that is not valid UTF-8, such as Latin-1, raises
  `IOStreams::Errors::InvalidEncoding`. To count bytes, set the encoding of the file: `encoding("ISO-8859-1")` for
  Latin-1, whose values are then ISO-8859-1 strings, or the name of another single-byte code page, or
  `encoding("BINARY")` to read binary strings, as the layout does, such as for UTF-8 text whose sizes count bytes. See
  [Schemas in IOStreams 2.2 and 3.0](formats#schemas-in-iostreams-22-and-30).
* An `integer` or `number` field that holds no number, such as `N/A` or `1,234.50`, raises
  `IOStreams::Errors::InvalidValue`, where the layout reads it as `0`, or as the number that its leading digits make,
  such as `12` for `12-` and `1.0` for `1,234.50`. A fraction in an `integer` field, such as `12.5`, raises too, where
  the layout truncates it, while a whole number with a decimal point, such as `12.0`, is still read as `12`.
* A `number` field reads `NaN` and `Inf`, which the layout writes for a `Float` that is not finite, as `Float::NAN`
  and `Float::INFINITY`, where the layout reads them as `0.0`.
* A line whose fields are all blank, even where a filler holds text, is a blank row, `nil`, which a copy skips, where
  the layout reads a record of blank values, such as `{name: "", zip: nil}`.
* `each(:array)` yields the names of the fields first, as an `IOStreams::Row::HeaderRow`, and then an Array of the
  values of each line, where the layout yields a Hash for each line, as `each(:hash)` does.

What writes differently:

* An `integer` or `number` field raises `IOStreams::Errors::InvalidValue` for a value that is not a number, such as
  `"abc"`, and an `integer` field for a fraction, such as `12.7`, where the layout writes zeros, or truncates the
  fraction.
* A `string` field writes a `BigDecimal` as `12.5`, and a `Time` in ISO 8601, such as `2026-10-13T09:30:00Z`, where
  the layout writes their `to_s`, such as `0.125e2` and `2026-10-13 09:30:00 UTC`. It raises
  `IOStreams::Errors::InvalidValue` for a `Hash` or an `Array`, where the layout writes their `to_s`: to write their
  JSON text, such as `{"a":1}`, give the field the type `object` or `array`.
* A `number` field writes infinity as `INF`, where the layout writes `Inf`.
* A filler is written as spaces, also where the layout gives it a `type:` of `:integer` or `:float`, which writes
  zeros.
* A record whose keys are Strings, such as `"name"`, is written to fields named with Symbols, such as `:name`, and
  the other way around, where the layout writes spaces for each of its columns, or zeros for a number.
* A column after the column with `size: :remainder` is not written, since it is not in the schema.

### Moving the column options to a schema

`columns:`, `cleanse_header:`, `allowed_columns:`, `required_columns:` and `skip_unknown:` are deprecated. They still
work without a schema, so no change is needed yet. A [schema](formats#schema) describes the columns of the file on its
path instead, so that every reader and writer of the path, including a copy, checks them the same way. Its fields
name the keys of the records read, and each column of the header row is matched to a field whatever its case, spaces
and punctuation, or to one of the `aliases` of a field, see [Matching columns to fields](formats#matching-columns-to-fields).
So the keys no longer depend on how the cleansing rule changes a column, such as `Amount ($)` and `Amount (€)`, which
are both `amount_`.

To keep the keys of the records that the code reads, name each field as that key. The names that `allowed_columns:`
and `required_columns:` list already are, since they were compared to the columns once cleansed, such as `first_name`
for the column `First Name`, so use them as the names of the fields: the schema matches each column to the field
named as the column was cleansed. With `cleanse_header: false`, they are the columns as they are in the file, so use
them as they are.

With a schema, `columns:`, `allowed_columns:` and `required_columns:` raise `ArgumentError`, unless they are nil, and
so does `cleanse_header:`, even when it is nil. `skip_unknown:` only applies to `allowed_columns:`, so it is accepted,
and has no effect, so that code can supply the same options with and without a schema. The property of a schema
that replaces each one:

| Option | With a schema |
|--------|---------------|
| `columns:` | The fields are the columns, in order: with `header: false` to read a file of a format with a header row, such as CSV, `fieldsMatch: "partial"` to read JSON, and `fieldsMatch: "subset"` to write. A `nil` column, which was not read, is a field with `skip: true`, see [Field properties](formats#field-properties) |
| `allowed_columns:` with `skip_unknown: false` | `fieldsMatch: "superset"`, which accepts a file without some of the fields, as `allowed_columns:` does, or `"equal"` when `required_columns:` lists every allowed column |
| `allowed_columns:` with `skip_unknown: true` | `fieldsMatch: "partial"`, which accepts a file without some of the fields, as `allowed_columns:` does, or `"subset"` when `required_columns:` lists every allowed column |
| `required_columns:` | `constraints: {required: true}` with `allowBlank: true` on each field, which needs the column but not a value, as `required_columns:` did, or a `fieldsMatch` that needs every field. Without `allowBlank`, a blank value raises too |
| `required_columns:` without `allowed_columns:`, which also read the other columns | Also `fieldsMatch: "subset"`, `extraColumns: "keep"` and `keyType: "cleansed"`, which keep the other columns, keyed as `cleanse_header` cleansed them, see [Keeping the other columns](formats#keeping-the-other-columns) |
| `cleanse_header:` | The keys of each record are the names of the fields, which the columns are matched to, or with `keyType: "cleansed"` the names once cleansed, as `cleanse_header: true` cleansed the columns, see [Keys of the records read](formats#keys-of-the-records-read) |
| `cleanse_header: false` without the other options, which read every column as it is written | `fieldsMatch: "subset"`, `extraColumns: "keep"` and no fields |

~~~ruby
# Before (deprecated)
path.each(:hash, allowed_columns: %w[first_name zip_code], required_columns: %w[zip_code]) do |record|
  p record
end

# After
path.schema(
  fieldsMatch: "partial",
  fields:      [
    {name: "first_name"},
    {name: "zip_code", constraints: {required: true}, allowBlank: true}
  ]
).each(:hash) do |record|
  p record
end

# Both read "First Name,Zip Code,Notes\nJack,12345,x\nJill,,y\n" as:
# {"first_name" => "Jack", "zip_code" => "12345"}
# {"first_name" => "Jill", "zip_code" => nil}
~~~

Reading a CSV file without a header row:

~~~ruby
# Before (deprecated)
IOStreams.path("no_header.csv").each(:hash, columns: ["name", "address", "zip"]) do |record|
  p record
end

# After
path = IOStreams.path("no_header.csv").schema(
  header: false,
  fields: [
    {name: "name"},
    {name: "address"},
    {name: "zip"}
  ]
)
path.each(:hash) do |record|
  p record
end
~~~

Writing only some of the keys of each record, in a fixed order:

~~~ruby
# Before (deprecated)
path = IOStreams.path("sample.csv")
path.writer(:hash, columns: ["name", "zip"]) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end

# After
path = IOStreams.path("sample.csv").schema(
  fieldsMatch: "subset",
  fields:      [
    {name: "name"},
    {name: "zip"}
  ]
)
path.writer(:hash) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end
~~~

With a schema, `writer(:array)` writes the names of the fields as the header row, and takes each row as the values of
the fields, in order, as `columns:` did.

A schema reads the same records as the options it replaces, named as above, as it does in v3.0, except that:

* A column is matched to a field whatever its case, spaces and punctuation, so a column that `allowed_columns:` did
  not list once cleansed, such as `FirstName` for `first_name`, is read.
* Two columns that are the same field, such as `Email` and `email`, or `Amount ($)` and `Amount (€)` for the field
  `amount_`, raise `IOStreams::Errors::InvalidHeader`, where the value of the last one was kept.
* The keys of each record are in the order of the fields, rather than of the columns of the file.
* `each(:array)` yields a header row of the names of the fields, an `IOStreams::Row::HeaderRow`, and each row holds
  only the values of the fields, where the column options left the header row and the rows as they are in the file.
* A value after the last column, which is not blank, raises `IOStreams::Errors::InvalidHeader` unless `fieldsMatch`
  is `"subset"` or `"partial"`, where it was dropped.
* The text read is UTF-8, see [Schemas in IOStreams 2.2 and 3.0](formats#schemas-in-iostreams-22-and-30).
* `IOStreams.enforce_column_restrictions` does not apply, since a schema applies to every input. So a schema applies
  its fields to what the column options were not applied to, while `enforce_column_restrictions` is false, the
  default: the keys of JSON records, the `columns:` of a file without a header row, and a header row read with
  `cleanse_header: false`. One schema for the files of every format, such as uploads whose format is detected from
  their file names, applies to each of them, where `allowed_columns:` restricted the columns of a CSV file but not the
  keys of a JSON one. The names given to `columns:` were not cleansed, while a field named as one is matched to its
  column loosely.
* A name that the cleansing of v2.1 named without its letters that are not ASCII, such as `prnom` for the column
  `Prénom`, which an application may have kept in `allowed_columns:`, is not the field of that column, since a schema
  cleanses it to `prénom`, which IOStreams 3.0 also does without a schema. With `fieldsMatch: "subset"` or `"partial"`
  the column is skipped without an error, so name the field `prénom`, or keep the name and give the field the column
  as an alias, such as `{name: "prnom", aliases: ["Prénom"]}`.
* A `Time` written to a field without a type is written in ISO 8601, such as `2026-10-13T09:30:00.123456Z`, where
  `columns:` wrote its `to_s`, `2026-10-13 09:30:00 UTC`. A `datetime` field with
  `format: "%Y-%m-%d %H:%M:%S UTC"` writes the text that `to_s` wrote.
* A key of a record written that is the field only once compared loosely, such as `LastName` for `last_name`, is
  written, where `columns:` wrote an empty value, and so is a Symbol key for a field named with a String, such as
  `:name` for `"name"`, where a layout wrote spaces.

Every use of the options has a schema form, see the table above, including `required_columns:` without
`allowed_columns:` and `cleanse_header: false` on its own, which read every column, with `extraColumns: "keep"`, and
`columns:` with `nil` for a column to skip, with `skip: true`. The options still work, so keep them until the schema
has been checked against the files of the application, since it reads some of them differently, see above.

### Changes in behavior

- A failed copy no longer deletes a target that it did not write. `#copy_from`, `#copy_to` and `#move_to` open the
  source before the target, as v3.0 does, and an error raised before the target is opened, such as for a source that
  does not exist, or a mode that a copy does not convert with, leaves an existing target as it was, where v2.1 deleted
  it, and a failed copy to S3 keeps the existing object. A copy that fails part way still leaves no part of the file,
  see [When a copy fails](copy_files#when-a-copy-fails).
- A mode that a copy does not convert with, such as `copy_from(source, mode: :stream)`, raises `ArgumentError` before
  the source or the target is opened, with a message that starts with v2.1's, `Invalid mode: :stream`, and then lists
  the modes.
- A copy of a path, made with `dup`, has its own streams and options, so that changing it does not change the path
  that it was copied from, and a copy with `convert: false` no longer changes the streams of the source or the
  target. A copy with `convert: false` from a source with options set with `#option` copies it, where v2.1 raised
  `ArgumentError`.

## Upgrading to v2.1

v2.1 is a security release, and is backward compatible except for `IOStreams::Pgp.delete_keys`,
described below. Most applications upgrade without any code changes. The changes that would break
existing code are postponed to v3.0, and log a warning in v2.1. See [Coming in v3.0](#coming-in-v30).

### Changes that may need code changes

#### PGP `delete_keys` requires an email or key id

`IOStreams::Pgp.delete_keys` raises `ArgumentError` unless an `email:` or `key_id:` is supplied.
Previously, on GnuPG 2.1 and later, calling it without either deleted every key in the keyring, and
with `private: true`, every secret key. This is the only breaking change in v2.1, since that could
not be undone. To delete several keys, call it once for each key, for example for each key returned
by `IOStreams::Pgp.list_keys`.

#### SFTP `#each_child` requires a known host key

`#each_child` on an SFTP path now verifies the server's host key, the same way reading and writing
already did. Previously it trusted a host key the first time it was seen. If listing files now
fails, supply the server's host key with the `HostKey` ssh option, or add it to the `known_hosts`
file of the user running the application. See [SFTP](path#sftp-sftp).

`#each_child` now also supports the `HostKey`, `IdentityKey` and `IdentityFile` ssh options, and
some others. Previously any ssh option made it raise `ArgumentError`. Any ssh option it does not
support raises `ArgumentError`.

#### Other changes in behavior

- SFTP `#each_child` lists the files in the path's directory. Previously it ignored the path and
  listed the login directory, so `IOStreams.path("sftp://host/data/in").each_child("*.csv")`
  listed `~/*.csv`, returning paths such as `/a.csv`. A url without a path, such as `sftp://host`,
  still lists the login directory.
- `Path#join` and `IOStreams.join` only return an element unchanged when it is the path itself or
  is inside it. Previously any element that started with the same characters was returned as-is,
  so `IOStreams.path("s3://bucket/reports").join("reports_2024.csv")` gave
  `s3://bucket/reports_2024.csv`, instead of `s3://bucket/reports/reports_2024.csv`.
- When writing PSV or fixed width files, a line break within a value is replaced with a space, so
  that a value can no longer start a separate record.
- Internal temp files are created so that only the current user can read them.
- When reading lines, newlines within quoted values are kept within the line when the tabular format
  quotes its values, such as CSV. Previously this depended on whether the file name contained `.csv`,
  so `.format(:psv)` on a `.csv` file still joined quoted lines, and `.format(:csv)` on a stream
  without a file name did not.
- An `ArgumentError` for an option that a stream does not accept now says which direction the option
  belongs to, or lists the valid options. Previously it was Ruby's `unknown keyword` error.

### Security checklist

When upgrading, review how your application uses IOStreams for the following documented security
issues. Each one depends on how the application is written, so upgrading alone does not fix it.

#### File names from untrusted input

If a user, a job, or any other untrusted input can supply a file name, it can also supply `..`
or an absolute path, and read or overwrite any file that the process can access. `IOStreams.join`
and root paths do not prevent this.

New in v2.1, add **allowed paths** in an initializer, so that accessing any other path raises
`IOStreams::Errors::AccessDenied`:

~~~ruby
IOStreams.add_allowed_path("/var/my_app/uploads")
IOStreams.add_allowed_path("s3://my-app-bucket-name/export")
~~~

Once any allowed path is added, every path IOStreams accesses in the process must be within one of
them, so add every location that your application reads or writes. See
[Restricting access with allowed paths](path#restricting-access-with-allowed-paths).

#### Untrusted names in S3 urls

Any query string in an S3 url is added to the S3 request parameters. Do not interpolate an
untrusted file name into the url, since a name such as `file.csv?acl=public-read` would set
request parameters. Join it onto the path instead. See [AWS S3](path#aws-s3-s3).

~~~ruby
# Unsafe
IOStreams.path("s3://my-bucket-name/uploads/#{untrusted_name}")

# Safe
IOStreams.path("s3://my-bucket-name/uploads").join(untrusted_name)
~~~

#### Credentials in HTTP and SFTP urls

A username and password supplied in an HTTP or SFTP url remain part of it, so `#to_s` returns
them, as does any log or error message that includes the path. Supply them with the `username:`
and `password:` arguments instead, and log `#display_name`, which never includes them:

~~~ruby
# Returns the password from #to_s
IOStreams.path("sftp://jack:secret@sftp.example.org/file.csv")

# Does not
IOStreams.path("sftp://sftp.example.org/file.csv", username: "jack", password: "secret")
~~~

#### Untrusted HTTP urls

When any part of an HTTP url comes from untrusted input, an attacker can point it at internal
services or cloud metadata endpoints (Server Side Request Forgery), either directly or with a
redirect. Use `allow_hosts`, `http_redirect_count` and `maximum_file_size`, or allowed paths, which
also check every redirect. See [Security: untrusted URLs (SSRF)](path#security-untrusted-urls-ssrf).

#### Processing PGP files before they are verified

By default IOStreams passes the decrypted contents of a PGP file to your block as gpg decrypts it.
gpg can only check the file's integrity and signature once it has read the whole file, so a
tampered file is only rejected after your block has processed its contents. Either do not commit
any side effects until the block returns, for example by using a database transaction, or supply
the `verify_first` option, new in v2.1. See
[Verifying a file before processing it](pgp#verifying-a-file-before-processing-it).

~~~ruby
path.option(:pgp, passphrase: "receiver_passphrase", verify_first: true)
~~~

#### Importing and trusting PGP keys

`import_and_trust` and the writer's `import_and_trust_key` option trust a key at the Ultimate
level by default, so only use them with keys received from a verified, trusted source. When a key
cannot be fully verified, supply a lower `trust_level:` to `import_and_trust`, or a lower
`import_and_trust_level` option to the writer. See
[Trust level](pgp#trust-level).

In v2.1, `import_and_trust_key` encrypts to the imported key's fingerprint on GnuPG 2.1 and later.
Previously it encrypted to the key's email address, so if your keyring holds another key with the
same email address, that key could have been used instead. Check your keyring for duplicate email
addresses.

#### PGP files without integrity protection

Only enable `ignore_mdc_error` for files from a trusted source, since without MDC the decrypted
contents are not protected against tampering. See
[Reading legacy files without MDC integrity protection](pgp#reading-legacy-files-without-mdc-integrity-protection).

#### Column restrictions on uploaded files

By default, `allowed_columns` and `required_columns` are ignored for JSON input. Since the format
is usually inferred from the file name, renaming an upload from `.csv` to `.json` bypasses them.
If your application relies on them to restrict which columns an upload can set, apply them to every
input in an initializer, new in v2.1, and check whether any uploads were affected:

~~~ruby
IOStreams.enforce_column_restrictions = true
~~~

See [Column restrictions apply to every input](#column-restrictions-apply-to-every-input) for what
it changes.

## Coming in v3.0

These changes are postponed to v3.0 since they could break existing code. Each one logs a warning
in v2.1 and v2.2 via `IOStreams.logger` when it would change the result, so check your logs for them.
v3.0 makes many more changes, see its
[upgrading guide](https://github.com/reidmorrison/iostreams/blob/main/docs/upgrading.md#upgrading-to-v30), and
[Upgrading to v2.2](#upgrading-to-v22) for the deprecations that v2.2 reports to prepare for it.

### Column restrictions apply to every input

When reading records, `allowed_columns`, `required_columns` and `skip_unknown` will apply to every
input. In v2.1 they are ignored for JSON and `:hash` input, when `columns:` is supplied, and with
`cleanse_header: false`.

When either `allowed_columns` or `required_columns` is set, JSON keys will be cleansed the same way
as a header row, for example `"Name"` becomes `"name"`. Unknown keys will be skipped, or raise
`IOStreams::Errors::InvalidHeader` when `skip_unknown: false`, and a record that is missing a
required column will raise `IOStreams::Errors::InvalidHeader`.

To prepare: set `IOStreams.enforce_column_restrictions = true`, and check that the JSON files you
read with these options have the expected keys. See [Header options](formats#header-options).

### BZip2 options are strict

The BZip2 reader and writer ignore any option they do not accept, and log a warning. In v3.0 it will
raise `ArgumentError`, like every other stream. They accept `autoclose`, `first_only` and `small` when
reading, and `autoclose`, `block_size` and `work_factor` when writing.

To prepare: remove the option, or use a separate path for reading and for writing. See
[Reading and writing need separate options](streams#reading-and-writing-need-separate-options).

### PGP `export` without an email or key id

`IOStreams::Pgp.export(email: nil)` without a `key_id:` raises `IOStreams::Pgp::Failure`, as it did
before v2.1. In v3.0 it will raise `ArgumentError`. Calling it without either argument already raises
`ArgumentError`.

## Upgrading to v2.0

v2.0 is a major release with breaking changes:

- **Ruby 3.2 or later is required.**
- **Writing Zip files requires the `zip_kit` gem.** The retired `zip_tricks` gem has been replaced
  by its successor, `zip_kit`. If your application writes Zip files, replace `gem "zip_tricks"` with
  `gem "zip_kit"` in your Gemfile. Reading Zip files is unaffected.
- **The deprecated pre-v1.6 API has been removed**, including the `IOStreams::Deprecated` mix-in.
  Move any code still using it to the `IOStreams.path` and `IOStreams.stream` API.
- **The deprecated PGP writer `compression:` option has been removed.** Use `compress:` instead,
  available since v1.11.0.
- **`IOStreams::Pgp.logger` and `IOStreams::Pgp.logger=` have been removed.** Logging is configured
  for the whole library with `IOStreams.logger=`. See [logger](config#logger).

## Upgrading from before v1.6

The pre-v1.6 API was deprecated in v1.6 and removed in v2.0. Upgrade to v1.11 first, move all code to
the `IOStreams.path` and `IOStreams.stream` API, and then upgrade to v2.
