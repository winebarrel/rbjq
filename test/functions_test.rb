# frozen_string_literal: true

require_relative 'test_helper'

# jq functions implemented in Ruby (Rbjq.compile(functions:) and
# Rbjq.define_function)
class FunctionsTest < Minitest::Test
  def teardown
    %w[double add_n greet].each { |n| Rbjq.undefine_function(n) }
  end

  def test_program_functions
    fns = { 'double' => ->(x) { x * 2 }, 'add_n' => ->(x, n) { x + n } }

    assert_equal [2, 4, 11, 12], Rbjq.query([1, 2], '(.[] | double), (.[] | add_n(10))', functions: fns)
  end

  def test_arguments_are_evaluated_values
    calls = []
    fns = { 'pair' => lambda { |x, a, b|
      calls << [x, a, b]
      [a, b]
    } }

    # like jq's `def pair($a; $b)`: the first argument varies slowest
    assert_equal [[1, 3], [1, 4], [2, 3], [2, 4]], Rbjq.query(0, 'pair(1, 2; 3, 4)', functions: fns)
    assert_equal 4, calls.size
    assert_equal [{ 'a' => 1 }], Rbjq.query({ 'a' => 1 }, 'id(.)', functions: { 'id' => ->(_, v) { v } })
  end

  def test_argument_order_matches_jq_value_parameters
    fns = { 'f' => ->(_, a, b) { [a, b] } }

    assert_equal Rbjq.query(0, 'def g($a; $b): [$a, $b]; [g(1,2; 10,20)]'),
                 Rbjq.query(0, '[f(1,2; 10,20)]', functions: fns)
  end

  def test_values_cannot_be_mutated
    mut = { 'mut' => lambda { |x|
      x['z'] = 1
      x
    } }
    push = { 'push' => lambda { |_, a|
      a << 2
      a
    } }

    assert_raises(FrozenError) { Rbjq.query({ 'a' => 1 }, '. as $o | mut | $o', functions: mut) }
    assert_raises(FrozenError) { Rbjq.query({ 'a' => [1] }, 'push(.a)', functions: push) }
    assert_raises(FrozenError) { Rbjq.query('s', 'up', functions: { 'up' => lambda(&:upcase!) }) }
    # the caller's data is not frozen
    data = { 'a' => [1] }
    Rbjq.query(data, 'id', functions: { 'id' => ->(x) { x } })

    refute_predicate data, :frozen?
    refute_predicate data['a'], :frozen?
    # returning a modified copy is fine
    assert_equal [{ 'a' => 1, 'z' => 1 }], Rbjq.query({ 'a' => 1 }, 'add_z', functions: { 'add_z' => lambda { |x|
      x.merge('z' => 1)
    } })
  end

  def test_global_functions
    assert_equal 'double/0', Rbjq.define_function('double') { |x| x * 2 }
    Rbjq.define_function('greet', ->(name, greeting) { "#{greeting}, #{name}" })

    assert_equal [6, 'hi, bob'], Rbjq.query(3, 'double, ("bob" | greet("hi"))')
    assert Rbjq.undefine_function('greet')
    refute Rbjq.undefine_function('greet')
    assert_raises(Rbjq::CompileError) { Rbjq.compile('"bob" | greet("hi")') }
  end

  def test_undefine_by_arity
    Rbjq.define_function('add_n') { |x, n| x + n }
    Rbjq.define_function('add_n/0') { |x| x + 1 }

    assert Rbjq.undefine_function('add_n/1')
    assert_equal [2], Rbjq.query(1, 'add_n')
    assert_raises(Rbjq::CompileError) { Rbjq.compile('add_n(1)') }
  end

  def test_callable_without_arity
    callable = Object.new
    def callable.call(input) = input * 3

    assert_raises(ArgumentError) { Rbjq.compile('.', functions: { 'triple' => callable }) }
    assert_equal [6], Rbjq.query(2, 'triple', functions: { 'triple/0' => callable })
  end

  def test_global_functions_are_captured_at_compile_time
    Rbjq.define_function('double') { |x| x * 2 }
    prog = Rbjq.compile('double')
    Rbjq.define_function('double') { |x| x * 3 }

    assert_equal [4], prog.run(2)
    assert_equal [6], Rbjq.query(2, 'double')
  end

  def test_precedence
    Rbjq.define_function('double') { |x| x * 2 }

    # program functions over global ones, jq definitions over both
    assert_equal [20], Rbjq.query(2, 'double', functions: { 'double' => ->(x) { x * 10 } })
    assert_equal [0], Rbjq.query(2, 'def double: 0; double', functions: { 'double' => ->(x) { x * 10 } })
    # Ruby functions over builtins
    assert_equal [42], Rbjq.query('abc', 'length', functions: { 'length' => ->(_) { 42 } })
  end

  def test_errors
    fns = { 'oops' => ->(_) { raise Rbjq::JQError, 'bad' }, 'boom' => ->(_) { raise 'boom' } }

    assert_equal ['bad'], Rbjq.query(nil, 'try oops catch .', functions: fns)
    assert_raises(Rbjq::JQError) { Rbjq.query(nil, 'oops', functions: fns) }
    assert_raises(RuntimeError) { Rbjq.query(nil, 'try boom catch .', functions: fns) }
  end

  def test_return_values_are_converted
    fns = { 'obj' => ->(_) { { a: [:b, 1.0] } } }

    assert_equal [{ 'a' => ['b', 1] }], Rbjq.query(nil, 'obj', functions: fns)
  end

  def test_explicit_arity
    assert_equal [2], Rbjq.query(nil, 'count(1; 2)', functions: { 'count/2' => ->(_, *args) { args.size } })
    # any object responding to #call; a Method's arity is used as for a lambda
    assert_equal [3], Rbjq.query(2, 'plus_one', functions: { 'plus_one' => 1.method(:+) })
  end

  def test_not_a_path_expression
    fns = { 'double' => ->(x) { x * 2 } }

    assert_raises(Rbjq::JQError) { Rbjq.query(1, 'path(double)', functions: fns) }
  end

  def test_invalid_definitions
    assert_raises(ArgumentError) { Rbjq.compile('.', functions: { 'f' => ->(*) {} }) }
    assert_raises(ArgumentError) { Rbjq.compile('.', functions: { 'f' => -> {} }) }
    assert_raises(ArgumentError) { Rbjq.compile('.', functions: { 'not-a-name' => ->(x) { x } }) }
    assert_raises(ArgumentError) { Rbjq.compile('.', functions: { 'f/x' => ->(x) { x } }) }
    assert_raises(ArgumentError) { Rbjq.compile('.', functions: { 'f' => 1 }) }
  end
end
