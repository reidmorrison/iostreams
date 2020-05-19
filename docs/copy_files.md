---
layout: default
---


## Copying between files

File copying can be used to:
* copy from one storage location to another.
* create a decrypted / encrypted copy of an existing file.
* create a decompressed / compressed copy of an existing file.

Stream based file copying. Changes the file type without changing the file format. For example, compress or encrypt. 

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

In this example, the file `CUSTOMER_DATA` 

Decrypt the contents of file that was encrypted with Symmetric Encryption 
PGP encrypt the output file and write it to `xyz.csv.pgp` using the pgp key that was imported for `a@a.com`.

~~~ruby
input = IOStreams.path("CUSTOMER_DATA").stream(:enc)
IOStreams.path("xyz.csv.pgp").option(:pgp, recipient: "a@a.com").copy_from(input)
~~~

To copy a file _without_ performing any conversions (ignore file extensions), set `convert` to `false`:

~~~ruby
input = IOStreams.path("sample.json.zip")
IOStreams.path("sample.copy").copy_from(input, convert: false)
~~~
