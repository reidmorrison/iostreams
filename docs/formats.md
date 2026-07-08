---
layout: default
---

# File Formats

When reading or writing rows (`:array`) or records (`:hash`), IOStreams converts each line
to or from the file's tabular format. The following formats are supported:

* `:csv`   Comma Separated Values
* `:psv`   Pipe Separated Values
* `:json`  One JSON document per line
* `:fixed` Fixed width columns
* `:array` Each line is already an array of values
* `:hash`  Each line is already a hash

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
