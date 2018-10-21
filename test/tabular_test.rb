require_relative 'test_helper'

class TabularTest < Minitest::Test
  describe IOStreams::Tabular do
    let :format do
      :csv
    end

    let :tabular do
      IOStreams::Tabular.new(columns: ['first_field', 'second', 'third'], format: format)
    end

    describe '#parse_header' do
      it 'parses and sets the csv header' do
        tabular = IOStreams::Tabular.new(format: :csv)
        header  = tabular.parse_header('first field,Second,thirD')
        assert_equal ['first field', 'Second', 'thirD'], header
        assert_equal header, tabular.header.columns
      end
    end

    describe '#cleanse_header!' do
      describe 'cleanses' do
        it 'a csv header' do
          tabular = IOStreams::Tabular.new(columns: ['first field', 'Second', 'thirD'])
          header  = tabular.cleanse_header!
          assert_equal ['first_field', "second", "third"], header
          assert_equal header, tabular.header.columns
        end

        it 'white listed snake cased alphanumeric columns' do
          tabular         = IOStreams::Tabular.new(
            columns:         ['Ard Vark', 'password', 'robot version', '$$$'],
            allowed_columns: %w( ard_vark robot_version )
          )
          expected_header = ['ard_vark', nil, 'robot_version', nil]
          cleansed_header = tabular.cleanse_header!
          assert_equal(expected_header, cleansed_header)
        end
      end

      describe 'allowed_columns' do
        before do
          @allowed_columns = ['first', 'second', 'third', 'fourth', 'fifth']
        end

        it 'passes' do
          tabular = IOStreams::Tabular.new(columns: ['   first ', 'Second', 'thirD   '], allowed_columns: @allowed_columns)
          header  = tabular.cleanse_header!
          assert_equal ['first', 'second', 'third'], header
          assert_equal header, tabular.header.columns
          assert_equal @allowed_columns, tabular.header.allowed_columns
        end

        it 'nils columns not in the whitelist' do
          tabular = IOStreams::Tabular.new(columns: ['   first ', 'Unknown Column', 'thirD   '], allowed_columns: @allowed_columns)
          header  = tabular.cleanse_header!
          assert_equal ['first', nil, 'third'], header
        end

        it 'raises exception for columns not in the whitelist' do
          tabular = IOStreams::Tabular.new(columns: ['   first ', 'Unknown Column', 'thirD   '], allowed_columns: @allowed_columns, skip_unknown: false)
          exc     = assert_raises IOStreams::Errors::InvalidHeader do
            tabular.cleanse_header!
          end
          assert_equal 'Unknown columns after cleansing: Unknown Column', exc.message
        end

        it 'raises exception missing required columns' do
          required = ['first', 'second', 'fifth']
          tabular  = IOStreams::Tabular.new(columns: ['   first ', 'Second', 'thirD   '], allowed_columns: @allowed_columns, required_columns: required)
          exc      = assert_raises IOStreams::Errors::InvalidHeader do
            tabular.cleanse_header!
          end
          assert_equal 'Missing columns after cleansing: fifth', exc.message
        end

        it 'raises exception when no columns left' do
          tabular = IOStreams::Tabular.new(columns: ['one', 'two', 'three'], allowed_columns: @allowed_columns)
          exc     = assert_raises IOStreams::Errors::InvalidHeader do
            tabular.cleanse_header!
          end
          assert_equal 'All columns are unknown after cleansing: one,two,three', exc.message
        end
      end
    end

    describe '#record_parse' do
      describe ':array format' do
        let :format do
          :array
        end

        it 'renders' do
          assert hash = tabular.record_parse([1, 2, 3])
          assert_equal({'first_field' => 1, 'second' => 2, 'third' => 3}, hash)
        end
      end

      it 'format :csv' do
        assert hash = tabular.record_parse('1,2,3')
        assert_equal({'first_field' => '1', 'second' => '2', 'third' => '3'}, hash)
      end

      describe ':hash format' do
        let :format do
          :hash
        end

        it 'renders' do
          assert hash = tabular.record_parse('first_field' => 1, 'second' => 2, 'third' => 3)
          assert_equal({'first_field' => 1, 'second' => 2, 'third' => 3}, hash)
        end
      end

      describe ':json format' do
        let :format do
          :json
        end

        it 'renders' do
          assert hash = tabular.record_parse('{"first_field":1,"second":2,"third":3}')
          assert_equal({'first_field' => 1, 'second' => 2, 'third' => 3}, hash)
        end
      end

      describe ':psv format' do
        let :format do
          :psv
        end

        it 'renders' do
          assert hash = tabular.record_parse('1|2|3')
          assert_equal({'first_field' => '1', 'second' => '2', 'third' => '3'}, hash)
        end
      end

      describe ':fixed format' do
        let :tabular do
          layout = [
            {key: 'name', size: 23},
            {key: 'address', size: 40},
            {key: 'zip', size: 5}
          ]
          IOStreams::Tabular.new(format: :fixed, format_options: {layout: layout})
        end

        it 'parses to hash' do
          assert hash = tabular.record_parse('Jack                   over there                              34618')
          assert_equal({'name' => 'Jack', 'address' => 'over there', 'zip' => '34618'}, hash)
        end

        it 'parses short string' do
          # TODO: Raise exception on lines that are too short?
          assert hash = tabular.record_parse('Jack                   over th')
          assert_equal({'name' => 'Jack', 'address' => 'over th', 'zip' => ''}, hash)
        end

        it 'parses longer string' do
          # TODO: Raise exception on lines that are too long?
          assert hash = tabular.record_parse('Jack                   over there                              34618........................................')
          assert_equal({'name' => 'Jack', 'address' => 'over there', 'zip' => '34618'}, hash)
        end

        it 'parses empty strings' do
          assert hash = tabular.record_parse('                                                               34618')
          assert_equal({'name' => '', 'address' => '', 'zip' => '34618'}, hash)
        end

        it 'parses nil data as nil' do
          refute tabular.record_parse(nil)
        end

        it 'parses empty string as nil' do
          refute tabular.record_parse('')
        end
      end

      it 'skips columns not in the whitelist' do
        tabular.header.allowed_columns = ['first', 'second', 'third', 'fourth', 'fifth']
        tabular.cleanse_header!
        assert hash = tabular.record_parse('1,2,3')
        assert_equal({'second' => '2', 'third' => '3'}, hash)
      end

      it 'handles missing values' do
        assert hash = tabular.record_parse('1,2')
        assert_equal({'first_field' => '1', 'second' => '2', 'third' => nil}, hash)
      end
    end

    describe '#render' do
      it 'renders an array of values' do
        assert csv_string = tabular.render([5, 6, 9])
        assert_equal '5,6,9', csv_string
      end

      it 'renders a hash' do
        assert csv_string = tabular.render({'third' => '3', 'first_field' => '1'})
        assert_equal '1,,3', csv_string
      end

      it 'renders a hash including nil and boolean' do
        assert csv_string = tabular.render({'third' => true, 'first_field' => false, 'second' => nil})
        assert_equal 'false,,true', csv_string
      end

      describe ':psv format' do
        let :format do
          :psv
        end

        it 'renders psv nil and boolean' do
          assert psv_string = tabular.render({'third' => true, 'first_field' => false, 'second' => nil})
          assert_equal 'false||true', psv_string
        end

        it 'renders psv numeric and pipe data' do
          assert psv_string = tabular.render({'third' => 23, 'first_field' => 'a|b|c', 'second' => '|'})
          assert_equal 'a:b:c|:|23', psv_string
        end
      end

      describe ':fixed format' do
        let :tabular do
          layout = [
            {key: 'name', size: 23},
            {key: 'address', size: 40},
            {key: 'zip', size: 5}
          ]
          IOStreams::Tabular.new(format: :fixed, format_options: {layout: layout})
        end

        it 'renders fixed data' do
          assert string = tabular.render({'name' => 'Jack', 'address' => 'over there', 'zip' => 34618, 'phone' => '5551231234'})
          assert_equal 'Jack                   over there                              34618', string
        end

        it 'truncates long data' do
          assert string = tabular.render({'name' => 'Jack', 'address' => 'over there', 'zip' => 3461832653653265, 'phone' => '5551231234'})
          assert_equal 'Jack                   over there                              34618', string
        end

        it 'renders nil as empty string' do
          assert string = tabular.render('zip' => 3461832653653265)
          assert_equal '                                                               34618', string
        end

        it 'renders boolean' do
          assert string = tabular.render({'name' => true, 'address' => false, 'zip' => nil, 'phone' => '5551231234'})
          assert_equal 'true                   false                                        ', string
        end

        it 'renders no data as nil' do
          refute tabular.render({})
        end
      end
    end
  end
end
