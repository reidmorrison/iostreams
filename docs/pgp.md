---
layout: default
---

# PGP Encrypted files/streams.

PGP encryption or decryption from IOStreams uses the [GnuPG](https://gnupg.org) command line program 
to perform encryption and decryption.

IOStreams has been tested against GnuPG v1.4.21, v2.0.30 and v2.2.20. 
Since GnuPG is a command line program, IOStreams has to parse its output to extract information. 
As a result every time that GnuPG changes it output then the RegEx parsers have to be updated for that version.  

## Installation

Install [GnuPG](https://gnupg.org)

Mac OSX via homebrew

    brew install gpg2
    
Redhat Linux

    rpm install gpg2

Confirm GunPGP is installed:

    gpg --version

### Tutorial

After installing GnuPG above, install iostreams:

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
 
Generate a private and public key that we can use as the sample sender of the encrypted files:
~~~ruby
IOStreams::Pgp.generate_key(name: "Sender", email: "sender@example.org", passphrase: "sender_passphrase")
~~~

Generate a private and public key that we can use as the sample receiver of the encrypted files:
~~~ruby
IOStreams::Pgp.generate_key(name: "Receiver", email: "receiver@example.org", passphrase: "receiver_passphrase")
~~~

By default the above keys are RSA 4096 bit encryption keys.

Reference a file path to hold the PGP encrypted data by adding `.pgp` as a file name extension: 
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
# => #<IOStreams::Paths::File:sample/example.csv.pgp pipeline={:pgp=>{}}>  
~~~

Add the email address for the recipient:
~~~ruby
path.option(:pgp, recipient: "receiver@example.org")
# => #<IOStreams::Paths::File:example.csv.pgp @options={:pgp=>{:recipient=>"receiver@example.org"}} pipeline={:pgp=>{:recipient=>"receiver@example.org"}}>  
~~~

Write data to the PGP file:
~~~ruby
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

Lets try to read the file:
~~~ruby
IOStreams.path("sample/example.csv.pgp").read
# ArgumentError (Missing both passphrase and IOStreams::Pgp::Reader.default_passphrase)
~~~

In order to decrypt the file it needs the passphrase for the receivers private key above:
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "sender_passphrase")
path.read
# IOStreams::Pgp::Failure
#        "Receiver <receiver@example.org>"
#  gpg: public key decryption failed: Bad passphrase
#  gpg: decryption failed: No secret key
~~~

It failed again because we tried to use the senders passphrase. Since only the receiver can decrypt this file we 
need to use its passphrase and therefore private key: 
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "receiver_passphrase")
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n" 
~~~

##### Sign the file

To prevent a man-in-the-middle attack we can sign the file so that the recipient knows the file came from the sender:
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, recipient: "receiver@example.org", signer: "sender@example.org", signer_passphrase: "sender_passphrase")
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

Try reading the pgp encrypted file that is now also signed by the sender:
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "receiver_passphrase")
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n" 
~~~

This time when we read the file the signature is automatically verified. However, this only works if the receiver
has already imported the senders public key.

##### Auto-sign all files

To automatically sign every PGP output file, set the global config options to sign with the sender credentials.
~~~ruby
IOStreams::Pgp::Writer.default_signer            = "sender@example.org"
IOStreams::Pgp::Writer.default_signer_passphrase = "sender_passphrase"
~~~

Now the file will be signed automatically without needing to supply the `signer` and `signer_passphrase` on every write.
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, recipient: "receiver@example.org")
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

### Decrypt output files

In the examples above the sender cannot decrypt the file because it was generated for the recipient only.

~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "sender_passphrase")
path.read
# IOStreams::Pgp::Failure
#        "Receiver <receiver@example.org>"
#  gpg: public key decryption failed: Bad passphrase
#  gpg: decryption failed: No secret key
~~~

Since the sender cannot decrypt the file how do we know what was actually sent to the recipient?

There are 2 options:
* Add the sender to the recipient list every time a file is created.
* Or, use the global configuration option to add the sender automatically to all PGP output files.

Add the sender to the recipient list every time a file is created.
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, recipient: ["receiver@example.org", "sender@example.org"])
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

Now the sender can also read the file:
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "sender_passphrase")
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n" 
~~~

Set the global configuration option to add the sender automatically to all PGP output files.
~~~ruby
IOStreams::Pgp::Writer.audit_recipient = "sender@example.org"
~~~

The sender is now automatically added to the recipient list every time a file is created.
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, recipient: "receiver@example.org")
path.writer do |io|
  io << "name,login\n"
  io << "Jack Jones,jjones\n"
  io << "Jill Smith,jsmith\n"
end
~~~

Now the sender can also read the file:
~~~ruby
path = IOStreams.path("sample/example.csv.pgp")
path.option(:pgp, passphrase: "sender_passphrase")
path.read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n" 
~~~

By now you must be getting tired of typing in the senders passphrase, so lets set the config option to remove that requirement:

~~~ruby
IOStreams::Pgp::Reader.default_passphrase = "sender_passphrase"
~~~

Try reading the above file again:
~~~ruby
IOStreams.path("sample/example.csv.pgp").read
# => "name,login\nJack Jones,jjones\nJill Smith,jsmith\n" 
~~~

## Cleanup

To remove the test PGP keys created above:
~~~ruby
IOStreams::Pgp.delete_keys(email: 'sender@example.org', private: true)
IOStreams::Pgp.delete_keys(email: 'receiver@example.org', private: true)
~~~

#### PGP FAQ:
- If you get not trusted errors
   gpg --edit-key sender@example.org
     Select highest level: 5


#### PGP Limitations
- Designed for processing larger files since a process is spawned for each file processed.
- For small in memory files or individual emails, use the 'opengpgme' library.

Compression Performance:
  Running tests on an Early 2015 Macbook Pro Dual Core with Ruby v2.3.1

  Input file: test.log 3.6GB
    :none:  size: 3.6GB  write:  52s  read:  45s
    :zip:   size: 411MB  write:  75s  read:  31s
    :zlib:  size: 241MB  write:  66s  read:  23s  ( 756KB Memory )
    :bzip2: size: 129MB  write: 430s  read: 130s  ( 5MB Memory )

Notes:
- Does not work yet with gnupg v2.1. Pull Requests welcome.




### import_and_trust_key

The standard approach with PGP is to import public keys into the keystore on every server. Copying the public keys to
every server can be tedious, especially when running inside docker containers.

An ideal way to manage PGP public keys is in a database, or in Secret Config that stores the keys in the
AWS SSM Parameter store.

Fetch the recipients public key from a data store. For example Secret Config
~~~ruby
public_pgp_key = SecretConfig.fetch("suppliers/acxiom/pgp/public_key")
~~~

When creating the pgp encrypted file let IOStreams import and trust the public key every time so that it does
not have to be managed on every production server. The option `import_and_trust_key` takes the public key as a string:
~~~ruby
path = IOStreams.join("test/sample.pgp", root: :downloads)
path.option(:pgp, import_and_trust_key: public_pgp_key)
path.write("Hello World")
​~~~

Now try to read the file:
~~~ruby
IOStreams.join("test/sample.pgp", root: :downloads).read
~~~
