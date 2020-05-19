require_relative "test_helper"
require "json"

module IOStreams
  class PathTest < Minitest::Test
    describe IOStreams do
      let :records do
        [
          {"name" => "Jack Jones", "login" => "jjones"},
          {"name" => "Jill Smith", "login" => "jsmith"}
        ]
      end

      let :expected_json do
        records.collect(&:to_json).join("\n") + "\n"
      end

      let :json_file_name do
        "/tmp/iostreams_abc.json"
      end

      describe ".root" do
        it "return default path" do
          path = ::File.expand_path(::File.join(__dir__, "../tmp/default"))
          assert_equal path, IOStreams.root.to_s
        end

        it "return downloads path" do
          path = ::File.expand_path(::File.join(__dir__, "../tmp/downloads"))
          assert_equal path, IOStreams.root(:downloads).to_s
        end
      end

      describe ".join" do
        it "returns path" do
          assert_equal IOStreams.root.to_s, IOStreams.join.to_s
        end

        it "adds path to root" do
          assert_equal ::File.join(IOStreams.root.to_s, "test"), IOStreams.join("test").to_s
        end

        it "adds paths to root" do
          assert_equal ::File.join(IOStreams.root.to_s, "test", "second", "third"), IOStreams.join("test", "second", "third").to_s
        end

        it "returns path and filename" do
          path = ::File.join(IOStreams.root.to_s, "file.xls")
          assert_equal path, IOStreams.join("file.xls").to_s
        end

        it "adds path to root and filename" do
          path = ::File.join(IOStreams.root.to_s, "test", "file.xls")
          assert_equal path, IOStreams.join("test", "file.xls").to_s
        end

        it "adds paths to root" do
          path = ::File.join(IOStreams.root.to_s, "test", "second", "third", "file.xls")
          assert_equal path, IOStreams.join("test", "second", "third", "file.xls").to_s
        end

        it "return path as sent in when full path" do
          path = ::File.join(IOStreams.root.to_s, "file.xls")
          assert_equal path, IOStreams.join(path).to_s
        end
      end

      describe ".path" do
        it "default" do
          path = IOStreams.path("a.xyz")
          assert path.is_a?(IOStreams::Paths::File), path
        end

        it "s3" do
          skip "TODO"
          IOStreams.path("s3://a.xyz")
          assert_equal :s3, path
        end

        it "hash writer detects json format from file name" do
          path = IOStreams.path("/tmp/io_streams/abc.json")
          path.writer(:hash) do |io|
            records.each { |hash| io << hash }
          end
          actual = path.read
          path.delete
          assert_equal expected_json, actual
        end

        it "hash reader detects json format from file name" do
          ::File.open(json_file_name, "wb") { |file| file.write(expected_json) }
          rows = []
          path = IOStreams.path(json_file_name)
          path.each(:hash) do |row|
            rows << row
          end
          actual = rows.collect(&:to_json).join("\n") + "\n"
          path.delete
          assert_equal expected_json, actual
        end

        it "array writer detects json format from file name" do
          path = IOStreams.path("/tmp/io_streams/abc.json")
          path.writer(:array, columns: %w[name login]) do |io|
            io << ["Jack Jones", "jjones"]
            io << ["Jill Smith", "jsmith"]
          end
          actual = path.read
          path.delete
          assert_equal expected_json, actual
        end
      end

      describe ".temp_file" do
        it "returns value from block" do
          result = IOStreams.temp_file("base", ".ext") { |_path| 257 }
          assert_equal 257, result
        end

        it "supplies new temp file_name" do
          path1 = nil
          path2 = nil
          IOStreams.temp_file("base", ".ext") { |path| path1 = path }
          IOStreams.temp_file("base", ".ext") { |path| path2 = path }
          refute_equal path1.to_s, path2.to_s
          assert path1.is_a?(IOStreams::Paths::File), path1
          assert path2.is_a?(IOStreams::Paths::File), path2
        end
      end
    end
  end
end
