---
layout: default
---

## Copying between files

File copying can be used to:
* copy from one storage location to another.
* create a decrypted / encrypted copy of an existing file.
* create a decompressed / compressed copy of an existing file.

### Examples

Decompress `example.csv.gz` into `example.csv`:

~~~ruby
source = IOStreams.path("example.csv.gz")
IOStreams.path("example.csv").copy_from(source)
~~~

Decrypt a file encrypted with Symmetric Encryption:

~~~ruby
source = IOStreams.path("example.csv.enc")
IOStreams.path("example.csv").copy_from(source)
~~~

Encrypt a file using PGP encryption so that it can only be read by `receiver@example.org`.

~~~ruby
source = IOStreams.path("example.csv")
target = IOStreams.path("example.csv.pgp")
target.option(:pgp, recipient: "receiver@example.org")
target.copy_from(source)
~~~

When the file name does not have file extensions that would allow IOStreams to infer what streams to apply,
the streams can be explicitly set using `stream`.

In this example, the file `CUSTOMER_DATA` has no extensions, so `stream(:enc)` tells IOStreams
that its contents were encrypted with Symmetric Encryption. The decrypted contents are then
PGP encrypted and written to `xyz.csv.pgp` using the pgp key for `receiver@example.org`.

~~~ruby
input = IOStreams.path("CUSTOMER_DATA").stream(:enc)
IOStreams.path("xyz.csv.pgp").option(:pgp, recipient: "receiver@example.org").copy_from(input)
~~~

To copy a file _without_ performing any conversions (ignore file extensions), set `convert` to `false`:

~~~ruby
input = IOStreams.path("sample.json.zip")
IOStreams.path("sample.copy").copy_from(input, convert: false)
~~~

Custom stream conversions can be applied to both the source and the target in a single copy.
Here the source is read as binary and the target is PGP encrypted:

~~~ruby
source = IOStreams.path("source_file").stream(:encode, encoding: "BINARY")
IOStreams.path("target_file.pgp").option(:pgp, passphrase: "hello").copy_from(source)
~~~

To convert the contents row by row, or record by record, during the copy, supply `mode`.
For example, copy a CSV file into JSON, parsing and rendering each record:

~~~ruby
source = IOStreams.path("source_file.csv")
IOStreams.path("target_file.json").copy_from(source, mode: :hash)
~~~

Notes:
* `mode` accepts `:line`, `:array`, or `:hash`, and only applies when `convert` is `true`.
