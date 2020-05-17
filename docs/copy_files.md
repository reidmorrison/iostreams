---
layout: default
---


## Copying between files

Stream based file copying. Changes the file type without changing the file format. For example, compress or encrypt. 

Encrypt the contents of the file `sample.json` and write to `sample.json.enc`

~~~ruby
input = IOStreams.path("sample.json")
IOStreams.path("sample.json.enc").copy_from(input)
~~~

Encrypt and compress the contents of the file `sample.json` with Symmetric Encryption and write to `sample.json.enc`

~~~ruby
input = IOStreams.path("sample.json")
IOStreams.path("sample.json.enc").option(:enc, compress: true).copy_from(input)
~~~

Encrypt and compress the contents of the file `sample.json` with pgp and write to `sample.json.enc`

~~~ruby
input = IOStreams.path("sample.json")
IOStreams.path("sample.json.pgp").option(:pgp, recipient: "sender@example.org").copy_from(input)
~~~

Decrypt the file `example.csv.enc` and write it to `xyz.csv`.

~~~ruby
input = IOStreams.path("example.csv.enc")
IOStreams.path("xyz.csv").copy_from(input)
~~~

Decrypt file `ABC` that was encrypted with Symmetric Encryption, 
PGP encrypt the output file and write it to `xyz.csv.pgp` using the pgp key that was imported for `a@a.com`.

~~~ruby
input = IOStreams.path("ABC").stream(:enc)
IOStreams.path("xyz.csv.pgp").option(:pgp, recipient: "a@a.com").copy_from(input)
~~~

To copy a file _without_ performing any conversions (ignore file extensions), set `convert` to `false`:

~~~ruby
input = IOStreams.path("sample.json.zip")
IOStreams.path("sample.copy").copy_from(input, convert: false)
~~~
