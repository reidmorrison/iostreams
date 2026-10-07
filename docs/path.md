---
layout: default
title: Path
description: >-
  How a path identifies where a file is stored and how to reach it, with the
  arguments for each location: local disk, AWS S3, SFTP and HTTP.
---

A path identifies _where_ a file is stored and how to reach it, so that the streaming pipeline knows
where to read the data from or write it to.

Create a path with `IOStreams.path`, passing the file name, which may also be a URI, followed by any
arguments specific to that storage location. IOStreams infers the storage mechanism from the URI
scheme, so the same call returns a local file path, an S3 path, an SFTP path, and so on, all sharing
the identical interface.

IOStreams supports accessing files in the following places:

* File
* AWS S3
* Google Cloud Storage (Using the AWS S3 Client)
* SFTP
* HTTP(S) (Read with GET, write with PUT)

Are you using another cloud provider and want to add support for your favorite?
Checkout the supplied [IOStreams S3 path provider](https://github.com/reidmorrison/iostreams/blob/main/lib/io_streams/paths/s3.rb)
for an example of what is required. Pull requests welcome.

### File

The simplest case is a file on the local disk:

~~~ruby
path = IOStreams.path("somewhere/example.csv")
~~~

A `file://` url is also accepted. It is always absolute, so it has an empty host or `localhost`, and
characters such as a space, `?` or `#` are percent-encoded. Supply a relative path without `file://`.

~~~ruby
IOStreams.path("file:///home/user/my%20file.csv")
# Same as:
IOStreams.path("/home/user/my file.csv")
~~~

A file name of `~`, or starting with `~/`, is within the current user's home directory. This matches an
[SFTP](#sftp-sftp) url, where `~` is the login directory, so the location of a file can be configured, for example
in an environment variable, as a local file in one environment and on an SFTP server in another, without changing
the code. A `file://` url can also start with `~`, although that is not part of the `file://` standard:

~~~ruby
# The file data/example.csv within the home directory
IOStreams.path("~/data/example.csv")
# Same as:
IOStreams.path("file://~/data/example.csv")
IOStreams.path("file:///~/data/example.csv")

# The file data/example.csv within the login directory on the SFTP server
IOStreams.path("sftp://hostname/~/data/example.csv")
~~~

Only a leading `~` on its own is the home directory, so `~user/a.csv`, `~$Book1.xlsx` and `a/~/b.csv` are
unchanged. Use `./~/example.csv` for a directory called `~` in the current directory.

In code, `IOStreams.home` is the current user's home directory, `IOStreams.home("username")` is another user's,
and `IOStreams.working_path` is the current working directory:

~~~ruby
IOStreams.home.join("my file.csv")
# Same as, when the home directory is /home/user:
IOStreams.path("/home/user/my file.csv")

IOStreams.working_path.join("my file.csv")
~~~

#### Optional Arguments:

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
~~~

#### Required Arguments:

* url [String]

  Prefix must be: `s3://`, followed by bucket name, followed by key.
  Any query string in the url is added to the S3 request parameters, for example
  `s3://my-bucket-name/file_name.csv?acl=bucket-owner-full-control`.
  Examples:
    s3://my-bucket-name/file_name.txt
    s3://my-bucket-name/some_path/file_name.csv

  Security warning: do not interpolate an untrusted file name into the url, since a name such as
  `file.csv?acl=public-read` would set request parameters. Join it onto the path instead, which
  does not parse it as a query:
  `IOStreams.path("s3://my-bucket-name/uploads").join(untrusted_name)`

#### Optional Arguments:

* :access_key_id [String]

  AWS Access Key Id to use to access this bucket.

* :secret_access_key [String]

  AWS Secret Access Key Id to use to access this bucket.

* :region [String]

  The AWS region to connect to.
  Default: the region set in the environment variables or credential files.

* :client [Aws::S3::Client | Hash]

  Supply the AWS S3 Client instance to use for this path.
  Or, when a Hash, build a new client using the hash parameters.

~~~ruby
client = Aws::S3::Client.new(endpoint: "https://s3.test.com")
path   = IOStreams.path("s3://bucket/path/file_name.txt", client: client)

# Or, pass the client parameters directly:
path = IOStreams.path("s3://bucket/path/file_name.txt", client: {endpoint: "https://s3.test.com"})
~~~

Writer specific options:

* :acl [String]

  The canned ACL to apply to the object.

* :cache_control [String]

  Specifies caching behavior along the request/reply chain.

* :content_disposition [String]

  Specifies presentational information for the object.

* :content_encoding [String]

  Specifies what content encodings have been applied to the object and
  thus what decoding mechanisms must be applied to obtain the media-type
  referenced by the Content-Type header field.

* :content_language [String]

  The language the content is in.

* :content_length [Integer]
 
  Size of the body in bytes. This parameter is useful when the size of
  the body cannot be determined automatically.

* :content_md5 [String]

  The base64-encoded 128-bit MD5 digest of the part data. This parameter
  is auto-populated when using the command from the CLI. This parameted
  is required if object lock parameters are specified.

* :content_type [String]

  A standard MIME type describing the format of the object data.

* :expires [Time,DateTime,Date,Integer,String]

  The date and time at which the object is no longer cacheable.

* :grant_full_control [String]

  Gives the grantee READ, READ\_ACP, and WRITE\_ACP permissions on the
  object.

* :grant_read [String]

  Allows grantee to read the object data and its metadata.

* :grant_read_acp [String]

  Allows grantee to read the object ACL.

* :grant_write_acp [String]

  Allows grantee to write the ACL for the applicable object.

* :metadata [Hash<String,String>]

  A map of metadata to store with the object in S3.

* :server_side_encryption [String]

  The Server-side encryption algorithm used when storing this object in
  S3 (e.g., AES256, aws:kms).

* :storage_class [String]

  The type of storage to use for the object. Defaults to 'STANDARD'.

* :website_redirect_location [String]

  If the bucket is configured as a website, redirects requests for this
  object to another object in the same bucket or to an external URL.
  Amazon S3 stores the value of this header in the object metadata.

* :sse_customer_algorithm [String]

  Specifies the algorithm to use to when encrypting the object (e.g.,
  AES256).

* :sse_customer_key [String]

  Specifies the customer-provided encryption key for Amazon S3 to use in
  encrypting data. This value is used to store the object and then it is
  discarded; Amazon does not store the encryption key. The key must be
  appropriate for use with the algorithm specified in the
  x-amz-server-side​-encryption​-customer-algorithm header.

* :sse_customer_key_md5 [String]

  Specifies the 128-bit MD5 digest of the encryption key according to
  RFC 1321. Amazon S3 uses this header for a message integrity check to
  ensure the encryption key was transmitted without error.

* :ssekms_key_id [String]

  Specifies the AWS KMS key ID to use for object encryption. All GET and
  PUT requests for an object protected by AWS KMS will fail if not made
  via SSL or using SigV4. Documentation on configuring any of the
  officially supported AWS SDKs and CLI can be found at
  http://docs.aws.amazon.com/AmazonS3/latest/dev/UsingAWSSDK.html#specify-signature-version

* :ssekms_encryption_context [String]

  Specifies the AWS KMS Encryption Context to use for object encryption.
  The value of this header is a base64-encoded UTF-8 string holding JSON
  with the encryption context key-value pairs.

* :request_payer [String]

  Confirms that the requester knows that she or he will be charged for
  the request. Bucket owners need not specify this parameter in their
  requests. Documentation on downloading objects from requester pays
  buckets can be found at
  http://docs.aws.amazon.com/AmazonS3/latest/dev/ObjectsinRequesterPaysBuckets.html

* :tagging [String]

  The tag-set for the object. The tag-set must be encoded as URL Query
  parameters. (For example, "Key1=Value1")

* :object_lock_mode [String]

  The object lock mode that you want to apply to this object.

* object_lock_retain_until_date: [Time,DateTime,Date,Integer,String]

  The date and time when you want this object's object lock to expire.

* object_lock_legal_hold_status: [String]
  The Legal Hold status that you want to apply to the specified object.

### SFTP (sftp://)

If the supplied file name string includes the `sftp` URI.

~~~ruby
path = IOStreams.path("sftp://hostname/path/example.csv")
~~~

IOStreams reads and writes SFTP files by shelling out to the `sftp` command line program,
so it must be installed and on the `PATH`. When a password is supplied the `sshpass`
program is also required to pass the password to `sftp`. Additionally the `net-sftp` gem
must be added to the `Gemfile` to use `each_child`. `each_child` lists the files within the path's directory.

`each_child` also needs the `ed25519` gem, and the `bcrypt_pbkdf` gem except on JRuby, when the
server's host key or the identity key is an ed25519 key:

~~~ruby
gem "net-sftp"
gem "bcrypt_pbkdf", platform: :ruby
gem "ed25519"
~~~

Reading and writing do not need these gems, since the `sftp` program supports ed25519 keys itself.
Without them `each_child` fails as follows:
* An ed25519 identity key raises `NotImplementedError`: "unsupported key type `ssh-ed25519'".
* A `HostKey` that only contains the ed25519 key raises `Net::SSH::HostKeyUnknown`, even though the
  key is correct, because the ed25519 entry is skipped. The full output of `ssh-keyscan hostname`
  also includes the server's other key types, which work without these gems.

The path in the url is absolute, so `sftp://hostname/path/example.csv` is `/path/example.csv`, and a
url without a path, such as `sftp://hostname`, is the root directory `/`. On many servers the user is
confined to their own directory, which is then `/`. To refer to a path within the login directory
instead, start the path with `~`, as curl does, for example `sftp://hostname/~` to list the login
directory:

~~~ruby
# The file data/example.csv within the login directory
path = IOStreams.path("sftp://hostname/~/data/example.csv")
~~~

Read a file from a remote sftp server.
~~~ruby
IOStreams.path("sftp://example.org/path/file.txt", 
               username: "jbloggs", 
               password: "secret").
  reader do |input|
    puts input.read
  end
~~~

Raises `IOStreams::Errors::CommunicationsFailure` when the file could not be read or written.

Write to a file on a remote sftp server.
~~~ruby
IOStreams.path("sftp://example.org/path/file.txt", 
               username: "jbloggs", 
               password: "secret").
  writer do |output|
    output.write('Hello World')
  end
~~~

Display the contents of a remote file, supplying the username and password in the url.
Note that `#to_s` then includes the password, so prefer the `username:` and `password:` arguments above:
~~~ruby
IOStreams.path("sftp://jack:OpenSesame@test.com:22/path/file_name.csv").reader do |io|
  puts io.read
end
~~~

Use an identity file instead of a password to authenticate:
~~~ruby
path = IOStreams.path("sftp://test.com/path/file_name.csv", 
                      username: "jack", 
                      ssh_options: {IdentityFile: "~/.ssh/private_key"})
path.reader do |io|
  puts io.read
end
~~~

Pass in the IdentityKey itself instead of a password to authenticate. 
For example, retrieve the identity key stored in Secret Config: 
~~~ruby
identity_key = SecretConfig.fetch("suppliers/sftp/identity_key")

path = IOStreams.path("sftp://test.com/path/file_name.csv", 
                      username: "jack", 
                      ssh_options: {IdentityKey: identity_key})
path.reader do |io|
  puts io.read
end
~~~

#### Required Arguments:

* url [String]

  Prefix must be: `sftp://`, followed by host name, followed by file name.
  Format:
    "sftp://<host_name>/<file_name>"
    "sftp://username:password@hostname:22/path/file_name"

  A username and password supplied in the url remain part of it, so `#to_s` returns them,
  as does any log or error message that includes the path. To keep them out of logs, supply them
  with the `username:` and `password:` arguments instead, and log `#display_name`, which never
  includes them.

#### Optional Arguments:

* username: [String]

  Name of user to login with.

* password: [String]

  Password for the user.

* ssh_options: [Hash]

  * IdentityFile [String]

    Path to the local identity (private key) file to authenticate with, instead of a password.

  * IdentityKey [String]

    The identity (private key) itself, supplied as a string.
    Under the covers the key is written to a temp file and then passed as `IdentityFile`.

  * HostKey [String]

    The expected SSH host key presented by the remote host, instead of storing it in the
    `known_hosts` file. It must contain the entire line that would be stored in `known_hosts`,
    including the hostname, ip address, key type and key value. The easiest way to generate
    the required value is with `ssh-keyscan hostname`.
    Under the covers the value is written to a temp file and then passed as `UserKnownHostsFile`.

  * Any other options supported by ssh_config.
    `man ssh_config` to see all available options.

  `each_child` lists files with the `net-sftp` gem instead of the `sftp` program, so it only supports
  these ssh options: `HostKey`, `IdentityKey`, `IdentityFile`, `UserKnownHostsFile`,
  `StrictHostKeyChecking`, `ConnectTimeout`, `ServerAliveInterval`, `ServerAliveCountMax` and
  `LogLevel`. Any other option raises `ArgumentError`. Unlike the `sftp` program, `net-sftp` needs the
  `ed25519` and `bcrypt_pbkdf` gems to use ed25519 host or identity keys, see above.

Notes:
* Since the `sftp` program operates on local files, reading from or writing to an SFTP path
  streams through a local temp file behind the scenes.

### HTTP (http://, https://)

Read from a remote file over HTTP or HTTPS using an HTTP GET, and write to one using an HTTP PUT.
`exist?` and `size` use an HTTP HEAD, and `delete` uses an HTTP DELETE.

~~~ruby
IOStreams.path('https://www5.fdic.gov/idasp/Offices2.zip').read

IOStreams.path('https://example.com/upload/report.csv', headers: {"Authorization" => "Bearer token"}).write(data)
~~~

Notes:
* Since Net::HTTP download only supports a push stream, the data is streamed into a tempfile first.
* Writing also streams into a tempfile first, which is uploaded in a single PUT request once the
  block completes, so that the server receives its size in the `Content-Length` header.
  The `Content-Type` is `application/octet-stream` unless supplied with `headers:`.
  Any 2xx response is treated as success.
* Only a `307` or `308` redirect to the same scheme, host and port is followed when writing, and the file
  is uploaded again to its location. Other redirects change the request into a GET, which would discard
  the upload, and a redirect to another server would send it the data being uploaded, so they raise
  `IOStreams::Errors::CommunicationsFailure`.
* `exist?` returns `false`, `size` returns `nil`, and `delete` does nothing when the server responds
  with `404 Not Found` or `410 Gone`. Any other unsuccessful response raises
  `IOStreams::Errors::CommunicationsFailure`, for example when the server does not support HEAD or DELETE.
* `delete` follows redirects the same way as writing. `exist?` and `size` follow redirects the same way as reading.
* `move_to` from an HTTP path downloads the file and then deletes it with an HTTP DELETE.
  `move_to` an HTTP path uploads the file and then deletes the source.
* A redirect from `https` to `http` is not followed, when reading or writing, and raises
  `IOStreams::Errors::CommunicationsFailure`.
* Each redirect that is followed is logged at info level via `IOStreams.logger`, without any
  user name, password or query string.

#### Required Arguments:

* url [String]

  Prefix must be: `http://`, or `https://` followed by host name, followed by path and file name.
  Also supports passing the username and password for basic authentication in the URI.
  
  Format:
  * http://hostname/path/file_name
  * https://username:password@hostname/path/file_name

  A username and password supplied in the url remain part of it, so `#to_s` returns them,
  as does any log or error message that includes the path. To keep them out of logs, supply them
  with the `username:` and `password:` arguments instead, and log `#display_name`, which never
  includes them.

#### Optional Arguments:

* username: [String]

  When supplied, basic authentication is used with the username and password.

* password: [String]

  Password to use use with basic authentication when the username is supplied.

* parameters: [Hash]

  Query parameters to append to the url as a query string.
  For example, `parameters: {"type" => "csv"}` appends `?type=csv` to the url.

* http_redirect_count: [Integer]

  Maximum number of http redirects to follow.
  Set to `0` to disable following redirects entirely.
  Default: `10`

* allow_hosts: [String | Array<String>]

  Optional allow-list of host names that may be contacted. It is applied both to the
  supplied url and to every redirect that is followed; a request to any other host raises
  `IOStreams::Errors::CommunicationsFailure`.
  Default: `nil` (any host is allowed).

* maximum_file_size: [Integer]

  Optional maximum number of bytes to download. When the response body exceeds this size the
  download is aborted with an `IOStreams::Errors::CommunicationsFailure`.
  Only applies when reading: writing to a path with a `maximum_file_size` raises `ArgumentError`.
  Default: `nil` (no limit).

* headers: [Hash]

  Optional headers to add to every request, when reading and when writing, for example
  `{"Authorization" => "Bearer token"}`, or `{"Content-Type" => "text/csv"}` when writing.
  Since any header may hold a credential, such as `X-Api-Key`, none of them are resent when a
  redirect points at a different scheme, host, or port.
  Default: `nil` (no additional headers).

~~~ruby 
path = IOStreams.path("http://hostname/path/example.csv")
~~~

#### Security: untrusted URLs (SSRF)

Reading an HTTP(S) path causes the application to issue a request to the host named in the url.
When the url, or any part of it, can be influenced by untrusted input, an attacker can point it
at internal services or cloud metadata endpoints (Server Side Request Forgery).

Because redirect targets are chosen by the remote server, validating only the url that is passed
in is not sufficient: a trusted (or compromised) server can redirect the request to an internal
address. IOStreams provides a few controls to reduce this exposure:

* Restrict which hosts may be contacted, including across redirects:

~~~ruby
IOStreams.path("https://supplier.example.com/report.csv", allow_hosts: ["supplier.example.com"]).read
~~~

* Disable redirects entirely for untrusted urls:

~~~ruby
IOStreams.path(untrusted_url, http_redirect_count: 0).read
~~~

* Cap the download size to avoid unbounded (denial of service) responses:

~~~ruby
IOStreams.path(untrusted_url, maximum_file_size: 50 * 1024 * 1024).read
~~~

Basic authentication credentials, and the supplied `headers:`, are only ever sent to the original
host. They are not resent when a redirect points at a different scheme, host, or port, so a redirect
cannot leak them to another server. A redirect from `https` to `http` is not followed, so the data
cannot be read or changed in transit. When writing or deleting, a redirect is only followed to the same scheme,
host and port, so a redirect cannot send the data being uploaded to another server, or delete a file on it. Each redirect
that is followed is logged at info level via `IOStreams.logger`. For stronger guarantees, route these downloads through an egress proxy or network
policy that blocks private, loopback, and link-local (cloud metadata) addresses.

Similarly when using https:

~~~ruby 
path = IOStreams.path("https://hostname/path/example.csv")
~~~

This time IOStreams inferred that the file lives on an HTTP Server and returns `IOStreams::Paths::HTTP`.

### Path Operations

Paths support common file operations, regardless of where the file is stored:

~~~ruby
path = IOStreams.path("sample/example.csv")

# Does the file exist?
path.exist?
# => true

# Size of the file in bytes.
path.size
# => 64

# Size of the file in bytes, or nil when it does not exist or is empty, like `File.size?`.
path.size?
# => 64

# Is it a file, or a directory?
path.file?
# => true
path.directory?
# => false

# Is it an empty file, or a directory without any children?
path.empty?
# => false

# Delete the file.
path.delete

# Move the file to another path, returning the target path.
path.move_to("sample/moved.csv")

# Create the directory path, when it does not already exist.
IOStreams.path("sample/data").mkpath
~~~

Inspect the components of a path's file name:

~~~ruby
# The full name of the path, without any user name, password or query in an SFTP or HTTP url,
# for logging. Unlike #to_s it cannot be used to create the path again.
IOStreams.path("sftp://jack:secret@sftp.example.org/data/ruby.rb").display_name
# => "sftp://sftp.example.org/data/ruby.rb"

# The last component of the path.
IOStreams.path("/home/gumby/work/ruby.rb").basename
# => "ruby.rb"

# Remove a specific suffix from the file name.
IOStreams.path("/home/gumby/work/ruby.rb").basename(".rb")
# => "ruby"

# Remove any extension by supplying ".*".
IOStreams.path("/home/gumby/work/ruby.rb").basename(".*")
# => "ruby"

# The directory portion of the path.
IOStreams.path("a/b/d/test.rb").dirname
# => "a/b/d"

# The extension, including the leading period.
IOStreams.path("a/b/d/test.rb").extname
# => ".rb"

# The extension, without the leading period.
IOStreams.path("a/b/d/test.rb").extension
# => "rb"
~~~

Notes:
* `basename`, `dirname`, `extname`, and `extension` return `nil` when no file name was set.
* A leading period on a dotfile is not treated as an extension, so `.profile` has no extension,
  while `.profile.sh` has the extension `sh`.
* A file name ending in a period, such as `foo.`, returns an empty string for the extension.

Iterate over the files in a path using a wildcard pattern:

~~~ruby
IOStreams.path("sample").each_child("*.csv") do |child|
  puts child
end

# Recursively, including sub-directories:
IOStreams.path("sample").each_child("**/*.csv") do |child|
  puts child
end
~~~

`each_child` is also available directly on `IOStreams` when the pattern includes the full path:

~~~ruby
IOStreams.each_child("sample/**/*.csv") { |child| puts child }
~~~

Notes:
* These operations are supported by File, S3 and SFTP paths. HTTP paths support all of them except
  `each_child`. HTTP has no directories, so `directory?` is always false and `mkpath` does nothing.
* S3 has no directories either, only keys that contain `/`. An S3 path is a directory when any key is
  within it, such as `a` and `a/b` for the key `a/b/c.csv`, or when a folder object exists for it, with
  a key ending in `/`, such as the folders created by the S3 console. An S3 directory is `empty?` when
  only its folder object exists.
* `file?`, `directory?` and `empty?` are false when the path does not exist.
* By default `each_child` patterns are case-insensitive and hidden files are excluded.
  Supply `case_sensitive: true` or `hidden: true` to change this behavior.
* Supply `directories: true` to also return directories. S3 has no directories, only keys that contain `/`,
  so the directories within the keys are returned, such as `a` and `a/b` for the key `a/b/c.csv`.
* `each_child` returns nothing when the path does not exist, or is a file. A directory below the path
  that cannot be read is skipped.
* S3 and SFTP paths also yield the attributes of each child as the second argument to the block.
  These attributes are specific to each store, and are not available for local files:
  * S3 yields the attributes of the object in the listing, such as `:size`, `:last_modified` (a `Time`),
    `:etag` and `:storage_class`. A directory has empty attributes, unless a folder object exists for it.
  * SFTP yields the attributes returned by the server, such as `:size`, `:permissions` and `:mtime`
    (seconds since the epoch). Which attributes are present depends on the server.

  Code that runs against more than one store, for example where the path is configured, should only use
  the first argument, and use methods on the path, such as `size`, for anything else.

### Using root paths

Roots allow paths to reference a particular root directory, so that all path names are appended to that root.
By using `IOStreams.join` instead of `IOStreams.path`, the storage location is no longer embedded in the
application code, it is configured once at startup.

The primary purpose of roots is to allow the exact same code to run in production and development,
yet use completely different data sources in each. For example, in production the root can point to an
S3 bucket, while in development it points to the local file system.

Roots are configured via an initializer at startup. Multiple roots can be setup, for example one for
input files, another for output files, another for reports, etc. During development the roots can all
point to a common location, while in production they could be completely different S3 buckets.

For example, inside an initializer:
~~~ruby
IOStreams.add_root(:default, "tmp/export")
IOStreams.add_root(:ftp, "tmp/ftp")
~~~

`:default` is used whenever a root is not supplied when calling `IOStreams.join`:
~~~ruby
# Uses the :default root: "tmp/export/sample/example.csv"
path = IOStreams.join("sample", "example.csv")

# Uses the :ftp root: "tmp/ftp/sample/example.csv"
path = IOStreams.join("sample", "example.csv", root: :ftp)
~~~

The following code:
~~~ruby
path = IOStreams.path("tmp/export", "sample", "example.csv")
path.writer(:line) do |io|
  io << "Welcome"
  io << "To IOStreams"
end
~~~

Can be reduced to:
~~~ruby 
path = IOStreams.join("sample", "example.csv")
path.writer(:line) do |io|
  io << "Welcome"
  io << "To IOStreams"
end
~~~

Most importantly the root path information and storage mechanism are externalized from the application code.

For example, to make the above code write to S3 in production, change the initializer to:
~~~ruby
IOStreams.add_root(:default, "s3://my-app-bucket-name/export")
IOStreams.add_root(:ftp, "s3://my-app-ftp-bucket-name/ftp")
~~~

The code calling `IOStreams.join` does not change at all, see [Config](config) for more examples.

### Restricting access with allowed paths

Roots make paths easy to build, but they do not stop a path from leaving the root, for example
`IOStreams.join("../../etc/passwd")`. When file names come from untrusted input, such as a user or a
job's configuration, add allowed paths in an initializer to restrict which paths IOStreams can access:

~~~ruby
IOStreams.add_allowed_path("/var/my_app/uploads")
IOStreams.add_allowed_path("s3://my-app-bucket-name/export")
IOStreams.add_allowed_path("sftp://sftp.example.org/outbound")
IOStreams.add_allowed_path("https://reports.example.org/daily")
~~~

Once any allowed path has been added, reading, writing, listing, deleting or otherwise accessing a
path that is not within one of them raises `IOStreams::Errors::AccessDenied`:

~~~ruby
IOStreams.path("/var/my_app/uploads/file.csv").read
# => "..."

IOStreams.path("/var/my_app/uploads/../secrets.yml").read
# => IOStreams::Errors::AccessDenied

# Check without raising:
IOStreams.allowed_path?("/etc/passwd")
# => false

IOStreams.path("/etc/passwd").allowed?
# => false
~~~

Paths are normalized before they are compared:

- Local file names are resolved to their real path, so neither `..` nor a symbolic link can be used to
  leave an allowed path. A relative allowed path is resolved against the current working directory
  when it is added.
- S3 paths must be in the same bucket. Keys containing `.` or `..` segments are denied, since some
  services that implement the S3 API resolve them.
- SFTP and HTTP paths must have the same host and port, and for HTTP the same scheme. `.` and `..`
  are resolved the way the server resolves them. Every HTTP redirect is checked as well.

Notes:

- By default no allowed paths are added, and every path is accessible.
- `each_child` skips children that are not within the allowed paths, for example a symbolic link to a
  file elsewhere.
- Temp files from `IOStreams.temp_file` are always accessible.
- `IOStreams.allowed_paths` returns the normalized allowed paths, and `IOStreams.delete_allowed_path`
  removes one.
- Paths from a scheme added with `IOStreams.register_scheme` are denied, unless its path class
  implements the private method `#allowed_location`.
- A local file could be replaced with a symbolic link after it is checked but before it is opened.
  Do not allow paths where untrusted users can create files.
