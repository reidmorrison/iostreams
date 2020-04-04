require_relative "test_helper"

class UtilsTest < Minitest::Test
  describe IOStreams::Utils do
    describe ".temp_file_name" do
      it "returns value from block" do
        result = IOStreams::Utils.temp_file_name("base", ".ext") { |_name| 257 }
        assert_equal 257, result
      end

      it "supplies new temp file_name" do
        file_name  = nil
        file_name2 = nil
        IOStreams::Utils.temp_file_name("base", ".ext") { |name| file_name = name }
        IOStreams::Utils.temp_file_name("base", ".ext") { |name| file_name2 = name }
        refute_equal file_name, file_name2
      end
    end
  end
end
