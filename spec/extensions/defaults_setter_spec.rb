require_relative "spec_helper"

require 'delegate'

describe "Sequel::Plugins::DefaultsSetter" do
  before do
    @db = db = Sequel.mock
    def db.supports_schema_parsing?() true end
    def db.schema(*) [] end
    db.singleton_class.send(:alias_method, :schema, :schema)
    @c = c = Class.new(Sequel::Model(db[:foo]))
    @c.instance_variable_set(:@db_schema, {:a=>{}, :b=>{}})
    @c.plugin :defaults_setter
    @c.columns :a, :b
    @pr = proc do |x|
      db.define_singleton_method(:schema){|*| [[:id, {:primary_key=>true}], [:a, {:ruby_default => x, :primary_key=>false}], [:b, {:primary_key=>false}]]}
      db.singleton_class.send(:alias_method, :schema, :schema)
      c.dataset = c.dataset; c
    end
  end
  after do
    Sequel.datetime_class = Time
  end

  it "should set default value upon initialization" do
    @pr.call(2).new.a.must_equal 2
  end

  it "should not mark the column as modified" do
    @pr.call(2).new.changed_columns.must_equal []
  end

  it "should not set a default of nil" do
    @pr.call(nil).new.class.default_values.must_equal({})
  end

  it "should set a default of false" do
    @pr.call(false).new.a.must_equal false
  end

  it "should handle Sequel::CURRENT_DATE default by using the current Date" do
    @pr.call(Sequel::CURRENT_DATE).new.a.must_equal Date.today
  end

  it "should handle Sequel::CURRENT_TIMESTAMP default by using the current Time" do
    t = @pr.call(Sequel::CURRENT_TIMESTAMP).new.a
    t.must_be_kind_of(Time)
    (t - Time.now).must_be :<,  1
  end

  it "should not reuse the same default hash for multiple objects" do
    h = {}
    c = @pr.call(h)
    c.new.a.must_equal(h)
    c.new.a.wont_be_same_as c.new.a
    c.default_values[:a].must_be_kind_of Proc
  end

  it "should not reuse the same default array for multiple objects" do
    h = []
    c = @pr.call(h)
    c.new.a.must_equal(h)
    c.new.a.wont_be_same_as c.new.a
    c.default_values[:a].must_be_kind_of Proc
  end

  it "should not reuse the same default hash delegate for multiple objects" do
    h = DelegateClass(Hash).new({})
    c = @pr.call(h)
    c.new.a.must_equal(h)
    c.new.a.wont_be_same_as c.new.a
    c.default_values[:a].must_be_kind_of Proc
  end

  it "should not reuse the same default array delegate for multiple objects" do
    h = DelegateClass(Array).new([])
    c = @pr.call(h)
    c.new.a.must_equal(h)
    c.new.a.wont_be_same_as c.new.a
    c.default_values[:a].must_be_kind_of Proc
  end

  it "should use other object delegates as-is" do
    h = DelegateClass(Integer).new(1)
    c = @pr.call(h)
    c.new.a.must_equal(h)
    c.new.a.object_id.must_equal c.new.a.object_id
    c.default_values[:a].object_id.must_equal h.object_id
  end

  it "should handle :callable_default values in schema in preference to :ruby_default" do
    @db.define_singleton_method(:schema) do |*|
      [[:id, {:primary_key=>true}],
       [:a, {:ruby_default => Time.now, :callable_default=>lambda{Date.today}, :primary_key=>false}]]
    end
    @c.dataset = @c.dataset
    @c.new.a.must_equal Date.today
  end

  it "should handle Sequel::CURRENT_TIMESTAMP default by using the current DateTime if Sequel.datetime_class is DateTime" do
    Sequel.datetime_class = DateTime
    t = @pr.call(Sequel::CURRENT_TIMESTAMP).new.a
    t.must_be_kind_of(DateTime)
    (t - DateTime.now).must_be :<,  1/86400.0
  end

  it "should work correctly with the current_datetime_timestamp extension" do
    @db.autoid = 1
    @db.fetch = {:id=>1}
    @c.dataset = @c.dataset.extension(:current_datetime_timestamp)
    c = @pr.call(Sequel::CURRENT_TIMESTAMP)
    @db.sqls
    o = c.new
    o.a = o.a
    o.save
    @db.sqls.must_equal ["INSERT INTO foo (a) VALUES (CURRENT_TIMESTAMP)", "SELECT * FROM foo WHERE id = 1"]
  end

  it "should cache default values if :cache plugin option is used" do
    @c.plugin :defaults_setter, :cache => true
    @c.default_values[:a] = 'a'
    o = @c.new
    o.a.must_equal 'a'
    o.values[:a].must_equal 'a'
    o.a.must_be_same_as(o.a)
  end

  it "should not cache default values if :cache plugin option is used and there is no default values" do
    @c.plugin :defaults_setter, :cache => true
    o = @c.new
    o.a.must_be_nil
    o.values.must_be_empty
    o.a.must_be_nil
    o.a.must_be_same_as(o.a)
  end

  it "should not override a given value" do
    @pr.call(2)
    @c.new('a'=>3).a.must_equal 3
    @c.new('a'=>nil).a.must_be_nil
  end

  it "should work correctly when subclassing" do
    Class.new(@pr.call(2)).new.a.must_equal 2
  end

  it "should contain the default values in default_values" do
    @pr.call(2).default_values.must_equal(:a=>2)
    @c.default_values.clear
    @pr.call(nil).default_values.must_equal({})
  end

  it "should allow modifications of default values" do
    @pr.call(2)
    @c.default_values[:a] = 3
    @c.new.a.must_equal 3
  end

  it "should allow proc default values" do
    @pr.call(2)
    @c.default_values[:a] = proc{3}
    @c.new.a.must_equal 3
  end

  it "should have procs that set default values set them to nil" do
    @pr.call(2)
    @c.default_values[:a] = proc{nil}
    @c.new.a.must_be_nil
  end

  it "should work in subclasses" do
    @pr.call(2)
    @c.default_values[:a] = proc{1}
    c = Class.new(@c)

    @c.new.a.must_equal 1
    c.new.a.must_equal 1

    c.default_values[:a] = proc{2}
    @c.new.a.must_equal 1
    c.new.a.must_equal 2
  end

  it "should support non-proc/non-method callables" do
    @pr.call(2)
    o = Object.new
    def o.call; 3; end
    @c.default_values[:a] = o
    @c.new.a.must_equal 3
  end

  it "should allow proc default values that depend on other values" do
    @pr.call(2)
    @c.default_values[:a] = proc{ |instance| instance.b * 2 }
    @c.new(b: 5).a.must_equal 10
  end

  it "should set default value upon initialization when plugin loaded without dataset" do
    db = @db
    @c = c = Class.new(Sequel::Model)
    @c.plugin :defaults_setter
    @c.instance_variable_set(:@db_schema, {:a=>{}})
    @c.dataset = @db[:foo]
    @c.columns :a
    proc{|x| db.define_singleton_method(:schema){|*| [[:id, {:primary_key=>true}], [:a, {:ruby_default => x, :primary_key=>false}]]}; c.dataset = c.dataset; c}.call(2).new.a.must_equal 2
  end

  it "should work correctly on a model without a dataset" do
    @pr.call(2)
    c = Class.new(Sequel::Model(@db[:bar]))
    c.plugin :defaults_setter
    c.default_values.must_equal(:a=>2)
  end

  it "should freeze default values when freezing model class" do
    c = Class.new(Sequel::Model(@db[:bar]))
    c.plugin :defaults_setter
    c.freeze
    c.default_values.frozen?.must_equal true
  end
end
