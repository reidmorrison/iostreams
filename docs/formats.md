---
layout: default
title: File Formats
description: >-
  Converting rows and records to and from CSV, PSV, JSON and fixed width files,
  including format inference, format options and header handling.
---

When reading or writing rows (`:array`) or records (`:hash`), IOStreams converts each line
to or from the file's tabular format. The following formats are supported:

* `:csv`   Comma Separated Values
* `:psv`   Pipe Separated Values
* `:json`  One JSON document per line
* `:fixed` Fixed width columns
* `:array` Each line is already an array of values
* `:hash`  Each line is already a hash

PSV has no way to escape values, so when writing PSV, a `|` within a value is replaced with `:`
and a line break with a space, so that a value cannot add columns or records.

## Format inference

The format is inferred from the file name when it contains a recognized extension:

~~~ruby
IOStreams.path("sample.csv").each(:hash) { |record| p record }
IOStreams.path("sample.json").each(:hash) { |record| p record }
IOStreams.path("sample.psv").each(:hash) { |record| p record }
~~~

The format extension can appear anywhere in the file name, so `sample.csv.gz` and
`sample.json.pgp` are recognized as CSV and JSON respectively.

When the file name does not contain a recognized format extension, the format defaults to `:csv`.

## Specifying the format

When the file name cannot be used to infer the format, set it explicitly with `format`:

~~~ruby
path = IOStreams.path("sample_data")
path.format(:json)
path.each(:hash) { |record| p record }
~~~

`format` can be chained with the other path methods:

~~~ruby
IOStreams.path("sample_data").format(:json).each(:hash) { |record| p record }
~~~

## Format options

Format specific options are supplied with `format_options`. They are passed to the parser
for the chosen format. The `:fixed` format requires its file layout to be supplied this way,
as shown in the next section. The other formats do not currently take any options.

## Fixed width files

Fixed width files have no delimiters; each column is identified by its position within the line.
Since the layout cannot be inferred from the file, supply it using `format_options`:

~~~ruby
path = IOStreams.path("sample_data")
path.format(:fixed)
path.format_options(
  layout: [
    {size: 23, key: "name"},
    {size: 40, key: "address"},
    {size: 5,  key: "zip"}
  ]
)
path.each(:hash) { |record| p record }
~~~

Writing a fixed width file uses the same layout to render each record:

~~~ruby
path = IOStreams.path("sample_data")
path.format(:fixed)
path.format_options(
  layout: [
    {size: 23, key: "name"},
    {size: 40, key: "address"},
    {size: 5,  key: "zip"}
  ]
)
path.writer(:hash) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end
~~~

Note: The keys in the hashes being written must match the layout `:key` values exactly,
including whether they are strings or symbols.

Layout column definitions:

* `:size` The number of characters this column occupies.
  The last column may use a size of `:remainder` to take the rest of the line as its value.
* `:key` The name for this column. Leave out the key to ignore the column during parsing,
  and to space fill when rendering.
* `:type` `:string` (default), `:integer`, or `:float`.
  Strings are left justified and space padded, numbers are right justified and zero padded.
  When writing, line breaks within a string are replaced with a space so that a value cannot
  add records.
  Raises `IOStreams::Errors::ValueTooLong` when an `:integer` or `:float` value cannot be
  rendered in `size` characters.
* `:decimals` For `:float` columns, the number of decimal places to render.
  Default: 2

In addition to `layout`, the `:fixed` format takes one more option:

* `truncate: [true|false]`
  Whether to truncate string values that are longer than their column `:size` when writing.
  When false, a string value that is too long raises `IOStreams::Errors::ValueTooLong`
  instead of being truncated. Numeric values are never truncated.
  Default: true

### Character encoding

Fixed width files are read and written as ASCII by default. The programs that write them, such as
COBOL programs, and the formats that specify them, such as NACHA ACH and IRS FIRE, count each column's
size in bytes, and their text is ASCII, or a single-byte code page such as ISO-8859-1. So a value read
is a UTF-8 string, like the values of every other format, and any byte that is not ASCII raises
`IOStreams::Errors::InvalidEncoding`, naming the byte and its offset, rather than shifting every
column that follows it.

Each `:size` counts the characters of the text as it is read, and when writing, string values are
padded and truncated to `:size` characters. In ASCII, and in a single-byte code page, each character
is one byte, so the sizes count bytes.

