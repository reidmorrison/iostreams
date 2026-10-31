# frozen_string_literal: true

require_relative "query_helper"

# A copy of the rows of an Active Record query, see `IOStreams::Query::Stream`, into a row or record writer that is
# already open, handed to code that copies into `IOStreams.stream(writer)`, on each database of QueryDatabase.
class QueryOpenWriterTest < Minitest::Test
  QueryDatabase.each do |database|
    describe "a copy of #{IOStreams::Query::Stream.name} on #{database.name} into a writer that is already open" do
      let(:db) { database }
      let(:relation) { db.order.order(:id).select(:id, :name, :amount) }
      let(:names) { db.order.order(:id).select(:id, :name) }
      let(:ids) { relation.pluck(:id) }

      before { db.load }

      it "writes the records into a record writer, which writes them with its own settings, rather than the schema of the query" do
        output = StringIO.new
        IOStreams.stream(output).format(:csv).writer(:hash) do |records|
          IOStreams.stream(records).copy_from(relation, mode: :hash)
        end

        assert_equal "id,name,amount\n#{ids[0]},a,12.5\n#{ids[1]},b,3.0\n#{ids[2]},c,100.25\n", output.string
      end

      it "writes the rows into a row writer" do
        output = StringIO.new
        IOStreams.stream(output).format(:csv).writer(:array) do |rows|
          IOStreams.stream(rows).copy_from(names, mode: :array)
        end

        assert_equal "id,name\n#{ids[0]},a\n#{ids[1]},b\n#{ids[2]},c\n", output.string
      end

      it "writes the records of a file and of a query into the same writer" do
        output = StringIO.new
        IOStreams.stream(output).format(:csv).writer(:hash) do |records|
          IOStreams.stream(records).copy_from(IOStreams.stream(StringIO.new("id,name\n9,z\n")), mode: :hash)
          IOStreams.stream(records).copy_from(names, mode: :hash)
        end

        assert_equal "id,name\n9,z\n#{ids[0]},a\n#{ids[1]},b\n#{ids[2]},c\n", output.string
      end

      it "still raises for a schema that the caller sets, which the open writer cannot apply" do
        IOStreams.stream(StringIO.new).writer(:hash) do |records|
          error = assert_raises(ArgumentError) do
            IOStreams.stream(records).schema(fields: [{name: "id"}]).copy_from(relation, mode: :hash)
          end
          assert_match(/\A#format, #schema or #as cannot be applied to the IOStreams::Record::Writer/, error.message)
        end
      end

      it "gives its schema to a line writer that is already open, whose rows the target renders" do
        output = StringIO.new
        IOStreams.stream(output).writer(:line) do |lines|
          IOStreams.stream(lines).format(:csv).copy_from(relation, mode: :hash)
        end

        assert_equal "id,name,amount\n#{ids[0]},a,12.50\n#{ids[1]},b,3.00\n#{ids[2]},c,100.25\n", output.string
      end
    end
  end
end
