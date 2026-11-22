# frozen_string_literal: true

require_relative "test_helper"
require "json"

module IOStreams
  class PathToHTest < Minitest::Test
    # The path that the Hash of the supplied path creates, once the Hash has been stored as JSON.
    def self.restored(path)
      IOStreams.path(JSON.parse(JSON.generate(path.to_h)))
    end

    describe "IOStreams::Path#to_h" do
      def restored(path)
        PathToHTest.restored(path)
      end

      describe "a local path" do
        it "holds only the url without settings" do
          assert_equal({"url" => "people.csv.gz"}, IOStreams.path("people.csv.gz").to_h)
        end

        it "creates the same path again" do
          path = IOStreams.path("/data", "people.csv.gz")
          copy = restored(path)

          assert_equal path, copy
          assert_instance_of IOStreams::Paths::File, copy
          assert_equal({gz: {}}, copy.pipeline)
        end

        it "holds create_path when it is false" do
          path = IOStreams.path("people.csv", create_path: false)

          assert_equal({"url" => "people.csv", "arguments" => {"create_path" => false}}, path.to_h)
          refute restored(path).create_path
        end

        it "holds the file name when it is not the name of the path" do
          path = IOStreams.path("tempfile2527").file_name("people.csv.gz")

          assert_equal "people.csv.gz", path.to_h["file_name"]
          assert_equal({gz: {}}, restored(path).pipeline)
        end

        it "raises for a file name that is not valid UTF-8, which JSON does not hold as it is" do
          error = assert_raises(ArgumentError) { IOStreams.path("caf\xE9.csv".b).to_h }

          assert_includes error.message, "UTF-8"
          assert_raises(ArgumentError) { IOStreams.path("tempfile2527").file_name("caf\xE9.csv".b).to_h }
        end

        it "holds a file name that was cleared" do
          path = IOStreams.path("people.csv.gz")
          path.file_name = nil

          assert_nil restored(path).file_name
        end

        it "does not hold the file name when it is the name of the path" do
          path = IOStreams.path("people.csv.gz")
          path.pipeline

          refute path.to_h.key?("file_name")
        end
      end

      describe "streams" do
        it "holds the options of a stream" do
          path = IOStreams.path("people.csv.gz").option(:gz, level: 9)

          assert_equal({"options" => {"gz" => {"level" => 9}}}, path.to_h["streams"])
          assert_equal({gz: {level: 9}}, restored(path).pipeline)
        end

        it "holds the streams set in place of the file name" do
          path = IOStreams.path("tempfile2527").stream(:gz, level: 2)

          assert_equal({"streams" => {"gz" => {"level" => 2}}}, path.to_h["streams"])
          assert_equal({gz: {level: 2}}, restored(path).pipeline)
        end

        it "holds that every stream was removed, rather than those of the file name" do
          path = IOStreams.path("people.csv.gz")
          path.remove_from_pipeline(:gz)

          assert_equal({}, restored(path).pipeline)
        end

        it "holds the options of the streams that remain once a stream is removed" do
          path = IOStreams.path("people.csv.gz.enc").option(:gz, level: 9)
          path.remove_from_pipeline(:enc)

          assert_equal({gz: {level: 9}}, restored(path).pipeline)
        end

        it "holds that every stream was removed after its options were set" do
          path = IOStreams.path("people.csv.gz").option(:gz, level: 9)
          path.remove_from_pipeline(:gz)

          assert_equal({}, restored(path).pipeline)
        end

        it "holds raw" do
          path = IOStreams.path("people.csv.gz").raw

          assert_equal({"raw" => true}, path.to_h["streams"])
          copy = restored(path)

          assert_predicate copy, :raw?
          assert_equal({}, copy.pipeline)
        end

        it "holds the encoding, an Encoding by its name, and a built-in cleaner by its name" do
          path = IOStreams.path("people.csv").encoding(Encoding::WINDOWS_1252, replace: "?", cleaner: :printable)

          assert_equal({"encoding" => {"encoding" => "Windows-1252", "replace" => "?", "cleaner" => "printable"}},
                       path.to_h["streams"])
          assert_equal({encoding: "Windows-1252", replace: "?", cleaner: "printable"}, restored(path).setting(:encode))
        end

        it "holds a Symbol option as its text, which the stream takes" do
          path = IOStreams.path("people.csv.pgp").option(:pgp, recipient: "receiver@example.org", compress: :none)

          assert_equal({"recipient" => "receiver@example.org", "compress" => "none"},
                       path.to_h.dig("streams", "options", "pgp"))
        end

        it "raises for a sensitive option of a stream" do
          path  = IOStreams.path("people.csv.pgp").option(:pgp, passphrase: "secret")
          error = assert_raises(ArgumentError) { path.to_h }

          assert_includes error.message, "passphrase"
          refute_includes error.message, "secret\""
        end

        it "does not raise for a sensitive option that is nil" do
          path = IOStreams.path("people.csv.pgp").option(:pgp, passphrase: nil)

          assert_equal({"passphrase" => nil}, path.to_h.dig("streams", "options", "pgp"))
        end

        it "raises for a Proc, such as a cleaner" do
          path  = IOStreams.path("people.csv").encoding("UTF-8", cleaner: ->(data, _replace) { data })
          error = assert_raises(ArgumentError) { path.to_h }

          assert_includes error.message, "cleaner"
          assert_includes error.message, "Proc"
        end
      end

      describe "rows" do
        it "holds the format and the options of the rows" do
          path = IOStreams.path("people.txt").format(:psv).option(:parquet, compression: "zstd")

          assert_equal({"format" => "psv", "options" => {"parquet" => {"compression" => "zstd"}}}, path.to_h["rows"])
          copy = restored(path)

          assert_equal :psv, copy.format
          assert_equal({compression: "zstd"}, copy.setting(:parquet))
        end

        it "holds a schema Hash with String keys" do
          path = IOStreams.path("people.txt").schema(fields: [{name: "name", type: "string", width: 5}])

          assert_equal({"fields" => [{"name" => "name", "type" => "string", "width" => 5}]}, path.to_h.dig("rows", "schema"))
        end

        it "reads a schema file once, so the path created again reads by the schema as it was" do
          Utils.temp_file_name("people", ".json") do |schema_file|
            ::File.write(schema_file, JSON.generate(fields: [{name: "age", type: "integer"}]))
            stored = IOStreams.path("people.csv").schema(schema_file).to_h
            ::File.write(schema_file, JSON.generate(fields: [{name: "name", type: "string"}]))

            assert_equal [{"name" => "age", "type" => "integer"}], stored.dig("rows", "schema", "fields")
            assert_equal ["age"], IOStreams.path(stored).infer_schema.fields.map(&:name)
          end
        end

        it "raises what reading a missing schema file raises" do
          path = IOStreams.path("people.csv").schema("does_not_exist.json")

          assert_raises(IOStreams::Errors::NotFound) { path.to_h }
        end

        it "raises for a contract" do
          path  = IOStreams.path("people.csv").as(fields: [{name: "name", type: "string"}])
          error = assert_raises(ArgumentError) { path.to_h }

          assert_includes error.message, "contract"
        end

        it "reads a fixed width file by the schema of the path created again" do
          Utils.temp_file_name("people", ".txt.gz") do |file_name|
            schema = {fields: [{name: "name", type: "string", width: 5}, {name: "age", type: "integer", width: 3}]}
            IOStreams.path(file_name).format(:fixed).schema(schema).writer(:hash) do |io|
              io << {"name" => "Jack", "age" => 21}
            end
            stored = IOStreams.path(file_name).format(:fixed).schema(schema).to_h

            records = []
            IOStreams.path(stored).each(:hash) { |record| records << record }

            assert_equal [{"name" => "Jack", "age" => 21}], records
          end
        end
      end

      describe "an S3 path" do
        it "holds the region in the options of the client, and the options of the query" do
          path = IOStreams.path("s3://bucket/people.csv?acl=bucket-owner-full-control", region: "us-east-1")

          assert_equal(
            {"url" => "s3://bucket/people.csv", "arguments" => {"client" => {"region" => "us-east-1"}, "acl" => "bucket-owner-full-control"}},
            path.to_h
          )
          copy = restored(path)

          assert_equal path, copy
          assert_equal({acl: "bucket-owner-full-control"}, copy.options)
        end

        it "raises for a secret access key" do
          path  = IOStreams.path("s3://bucket/people.csv", access_key_id: "AKIA", secret_access_key: "secret")
          error = assert_raises(ArgumentError) { path.to_h }

          assert_includes error.message, "secret_access_key"
        end

        it "raises for a client object" do
          path  = IOStreams.path("s3://bucket/people.csv", client: Object.new)
          error = assert_raises(ArgumentError) { path.to_h }

          assert_includes error.message, "Aws::S3::Client"
        end
      end

      describe "an SFTP path" do
        it "holds the user name of the url and the ssh options" do
          path = IOStreams.path("sftp://jack@example.org/data/people.csv", ssh_options: {"IdentityFile" => "~/.ssh/id"})

          assert_equal(
            {"url" => "sftp://jack@example.org/data/people.csv", "arguments" => {"ssh_options" => {"IdentityFile" => "~/.ssh/id"}}},
            path.to_h
          )
          copy = restored(path)

          assert_equal "jack", copy.username
          assert_equal({"IdentityFile" => "~/.ssh/id"}, copy.ssh_options)
        end

        it "holds a user name supplied as an argument" do
          path = IOStreams.path("sftp://example.org/people.csv", username: "jack")

          assert_equal({"username" => "jack"}, path.to_h["arguments"])
          assert_equal "jack", restored(path).username
        end

        it "raises for a password in the url, without displaying it" do
          error = assert_raises(ArgumentError) { IOStreams.path("sftp://jack:OpenSesame@example.org/people.csv").to_h }

          assert_includes error.message, "password"
          refute_includes error.message, "OpenSesame"
        end

        it "raises for a password supplied as an argument" do
          path = IOStreams.path("sftp://example.org/people.csv", username: "jack", password: "OpenSesame")

          assert_raises(ArgumentError) { path.to_h }
        end

        it "raises for an identity key in the ssh options" do
          path  = IOStreams.path("sftp://example.org/people.csv", ssh_options: {"IdentityKey" => "-----BEGIN"})
          error = assert_raises(ArgumentError) { path.to_h }

          assert_includes error.message, "IdentityKey"
        end
      end

      describe "a path whose directories are made when the file is written" do
        it "holds mkpath, which the path created again makes" do
          path = IOStreams.path("sftp://example.org/new_dir/people.csv").mkpath

          assert path.to_h["mkpath"]
          assert_predicate restored(path), :mkpath_pending?
        end

        it "does not hold mkpath until it is called" do
          refute IOStreams.path("sftp://example.org/new_dir/people.csv").to_h.key?("mkpath")
        end
      end

      describe "a path of a registered scheme" do
        it "raises when its class does not return its arguments" do
          klass = Class.new(IOStreams::Path) do
            def self.name = "ExamplePath"
          end
          error = assert_raises(ArgumentError) { klass.new("/people.csv").to_h }

          assert_includes error.message, "ExamplePath"
          assert_includes error.message, "stored_arguments"
        end
      end

      describe "an HTTP path" do
        it "holds the arguments that are not their defaults" do
          path = IOStreams.path("https://example.org/people.csv", http_redirect_count: 2, allow_hosts: "example.org",
                                maximum_file_size: 1_000, headers: {"Accept" => "text/csv"})

          assert_equal(
            {
              "url"       => "https://example.org/people.csv",
              "arguments" => {"http_redirect_count" => 2, "allow_hosts" => ["example.org"], "maximum_file_size" => 1_000,
                              "headers" => {"Accept" => "text/csv"}}
            },
            path.to_h
          )
          assert_equal path, restored(path)
        end

        it "raises for the query of the url, which #inspect does not display, and holds it with secrets: true" do
          path  = IOStreams.path("https://example.org/people.csv?X-Amz-Signature=abc123")
          error = assert_raises(ArgumentError) { path.to_h }

          assert_includes error.message, "secrets: true"
          refute_includes error.message, "abc123"
          assert_equal path, IOStreams.path(path.to_h(secrets: true))
        end

        it "holds no headers when none were supplied" do
          assert_equal({"url" => "https://example.org/people.csv"}, IOStreams.path("https://example.org/people.csv").to_h)
        end

        it "raises for parameters, which can hold an access key, and holds them with secrets: true" do
          path  = IOStreams.path("https://example.org/people.csv", parameters: {api_token: "S3cr3t"})
          error = assert_raises(ArgumentError) { path.to_h }

          assert_includes error.message, "parameters"
          refute_includes error.message, "S3cr3t"
          assert_equal path, IOStreams.path(JSON.parse(JSON.generate(path.to_h(secrets: true))))
        end

        it "raises for a password" do
          path = IOStreams.path("https://example.org/people.csv", username: "jack", password: "OpenSesame")

          assert_raises(ArgumentError) { path.to_h }
        end

        it "raises for a header that holds a credential" do
          path  = IOStreams.path("https://example.org/people.csv", headers: {"Authorization" => "Bearer token"})
          error = assert_raises(ArgumentError) { path.to_h }

          assert_includes error.message, "Authorization"
          refute_includes error.message, "Bearer"
        end
      end

      describe "secrets: true" do
        def restored_with_secrets(path)
          IOStreams.path(JSON.parse(JSON.generate(path.to_h(secrets: true))))
        end

        it "holds the password of an SFTP path, which the path created again uses" do
          path = IOStreams.path("sftp://example.org/people.csv", username: "jack", password: "OpenSesame")

          assert_equal(
            {"url" => "sftp://example.org/people.csv", "arguments" => {"username" => "jack", "password" => "OpenSesame"}},
            path.to_h(secrets: true)
          )
          copy = restored_with_secrets(path)

          assert_equal "jack", copy.username
          assert_equal "OpenSesame", copy.to_h(secrets: true).dig("arguments", "password")
        end

        it "creates an SFTP path again whose url holds the password" do
          copy = restored_with_secrets(IOStreams.path("sftp://jack:OpenSesame@example.org/people.csv"))

          assert_equal "jack", copy.username
          assert_equal "OpenSesame", copy.to_h(secrets: true).dig("arguments", "password")
        end

        it "holds the sensitive option of a stream" do
          path = IOStreams.path("people.csv.pgp").option(:pgp, passphrase: "secret")

          assert_equal({"passphrase" => "secret"}, path.to_h(secrets: true).dig("streams", "options", "pgp"))
          assert_equal({passphrase: "secret"}, restored_with_secrets(path).setting(:pgp))
        end

        it "holds the secret access key of an S3 client" do
          path = IOStreams.path("s3://bucket/people.csv", access_key_id: "AKIA", secret_access_key: "secret")

          assert_equal({"client" => {"access_key_id" => "AKIA", "secret_access_key" => "secret"}},
                       path.to_h(secrets: true)["arguments"])
          assert_equal path, restored_with_secrets(path)
        end

        it "holds a header that holds a credential" do
          path = IOStreams.path("https://example.org/people.csv", headers: {"Authorization" => "Bearer token"})

          assert_equal({"headers" => {"Authorization" => "Bearer token"}}, path.to_h(secrets: true)["arguments"])
        end

        it "still raises for a value that JSON does not hold as it is" do
          path = IOStreams.path("s3://bucket/people.csv", client: Object.new)

          assert_raises(ArgumentError) { path.to_h(secrets: true) }
        end

        it "names the option, to store the secret, when it raises without it" do
          error = assert_raises(ArgumentError) { IOStreams.path("people.csv.pgp").option(:pgp, passphrase: "x").to_h }

          assert_includes error.message, "to_h(secrets: true)"
        end
      end

      it "stores a frozen path, such as a root" do
        path = IOStreams.path("/data/people.csv.gz").option(:gz, level: 3).freeze

        assert_equal({gz: {level: 3}}, restored(path).pipeline)
      end
    end

    describe "IOStreams.path(hash)" do
      it "takes Symbol keys" do
        path = IOStreams.path({url: "people.txt", rows: {format: :json}, streams: {options: {gz: {level: 1}}}})

        assert_equal :json, path.format
      end

      it "returns a path that can be changed without changing another" do
        stored = IOStreams.path("people.csv").to_h
        path   = IOStreams.path(stored)
        path.option(:gz, level: 1)

        assert_equal({"url" => "people.csv"}, stored)
      end

      # A Hash that keeps its keys as Strings, as ActiveSupport::HashWithIndifferentAccess does, which is not loaded here,
      # since it changes how other tests write JSON.
      indifferent = Class.new(Hash) do
        def self.from(hash)
          hash.each_with_object(new) { |(key, value), copy| copy[key] = value.is_a?(Hash) ? from(value) : value }
        end

        def []=(key, value)
          super(key.to_s, value)
        end

        def transform_keys(...) = self.class.from(super)
      end

      it "takes a Hash with indifferent access, such as ActiveSupport's" do
        hash = indifferent.from(url: "people.csv.gz", streams: {options: {gz: {level: 1}}})

        assert_equal({gz: {level: 1}}, IOStreams.path(hash).pipeline)
      end

      it "raises for a key named both as a String and as a Symbol" do
        assert_raises(ArgumentError) { IOStreams.path({"url" => "a.csv", url: "b.csv"}) }
      end

      it "raises for a key that a path does not hold" do
        error = assert_raises(ArgumentError) { IOStreams.path({"url" => "people.csv", "_id" => 1}) }

        assert_includes error.message, "_id"
      end

      it "raises without a url" do
        assert_raises(ArgumentError) { IOStreams.path({"rows" => {"format" => "csv"}}) }
      end

      it "raises for a Hash with other elements or arguments" do
        assert_raises(ArgumentError) { IOStreams.path("/data", {"url" => "people.csv"}) }
        assert_raises(ArgumentError) { IOStreams.path({"url" => "people.csv"}, create_path: false) }
      end

      it "checks each setting again" do
        assert_raises(ArgumentError) { IOStreams.path({"url" => "people.csv", "rows" => {"format" => "nope"}}) }
        assert_raises(ArgumentError) do
          IOStreams.path({"url" => "people.csv.gz", "streams" => {"options" => {"gz" => {"unknown" => 1}}}})
        end
        assert_raises(ArgumentError) { IOStreams.path({"url" => "people.csv.gz", "streams" => {"raw" => true, "options" => {"gz" => {}}}}) }
        assert_raises(ArgumentError) { IOStreams.path({"url" => "people.csv", "streams" => {"other" => 1}}) }
        assert_raises(ArgumentError) { IOStreams.path({"url" => "people.csv", "file_name" => 5}) }
        assert_raises(ArgumentError) { IOStreams.path({"url" => "people.csv", "mkpath" => "true"}) }
        assert_raises(ArgumentError) { IOStreams.path({"url" => "people.csv.gz", "streams" => {"raw" => "false"}}) }
      end
    end
  end
end
