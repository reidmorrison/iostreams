# frozen_string_literal: true

require_relative "test_helper"

class InferSampleTest < Minitest::Test
  describe IOStreams::Stream do
    describe "#infer_schema(sample:)" do
      # Returns [IOStreams::Stream] a stream of the text, read as the file name says.
      def text(text, file_name = "orders.csv")
        IOStreams.stream(StringIO.new(text)).file_name(file_name)
      end

      # Returns [Hash] the field of the supplied name in the draft of the text.
      def drafted(csv, name, sample: :all)
        text(csv).infer_schema(sample: sample).to_h[:fields].find { |field| field[:name] == name }
      end

      it "drafts the type of each column of text from its values, with fieldsMatch subset" do
        csv = "ID,Amount,Ordered At,Zip,Paid,Shipped On,Opens\n" \
              "1001,12.50,2026-10-25T09:30:00Z,01234,true,2026-10-25,09:30:00\n" \
              "1002,3.5,2026-10-26T10:00:00-04:00,99999,FALSE,2026-10-26,17:00:00.250\n"

        assert_equal(
          {
            fieldsMatch: "subset",
            fields:      [
              {name: "id", type: "integer"},
              {name: "amount", type: "number", decimals: 2},
              {name: "ordered_at", type: "datetime"},
              {name: "zip", type: "string"},
              {name: "paid", type: "boolean"},
              {name: "shipped_on", type: "date"},
              {name: "opens", type: "time"}
            ]
          },
          text(csv).infer_schema(sample: 1_000).to_h
        )
      end

      it "returns a schema, which reads the file by the types drafted" do
        csv    = "id,amount\n1,12.50\n"
        schema = text(csv).infer_schema(sample: 10)

        assert_instance_of IOStreams::Schema, schema
        records = []
        text(csv).schema(schema).each(:hash) { |record| records << record }

        assert_equal [{"id" => 1, "amount" => BigDecimal("12.5")}], records
      end

      it "keeps text with a leading zero a string, so that 007 and 01234 keep their zeros" do
        assert_equal "string", drafted("zip,code\n01234,007\n", "zip")[:type]
        assert_equal "string", drafted("zip,code\n01234,007\n", "code")[:type]
        assert_equal "integer", drafted("n\n0\n-12\n", "n")[:type]
      end

      it "drafts a number of the integers and numbers of a column, with the most decimals seen" do
        assert_equal({name: "n", type: "number", decimals: 3}, drafted("n\n1\n2.5\n.125\n", "n"))
      end

      it "drafts any for a column without a value, for a person to decide" do
        assert_equal({name: "notes", type: "any"}, drafted("id,notes\n1,\n2,  \n", "notes"))
      end

      it "drafts a string for a column of text with blank values, also null in JSON" do
        assert_equal "string", drafted("x,y\nabc,1\n,2\n", "x")[:type]
        assert_equal "string", text(%({"s":"abc"}\n{"s":null}\n), "orders.json").infer_schema(sample: :all).fields.first.type
      end

      it "drafts only the types that read the sample back, such as booleans of the default text, and real times" do
        assert_equal "boolean", drafted("v\ntrue\nFALSE\nTrue\n", "v")[:type]
        assert_equal "string", drafted("v\ntRuE\n", "v")[:type]
        assert_equal "datetime", drafted("v\n2026-10-25T23:59:59Z\n", "v")[:type]
        assert_equal "string", drafted("v\n2026-10-25T25:00:00\n", "v")[:type]
      end

      it "drafts a string for text of several types, or that is no type" do
        assert_equal "string", drafted("v\n1\n2026-10-25\n", "v")[:type]
        assert_equal "string", drafted("v\n2026-10-25\n2026-10-25T09:30:00Z\n", "v")[:type]
        assert_equal "string", drafted("v\n1e5\n", "v")[:type]
        assert_equal "string", drafted("v\n2026-02-30\n", "v")[:type]
        assert_equal "string", drafted("v\n2026-10-25 09:30:00\n", "v")[:type]
      end

      it "recognizes US dates, recording their format, and dates written day first" do
        assert_equal({name: "on", type: "date", format: "%m/%d/%Y"}, drafted("on\n10/25/2026\n1/5/2026\n", "on"))
        assert_equal({name: "on", type: "date", format: "%d/%m/%Y"}, drafted("on\n25/10/2026\n5/1/2026\n", "on"))
      end

      it "drafts month first for dates that could be either, saying so for the reviewer" do
        field = drafted("on\n01/02/2026\n03/04/2026\n", "on")

        assert_equal "%m/%d/%Y", field[:format]
        assert_includes field[:description], "month or day first"
      end

      it "drafts a string for dates that disagree on which part is the day" do
        assert_equal "string", drafted("on\n10/25/2026\n25/10/2026\n", "on")[:type]
      end

      it "drafts any for each column of a file with only a header row, and no field for a file without lines" do
        assert_equal [{name: "id", type: "any"}, {name: "name", type: "any"}], text("ID,Name\n").infer_schema(sample: 5).to_h[:fields]
        assert_equal [], text("").infer_schema(sample: 5).to_h[:fields]
      end

      it "reads a stream once, so that an IO that is read once is drafted from its header row and values" do
        io = StringIO.new("id\n1\n")

        assert_equal [{name: "id", type: "integer"}], IOStreams.stream(io).file_name("a.csv").infer_schema(sample: 5).to_h[:fields]
      end

      it "reads only the first rows of the sample" do
        assert_equal "integer", drafted("v\n1\n2\nx\n", "v", sample: 2)[:type]
        assert_equal "string", drafted("v\n1\n2\nx\n", "v", sample: 3)[:type]
      end

      it "drafts the keys of every JSON record of the sample, and the type of their values" do
        json = %({"id":1,"amount":12.5,"tags":["a"]}\n{"id":2,"amount":3,"prefs":{"a":1},"on":"2026-10-25"}\n)

        assert_equal [{name: "id", type: "integer"}, {name: "amount", type: "number", decimals: 1},
                      {name: "tags", type: "array"}, {name: "prefs", type: "object"}, {name: "on", type: "date"}],
                     text(json, "orders.json").infer_schema(sample: :all).to_h[:fields]
        assert_equal(%w[id amount tags], text(json, "orders.json").infer_schema.to_h[:fields].map { |field| field[:name] })
      end

      it "drafts any for JSON values of several types that are not all text" do
        assert_equal [{name: "v", type: "any"}], text(%({"v":1}\n{"v":"x"}\n), "orders.json").infer_schema(sample: 5).to_h[:fields]
      end

      it "ignores a contract, drafting what the source holds" do
        contract = IOStreams::Contract.new(fieldsMatch: "partial", fields: [{name: "id", type: "string"}])

        assert_equal [{name: "id", type: "integer"}], text("id\n1\n").as(contract).infer_schema(sample: 5).to_h[:fields]
      end

      it "raises for a sample that is neither a positive Integer nor :all" do
        [0, -1, 1.5, "10", :some, nil.to_a].each do |sample|
          assert_raises(ArgumentError, sample.inspect) { text("id\n1\n").infer_schema(sample: sample) }
        end
      end

      it "raises with a schema, which already gives the types, after checking the sample" do
        stream = text("id\n1\n").schema(fields: [{name: "id"}])

        assert_includes assert_raises(ArgumentError) { stream.infer_schema(sample: 5) }.message, "with a schema"
        assert_includes assert_raises(ArgumentError) { stream.infer_schema(sample: 0) }.message, "positive Integer"
      end

      describe "Parquet" do
        before do
          skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)
        end

        it "returns the schema that the file declares, with fieldsMatch subset, reading no row" do
          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "orders.parquet")
            path.schema(fields: [{name: "id", type: "integer", constraints: {required: true}}]).writer(:hash) { |io| io << {"id" => 1} }

            assert_equal({fieldsMatch: "subset", fields: [{name: "id", type: "integer", constraints: {required: true}}]},
                         IOStreams.path(dir, "orders.parquet").infer_schema(sample: 10).to_h)
          end
        end

        it "drafts a column of type any from its values, opening an IO once, and leaving it to be read" do
          Dir.mktmpdir do |dir|
            file = File.join(dir, "blobs.parquet")
            require "parquet"
            schema = ::Parquet::Schema.define do
              field :id, :int64
              field :blob, :binary
            end
            ::Parquet.write_rows([[1, "abc"], [2, "x"]].each, schema: schema, write_to: file)
            reader, writer = IO.pipe
            writer.binmode
            writer.write(File.binread(file))
            writer.close

            expected = {fieldsMatch: "subset", fields: [{name: "id", type: "integer"}, {name: "blob", type: "string"}]}

            assert_equal expected, IOStreams.stream(reader).file_name("blobs.parquet").infer_schema(sample: 10).to_h
            stream = IOStreams.stream(StringIO.new(File.binread(file))).file_name("blobs.parquet")

            assert_equal expected, stream.infer_schema(sample: 10).to_h
            records = []
            stream.each(:hash) { |record| records << record }

            assert_equal([1, 2], records.map { |record| record["id"] })
          end
        end
      end
    end

    describe "IOStreams::Schema#to_dsl" do
      it "writes the class of the contract of the draft, for a person to review and commit" do
        csv = "ID,Amount,Ordered At,1st\n1001,12.50,2026-10-25T09:30:00Z,x\n"

        assert_equal(<<~RUBY, IOStreams.stream(StringIO.new(csv)).file_name("orders.csv").infer_schema(sample: 10).to_dsl("Order"))
          class Order < IOStreams::Contract
            fields_match "subset"

            field :id,         :integer
            field :amount,     :number,   decimals: 2
            field :ordered_at, :datetime
            field :field_1st,  :string,   name: "1st"
          end
        RUBY
      end

      it "notes the format of a field, which the contract leaves to the schema of the file" do
        dsl = IOStreams.stream(StringIO.new("on\n10/25/2026\n")).file_name("orders.csv").infer_schema(sample: 10).to_dsl("Order")

        assert_includes dsl, '# The schema of the file reads "on" with format "%m/%d/%Y", which this contract leaves to it'
        assert_includes dsl, "field :on, :date\n"
      end
    end
  end
end
