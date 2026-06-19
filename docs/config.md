---
layout: default
---

## Configuring IOStreams

### add_root

Roots allow paths to reference a particular root directory, so that all path names are appended to that root.
Their primary purpose is to allow the exact same code to run in production and development, yet use completely
different data sources in each. For example, in production a root can point to an S3 bucket, while in
development it points to the local file system.

Roots are configured via an initializer at startup. `IOStreams.join` then joins the supplied path
elements onto the named root, using the `:default` root whenever a root is not supplied.

Set the default root for this environment in an initializer:
~~~ruby
IOStreams.add_root(:default, "/var/my_app/files")
~~~

Now the default root path is available:
~~~ruby
IOStreams.root
# => #<IOStreams::Paths::File:/var/my_app/files pipeline={}>
 
IOStreams.root.to_s
# => "/var/my_app/files"
~~~

Comparing the final path using `path` and then `join` that uses a root path:
~~~ruby
IOStreams.path("/var/my_app/files", "my_test_file.txt").to_s
# => "/var/my_app/files/my_test_file.txt"

IOStreams.join("my_test_file.txt").to_s
# => "/var/my_app/files/my_test_file.txt"
~~~


Using `path`:
~~~ruby
IOStreams.path("/var/my_app/files", "my_test_file.txt").write("Hello World")
~~~

With the default root path configured the above code can be simplified by using `join` since it resolves to the same path.
~~~ruby
IOStreams.join("my_test_file.txt").write("Hello World")
~~~

Multiple roots can be setup, for example one for input files, another for output files, another for
reports, etc. During development the roots can all point to a common location, while in production
they could be completely different S3 buckets.

For example add special paths for `downloads` and `uploads`.
~~~ruby
IOStreams.add_root(:downloads, "/var/my_app/downloads")
IOStreams.add_root(:uploads, "/var/my_app/uploads")
~~~

An example that writes a file into the `/var/my_app/downloads` directory:
~~~ruby
IOStreams.join("my_test_file.txt", root: :downloads).write("Hello World")
~~~

The other benefit is that the root paths used in an application are externalized from the code base. That way the
roots can be changed to different locations depending on the environment.

We can also change the storage mechanism by changing the root:
~~~ruby
IOStreams.add_root(:downloads, "s3://my-app-bucket-name/downloads")
IOStreams.add_root(:uploads, "s3://my-app-bucket-name/uploads")
~~~

Now the application will write to S3 and the code does not change at all.
~~~ruby
IOStreams.join("my_test_file.txt", root: :downloads).write("Hello World")
~~~

To use or query a configured root path:
~~~ruby
IOStreams.root(:downloads).to_s
# => "s3://my-app-bucket-name/downloads"
~~~

## temp_dir

When working with large files the standard temp file system location can be too small to handle downloading large
files. For example to decrypt a pgp file from S3, because GnuPG is not streaming capable and only operates on local files.

By default IOStreams looks up the location to store temp files in the following order:
* `ENV['TMPDIR']`
* `ENV['TMP']`
* `ENV['TEMP']`
* `Etc.systmpdir`
* `/tmp` (if it exists)
* Otherwise `.`

To explicity set the temp file location the following config option can be used:

~~~ruby
IOStreams.temp_dir = "/var/really_big_temp"
~~~

## logger

IOStreams can log debug information, such as the external commands it runs for PGP and SFTP.

When [Semantic Logger](https://logger.rocketjob.io) is loaded it is detected automatically, and IOStreams
logs to it without any additional configuration.

To use a different logger, or to log when Semantic Logger is not present, assign any logger that
responds to the standard logging methods:

~~~ruby
require "logger"
IOStreams.logger = Logger.new($stdout)
~~~

To disable logging entirely, set the logger to `nil`:

~~~ruby
IOStreams.logger = nil
~~~
