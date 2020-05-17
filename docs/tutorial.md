---
layout: default
---

## File / Data Streaming with Ruby

If all files were small, they could just be loaded into memory in their entirety. 
However, multi Gigabytes, or even Terabytes in size, loading them into memory is not feasible.
 
In linux it is common to use pipes to stream data between processes. 
For example:

~~~
# Count the number of lines in a file that has been compressed with gzip
cat abc.gz | gunzip -c | wc -l
~~~

For large files it is critical to be able to read and write these files as streams. Ruby has support
for reading and writing files using streams, but has no built-in way of passing one stream through
another to support for example compressing the data, encrypting it and then finally writing the result
to a file. Several streaming implementations exist for languages such as `C++` and `Java` to chain
together several streams, `IOStreams` attempts to offer similar features for Ruby.

~~~ruby
# Read a compressed file:
IOStreams.path("hello.gz").reader do |io|
  data = io.read(1024)
  puts "Read: #{data}"
end
~~~

The true power of streams is shown when many streams are chained together to achieve the end
result, without holding the entire file in memory, or ideally without needing to create
any temporary files to process the stream.

~~~ruby
# Create a file that is compressed with GZip and then encrypted with Symmetric Encryption:
IOStreams.path("hello.gz.enc").writer do |io|
  io << "Hello World"
  io << "and some more"
end
~~~

The power of the above example applies when the data being written starts to exceed hundreds of megabytes,
or even gigabytes.

By looking at the file name supplied above, `iostreams` is able to determine which streams to apply
to the data being read or written. For example:
* `hello.zip` => Compressed using Zip
* `hello.zip.enc` => Compressed using Zip and then encrypted using Symmetric Encryption
* `hello.gz.enc` => Compressed using GZip and then encrypted using Symmetric Encryption

The objective is that all of these streaming processes are performed used streaming
so that only the current portion of the file is loaded into memory as it moves
through the entire file.
Where possible each stream never goes to disk, which for example could expose
un-encrypted data.

## Step by Step 

Install IOStreams gem:
~~~
gem install iostreams --no-doc
~~~

Open a ruby interactive console:

~~~
irb
~~~
 
Load iostreams:

~~~ruby
require "iostreams"
~~~
 
Reference a file path to hold CSV data and then compress it with GZip: 
~~~ruby
path = IOStreams.path("sample/example.csv.gz")
# => #<IOStreams::Paths::File:sample/example.csv.gz pipeline={:gz=>{}}> 
~~~

The path and file name does not exist yet:
~~~ruby
path.exist?
# => false 
~~~

If the path `sample` does not exist, it is created automatically during the first write. 
Write CSV data to the file, compressing to GZip as we go.
~~~ruby
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

To verify the data written above, read the entire file:
~~~ruby
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n"
~~~

It would be much easier if we could write the CSV data as hashes and let IOStreams deal
with all the details on how to create properly formatted CSV data: 
~~~ruby
path.writer(:hash) do |io|
  io << {name: "Jack Jones", login: "jjones"}
  io << {name: "Jill Smith", login: "jsmith"}
end 
~~~

Verify the data written by reading the entire file:
~~~ruby
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n"
~~~

Now lets read the file one line at a time:
~~~ruby
path.each do |line|
  puts line
end
~~~
Output:
~~~
name,login
Jack Jones,jjones
Jill Smith,jsmith
~~~

But who wants to do CSV parsing by hand, lets get IOStreams to do that for us by passing `:array` to `each`:
~~~ruby
path.each(:array) do |array|
  p array
end
~~~
Output:
~~~ruby
["name", "login"]
["Jack Jones", "jjones"]
["Jill Smith", "jsmith"]
~~~

That was better, but we really want a hash back where IOStreams takes care of the CSV header:
~~~ruby
path.each(:hash) do |hash|
  p hash
end
~~~
Output:
~~~ruby
{"name"=>"Jack Jones", "login"=>"jjones"}
{"name"=>"Jill Smith", "login"=>"jsmith"}
~~~

As the file gets larger and we reach millions of rows the above code does not have to change at all. 
And memory utilization stays about the same since each block is read in, decompressed, and parsed 
from CSV one block at a time. The garbage collector can then free the released blocks from memory. 

Now lets read a zip file hosted on an HTTP Web Server, displaying the first row as a hash: 

~~~ruby
IOStreams.
  path("https://www5.fdic.gov/idasp/Offices2.zip").
  option(:zip, entry_file_name: "OFFICES2_ALL.CSV").
  each(:hash) do |row|
    p row
    # Just show the first line for this tutorial
    break
  end
~~~
Output:
~~~ruby
{"address"=>"1 Lincoln St. Fl 1", "bkclass"=>"SM", "cbsa"=>"Boston-Cambridge-Newton, MA-NH", "cbsa_div"=>"Boston, MA", "cbsa_div_flg"=>"1", "cbsa_div_no"=>"14454", "cbsa_metro"=>"14460", "cbsa_metro_flg"=>"1", "cbsa_metro_name"=>"Boston-Cambridge-Newton, MA-NH", "cbsa_micro_flg"=>"0", "cbsa_no"=>"14460", "cert"=>"14", "city"=>"Boston", "county"=>"Suffolk", "csa"=>"Boston-Worcester-Providence, MA-RI-NH-CT", "csa_flg"=>"1", "csa_no"=>"148", "estymd"=>"1792-01-01", "fi_uninum"=>"6", "mainoff"=>"1", "name"=>"State Street Bank And Trust Company", "offname"=>"State Street Bank And Trust Company", "offnum"=>nil, "rundate"=>"2020-05-14", "servtype"=>"11", "stalp"=>"MA", "stcnty"=>"25025", "stname"=>"Massachusetts", "uninum"=>"6", "zip"=>"2111"}
~~~

Noticed that it took a while to return the first line?

That is because `zip` requires the entire file to be downloaded before it can decompress anything
in the file. And HTTP uses a push protocol when reading files, so it is downloaded automatically
into a temp file behind the scenes so that we can read it as if it was a local file.


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

Decrypt the file `abc.csv.enc` and write it to `xyz.csv`.

~~~ruby
input = IOStreams.path("abc.csv.enc")
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

## Notes

* Due to the nature of Zip, both its Reader and Writer methods will create
  a temp file when reading from or writing to a stream.
  Recommended to use Gzip over Zip since it can be streamed without requiring temp files.
* Zip becomes exponentially slower with very large files, especially files
  that exceed 4GB when uncompressed. Highly recommend using GZip for large files.
