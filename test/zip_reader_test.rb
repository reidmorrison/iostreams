require_relative "test_helper"
require_relative "minimal_file_reader"
require "zip"

class ZipReaderTest < Minitest::Test
  describe IOStreams::Zip::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "text.zip")
    end

    let :multiple_zip_file_name do
      File.join(File.dirname(__FILE__), "files", "multiple_files.zip")
    end

    let :csv_zip_file_name do
      'https://www5.fdic.gov/idasp/Offices2.zip'
    end

    let :contents_test_txt do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    let :contents_test_json do
      File.read(File.join(File.dirname(__FILE__), "files", "test.json"))
    end

    let :decompressed do
      Zip::File.open(file_name) { |zip_file| zip_file.first.get_input_stream.read }
    end

    describe ".file" do
      it "reads the first file" do
        result = IOStreams::Zip::Reader.file(file_name, &:read)
        assert_equal decompressed, result
      end

      it "reads entry within zip file" do
        result = IOStreams::Zip::Reader.file(multiple_zip_file_name, entry_file_name: "text.txt", &:read)
        assert_equal contents_test_txt, result
      end

      it "reads another entry within zip file" do
        result = IOStreams::Zip::Reader.file(multiple_zip_file_name, entry_file_name: "test.json", &:read)
        assert_equal contents_test_json, result
      end

      it "parses CSV which is inside a zip" do        
        IOStreams.path(csv_zip_file_name).option(:zip, entry_file_name: 'OFFICES2_ALL.CSV').reader do |io|
          csv    = ::CSV.new(io, headers: true)
          row = csv.first
          assert Date.parse(row['RUNDATE'])
        end
      end

      # it 'reads from a stream' do
      #   result = MinimalFileReader.open(file_name) do |file|
      #     IOStreams::Zip::Reader.stream(file) do |io|
      #       io.read
      #     end
      #   end
      #   assert_equal decompressed, result
      # end
    end
  end
end
