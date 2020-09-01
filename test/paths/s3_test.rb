require_relative "../test_helper"

module Paths
  class S3Test < Minitest::Test
    describe IOStreams::Paths::S3 do
      before do
        skip "Supply 'S3_BUCKET_NAME' environment variable with S3 bucket name to test S3 paths" unless ENV["S3_BUCKET_NAME"]
      end

      let :file_name do
        File.join(File.dirname(__FILE__), "..", "files", "text file.txt")
      end

      let :raw do
        File.read(file_name)
      end

      let(:root_path) { IOStreams::Paths::S3.new("s3://#{ENV['S3_BUCKET_NAME']}/iostreams_test") }

      let :existing_path do
        path = root_path.join("test.txt")
        path.write(raw) unless path.exist?
        path
      end

      let :missing_path do
        root_path.join("unknown.txt")
      end

      let :write_path do
        root_path.join("writer_test.txt").delete
      end

      describe "#delete" do
        it "existing file" do
          assert existing_path.delete.is_a?(IOStreams::Paths::S3)
        end

        it "missing file" do
          assert missing_path.delete.is_a?(IOStreams::Paths::S3)
        end
      end

      describe "#exist?" do
        it "existing file" do
          assert existing_path.exist?
        end

        it "missing file" do
          refute missing_path.exist?
        end
      end

      describe "#mkpath" do
        it "returns self for non-existant path" do
          assert existing_path.mkpath.is_a?(IOStreams::Paths::S3)
        end

        it "checks for lack of existence" do
          assert missing_path.mkpath.is_a?(IOStreams::Paths::S3)
        end
      end

      describe "#mkdir" do
        it "returns self for non-existant path" do
          assert existing_path.mkdir.is_a?(IOStreams::Paths::S3)
        end

        it "checks for lack of existence" do
          assert missing_path.mkdir.is_a?(IOStreams::Paths::S3)
        end
      end

      describe "#reader" do
        it "reads" do
          assert_equal raw, existing_path.read
        end
      end

      describe "#size" do
        it "existing file" do
          assert_equal raw.size, existing_path.size
        end

        it "missing file" do
          assert_nil missing_path.size
        end
      end

      describe "#writer" do
        it "writes" do
          assert_equal(raw.size, write_path.writer { |io| io.write(raw) })
          assert write_path.exist?
          assert_equal raw, write_path.read
        end
      end

      describe "#each_line" do
        it "reads line by line" do
          lines = []
          existing_path.each(:line) { |line| lines << line }
          assert_equal raw.lines.collect(&:chomp), lines
        end
      end

      describe "#each_child" do
        # TODO: case_sensitive: false, directories: false, hidden: false
        let(:abd_file_names) { %w[abd/test1.txt abd/test5.file abd/extra/file.csv] }
        let(:files_for_test) { abd_file_names + %w[xyz/test2.csv xyz/another.csv] }

        let :each_root do
          root_path.join("each_child_test")
        end

        let :multiple_paths do
          files_for_test.collect { |file_name| each_root.join(file_name) }
        end

        let :write_raw_data do
          multiple_paths.each { |path| path.write(raw) unless path.exist? }
        end

        it "existing file returns just the file itself" do
          # Glorified exists call
          existing_path
          assert_equal root_path.join("test.txt").to_s, root_path.children("test.txt").first.to_s
        end

        it "missing file does nothing" do
          # Glorified exists call
          assert_equal [], missing_path.children("readme").collect(&:to_s)
        end

        it "returns all the children" do
          write_raw_data
          assert_equal multiple_paths.collect(&:to_s).sort, each_root.children("**/*").collect(&:to_s).sort
        end

        it "returns all the children under a sub-dir" do
          write_raw_data
          expected = %w[abd/test1.txt abd/test5.file].collect { |file_name| each_root.join(file_name) }
          assert_equal expected.collect(&:to_s).sort, each_root.children("abd/*").collect(&:to_s).sort
        end

        it "missing path" do
          count = 0
          missing_path.each_child { |_| count += 1 }
          assert_equal 0, count
        end

        # Test is here since all the test artifacts have been created already in S3.
        describe "IOStreams.each_child" do
          it "returns all the children" do
            write_raw_data
            children = []
            IOStreams.each_child(each_root.join("**/*").to_s) { |child| children << child }
            assert_equal multiple_paths.collect(&:to_s).sort, children.collect(&:to_s).sort
          end
        end
      end

      describe "#move_to" do
        it "moves existing file" do
          source = root_path.join("move_test_source.txt")
          begin
            source.write("Hello World")
            target   = source.directory.join("move_test_target.txt")
            response = source.move_to(target)
            assert_equal target, response
            assert target.exist?
            refute source.exist?
            assert_equal "Hello World", response.read
            assert_equal target.to_s, response.to_s
          ensure
            source&.delete
            target&.delete
          end
        end

        it "missing source file" do
          source = root_path.join("move_test_source.txt")
          refute source.exist?
          begin
            target = source.directory.join("move_test_target.txt")
            assert_raises Aws::S3::Errors::NoSuchKey do
              source.move_to(target)
            end
            refute target.exist?
          ensure
            source&.delete
            target&.delete
          end
        end

        it "missing target directories" do
          source = root_path.join("move_test_source.txt")
          begin
            source.write("Hello World")
            target   = source.directory.join("a/b/c/move_test_target.txt")
            response = source.move_to(target)
            assert_equal target, response
            assert target.exist?
            refute source.exist?
            assert_equal "Hello World", response.read
            assert_equal target.to_s, response.to_s
          ensure
            source&.delete
            target&.delete
          end
        end
      end

      describe "#partial_files_visible?" do
        it "visible only after upload" do
          refute root_path.partial_files_visible?
        end
      end
    end
  end
end