Set the encoding of the file on the [encode stream](extensions#character-encoding) when it is not
ASCII. An encoding set with `#option` or `#stream` always replaces the ASCII default:

* A single-byte code page, such as ISO-8859-1 or Windows-1252, or EBCDIC from a mainframe: name it
  with the encoding that the values are read as, for example
  `option(:encode, encoding: "ISO-8859-1:UTF-8")`, `"Windows-1252:UTF-8"`, or `"IBM037:UTF-8"` for
  EBCDIC. The sizes count bytes, and the values are UTF-8 strings.
* To load a file anyway, replacing each byte that is not ASCII with a space, so that the columns stay
  aligned: `option(:encode, replace: " ")`.
* UTF-8 written by a program that counts characters: `option(:encode, encoding: "UTF-8")`.
* UTF-8 written by a program that counts bytes, which is rare: read it as binary, with
  `option(:encode, encoding: "BINARY")`, whose values are binary strings, or with `replace: " "`.

An EBCDIC file is split into lines after it is converted, so its lines must end with the EBCDIC line
feed (`0x25`), which converts to `\n`. The EBCDIC new line (`0x15`) converts to U+0085, so supply
`delimiter: "\u0085"` to `#each` or `#reader` for a file whose lines end with it.

The `:line` mode reads ASCII too when the format of the path is `:fixed`, set with `#format` or
detected from a file name such as `data.fixed`.

When writing, a value that is not ASCII raises `Encoding::UndefinedConversionError`, rather than
writing a line that is longer than the layout in bytes. Set the encoding of the file, such as
`option(:encode, encoding: "ISO-8859-1")`, whose lines are then the length of the layout in bytes, or
`replace: " "` to write a space for each character that is not ASCII:

~~~ruby
path = IOStreams.path("people.txt").option(:encode, encoding: "ISO-8859-1")
path.format(:fixed).format_options(layout: [{size: 10, key: "name"}, {size: 5, key: "zip"}])
path.writer(:hash) { |io| io << {"name" => "José", "zip" => "12345"} }
~~~

### Cleaning fixed width files

To remove non-printable characters, such as NUL padding, from a fixed width file, replace them with a
space, so that every column after them stays in place:

~~~ruby
path.option(:encode, cleaner: :replace_non_printable, replace: " ")
~~~

Since `replace:` also replaces invalid characters, each byte that is not ASCII is replaced with a space
too, unless the encoding of the file is set.

The `:printable` cleaner removes non-printable characters rather than replacing them, even with
`replace:`, which only replaces invalid characters. So each one it removes moves every column that
follows it, and a line with one raises `IOStreams::Errors::InvalidLineLength`.

## Header options

When reading or writing records (`:hash`), the following options control the header row:

* `columns: [Array<String>]`
  When reading, supplies the header columns for files that do not include a header row.
  When writing, sets the columns to write, including their order. Keys not listed in
  `columns` are ignored during writes.

* `cleanse_header: [true|false]`
  Whether to cleanse the column names read from the header row.
  Column names are stripped of leading and trailing whitespace, lowercased, and spaces
  and dashes are converted to underscores, so the header `" First Name "` becomes `"first_name"`.
  Default: true

* `allowed_columns: [Array<String>]`
  List of columns to allow. Any other columns are ignored when `skip_unknown` is true,
  otherwise an `IOStreams::Errors::InvalidHeader` exception is raised.
  Default: nil (allow all columns)

* `required_columns: [Array<String>]`
  List of columns that must be present, otherwise an exception is raised.

* `skip_unknown: [true|false]`
  When true, any columns not present in `allowed_columns` are skipped entirely as if they
  were not in the file at all. When false, an unknown column raises
  `IOStreams::Errors::InvalidHeader`.
  Default: true

When reading records, `allowed_columns`, `required_columns` and `skip_unknown` apply to the
header row, to the supplied `columns`, and, for formats without a header row such as JSON,
to the keys of each record. When either `allowed_columns` or `required_columns` is set, JSON keys
are cleansed the same way as a header row, unless `cleanse_header: false` is supplied.

When reading rows with `each(:array)`, they apply to the header row and to the supplied `columns`,
including with `cleanse_header: false`. The header row is yielded as it was read, and each row
still contains every value.

To return to the behavior before v3.0, where they only apply to a header row read from the file,
and only when `cleanse_header` is true, set `IOStreams.enforce_column_restrictions = false`.
This applies to reading both records and rows. A warning is then logged when applying them would
change the records or the header row read. Since the format is usually inferred from the file name,
renaming an uploaded file from `.csv` to `.json` then bypasses them.

Example, reading a headerless CSV file:

~~~ruby
path = IOStreams.path("no_header.csv")
path.each(:hash, columns: ["name", "address", "zip"]) do |record|
  p record
end
~~~

Example, writing only specific columns in a fixed order:

~~~ruby
path = IOStreams.path("sample.csv")
path.writer(:hash, columns: ["name", "zip"]) do |io|
  io << {"name" => "Jack Jones", "address" => "Somewhere", "zip" => 12345}
end
path.read
# => "name,zip\nJack Jones,12345\n"
~~~

Note: Column names are converted to strings, and the keys in the hashes being written may
be strings or symbols.
