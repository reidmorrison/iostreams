---
layout: default
---

# File Storage

* File
* AWS S3
* SFTP
* HTTP(S) (Read only)

## Path

In order to apply a streaming pipeline it needs to know where the data is being stored and how it should be accessed.
  
A path describes the data store and the attributes for the file to be stored there.

When a path is created it takes the name of the file which can also be a URI, followed by several arguments
specific to that path. IOStreams will infer the file storage mechanism based on the supplied URI.

### File

The simplest case is a file on the local disk:

~~~ruby
path = IOStreams.path("somewhere/example.csv")
# => #<IOStreams::Paths::File:somewhere/example.csv pipeline={}>
~~~

When a file path is created it will accept the following arguments:

#### Arguments:
* `:create_path` set to false to stop IOStreams from automatically creating the output directories 
  if they do not exist.
  Default: true 
~~~ruby
path = IOStreams.path("somewhere/example.csv.gz", create_path: false)
~~~

### AWS S3 (s3://)

If the supplied file name string includes a URI. For example if AWS is configured locally:

~~~ruby
path = IOStreams.path("s3://bucket-name/path/example.csv")
#  => #<IOStreams::Paths::S3:/path/example.csv pipeline={}>
~~~

### SFTP (sftp://)

If the supplied file name string includes a URI.

~~~ruby
path = IOStreams.path("sftp://hostname/path/example.csv")
#  => #<IOStreams::Paths::SFTP:/path/example.csv pipeline={}>
~~~

This time IOStreams inferred that the file lives on an SFTP Server and returns `IOStreams::Paths::SFTP`.


### HTTP (http://, https://)

If the supplied file name string includes a URI.

~~~ruby 
path = IOStreams.path("http://hostname/path/example.csv")
# => #<IOStreams::Paths::HTTP:/path/example.csv pipeline={}> 
~~~

Similarly when using https:

~~~ruby 
path = IOStreams.path("https://hostname/path/example.csv")
# => #<IOStreams::Paths::HTTP:/path/example.csv pipeline={}> 
~~~

This time IOStreams inferred that the file lives on an HTTP Server and returns `IOStreams::Paths::HTTP`.

## Pipeline

If the file is compressed, the pipeline will infer the necessary streams that need to be applied to it:

~~~ruby
path = IOStreams.path("somewhere/example.csv.gz")
# => #<IOStreams::Paths::File:somewhere/example.csv.gz pipeline={:gz=>{}}>
 
path.pipeline
# => {:gz=>{}} 
~~~

The `pipeline` above includes `:gz` to indicate that the file should compressed / decompressed with GZip.

#### Options

Each path supports several options which can be supplied using the `option` method. 
For files the only available option is to disable the auto-creation of the target directory during writes:

~~~ruby
path = IOStreams.path("somewhere/example.csv.gz", create_path: false)
path.pipeline
# => {:gz=>{}} 
~~~

#### Stream
