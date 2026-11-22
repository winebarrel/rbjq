# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'
require 'rbjq/cli'

class RbjqTest < Minitest::Test
  def q(filter, input = nil, **)
    Rbjq.query(input, filter, **)
  end

  def test_query_with_ruby_values
    assert_equal [1, 2], q('.a[]', { 'a' => [1, 2] })
    assert_equal [1], q('.a', { a: 1 }) # symbol keys are converted
  end

  def test_vars
    assert_equal [[1, 'x']], q('[.n, $s]', { 'n' => 1 }, vars: { s: 'x' })
  end

  def test_query_json
    assert_equal [2, 4], Rbjq.query_json('1 2', '. * 2')
  end

  def test_compile_errors
    assert_raises(Rbjq::CompileError) { Rbjq.compile('[1,') }
    assert_raises(Rbjq::CompileError) { Rbjq.compile('undefined_fn') }
    assert_raises(Rbjq::CompileError) { Rbjq.compile('$nope') }
    assert_raises(Rbjq::CompileError) { Rbjq.compile('break $nope') }
  end

  def test_runtime_error_value
    e = assert_raises(Rbjq::JQError) { q('error({a: 1})') }
    assert_equal({ 'a' => 1 }, e.value)
    e = assert_raises(Rbjq::JQError) { q('.a', 1) }
    assert_equal 'Cannot index number with string ("a")', e.message
  end

  def test_try_does_not_catch_downstream_errors
    assert_raises(Rbjq::JQError) { q('(try 1) | error("x")') }
    assert_equal ['x'], q('try ((try 1) | error("x")) catch .')
  end

  def test_deep_recursion_is_linear_in_stack
    assert_equal [6765], q('def fib: if . < 2 then . else (. - 1 | fib) + (. - 2 | fib) end; 20 | fib')
  end

  # like jq without decNumber, numbers are IEEE 754 doubles
  def test_large_integers_are_doubles
    assert_equal '12345678901234567000', Rbjq.dump_json(q('.', Rbjq.parse_json('12345678901234567890')).first)
    assert_equal(['9007199254740992'], q('9007199254740993').map { |v| Rbjq.dump_json(v) })
    assert_equal [false], q('have_decnum')
  end

  def test_number_formatting
    {
      1.5 => '1.5', 1e100 => '1e+100', 1e-5 => '1e-05', 0.0001 => '0.0001', 1e17 => '1e+17',
      Float::INFINITY => '1.7976931348623157e+308', Float::NAN => 'null', -0.0 => '-0'
    }.each do |n, s|
      assert_equal s, Rbjq::Encoder.format_number(n)
    end
  end

  def test_inputs
    prog = Rbjq.compile('[., input]')

    assert_equal [[1, 2]], prog.run(1, inputs: [2, 3])
    assert_equal [[1, 2, 3]], Rbjq.compile('[inputs]').run(nil, inputs: [1, 2, 3])
  end

  def test_regex
    assert_equal ['-a--c-'], q('gsub("b*"; "-")', 'abc')
    assert_equal [{ 'x' => 'a', 'y' => '1' }], q('capture("(?<x>[a-z])(?<y>\\\\d)")', 'a1')
    assert_equal [%w[x 1]], q('[match("(?<n>x)(\\\\d)").captures[].string]', 'x1')
    assert_equal [false], q('test("^b")', "a\nb")
  end

  def test_paths_and_assignment
    assert_equal [{ 'a' => [1, 20, 30] }], q('.a[1:] |= map(. * 10)', { 'a' => [1, 2, 3] })
    assert_equal [[1, 3]], q('del(.[] | select(. == 2))', [1, 2, 3])
    assert_equal [{ 'a' => {} }], q('.a.b |= empty', { 'a' => { 'b' => 1 } })
    assert_equal [{ 'b' => { 'c' => 2 } }], q('pick(.b.c)', { 'a' => 1, 'b' => { 'c' => 2, 'd' => 3 } })
  end

  Point = Struct.new(:x, :y)

  def test_ruby_values_are_converted
    assert_equal [{ 'x' => 1, 'y' => 'a' }], q('.', Point.new(1, :a))
    assert_equal [[1, 2]], q('.', 1..2)
    assert_equal ['2024-01-02'], q('.', Date.new(2024, 1, 2))
    assert_equal [1], q('.', 1.0)
    assert_equal [9_007_199_254_740_992.0], q('.', 9_007_199_254_740_993)
  end

  def test_scrub_utf8_like_jq
    assert_equal 'a�b', Rbjq::Value.scrub_utf8("a\xFFb")
    assert_equal '�x', Rbjq::Value.scrub_utf8("\xE3\x81x")
    assert_equal 'é�', Rbjq::Value.scrub_utf8("é\xE3\x81")
    assert_equal 'é', Rbjq::Value.scrub_utf8('é'.b)
  end

  def test_syntax_errors
    ['def', 'def f(1): 1;', '1 == 2 == 3', '{(1):2}', '. as [] | 1', '"\\q"', '"\\(1', '"abc',
     '{@base64: 1}', '[1,2', '1 +', 'reduce . as $x', 'if 1 then 2', '%'].each do |src|
      assert_raises(Rbjq::CompileError, src) { Rbjq.compile(src) }
    end
    assert_equal [nil], q('')
  end

  def test_unsupported_modules
    assert_raises(Rbjq::CompileError) { Rbjq.compile('import "a" as a; .') }
    assert_raises(Rbjq::CompileError) { Rbjq.compile('include "a"; .') }
  end

  def test_limit_is_lazy
    assert_equal [[0, 1, 2]], q('[limit(3; range(1e9))]')
    assert_equal [[2, 10, 2, 10]], q('[limit(4; 1 | repeat(. * 2, 10))]') # same as jq 1.7.1
  end

  def test_binop_operands_stay_lazy
    assert_equal [[0, 1, 2]], q('[limit(3; 0 + range(1e9))]')
    assert_equal [2], q('first(1 + (1, error("x")))')
    assert_equal [2], q('label $o | 1 + (1, break $o, 3)')
    assert_equal [[1], [7, 8]], Rbjq.compile('[limit(1; 0 + (1, input))], [inputs]').run(nil, inputs: [7, 8])
    assert_equal [2], q('def f: 1, error("y"); first(1 + f)')
    assert_equal [[11, 'z']], q('def f: 1, error("z"); [try (10 + f) catch .]')
    assert_equal [[2, 3, 3, 4]], q('def f: 1, 2; [(f) + (f)]')
    assert_equal [11, 12], q('def f: 1, 2; label $o | 10 + f, break $o')
    assert_equal [[11], [7, 8]],
                 Rbjq.compile('def f: (1, input); [limit(1; 10 + f)], [inputs]').run(nil, inputs: [7, 8])
    assert_equal [0], q('def g: range(1e9); first(0 + g)')
  end

  def test_recursive_sum_uses_linear_stack
    tree = (1..12).reduce(1) { |t, _| [t, t] }

    assert_equal [4096], q('def s: if type == "array" then (.[0] | s) + (.[1] | s) else . end; s', tree)
  end

  def test_large_integer_arithmetic_uses_doubles
    big = Rbjq.parse_json('9007199254740993')

    {
      '. + 1' => '9007199254740992', '. - 1' => '9007199254740991', '. + 2 - 2' => '9007199254740992',
      '. % 7' => '4', '. * 1' => '9007199254740992'
    }.each do |f, expected|
      assert_equal [expected], q(f, big).map { |v| Rbjq.dump_json(v) }, f
    end
    assert_equal [0], q('100000000000000000000000000001 | . % 7')
  end

  def cli(args, stdin = '')
    out = StringIO.new
    err = StringIO.new
    status = Rbjq::CLI.start(args, stdin: StringIO.new(stdin), stdout: out, stderr: err)
    [status, out.string, err.string]
  end

  def test_cli_pretty
    status, out, = cli(['.'], '{"a":[1,{"b":null}]}')

    assert_equal 0, status
    assert_equal "{\n  \"a\": [\n    1,\n    {\n      \"b\": null\n    }\n  ]\n}\n", out
  end

  def test_cli_options
    assert_equal "a\nb\n", cli(['-r', '.[]'], '["a","b"]')[1]
    assert_equal "[1,2]\n", cli(['-cs', '.'], '1 2')[1]
    assert_equal "\"x\"\n", cli(['-n', '--arg', 'v', 'x', '$v'])[1]
    assert_equal "{\"a\":1}\n", cli(['-nc', '--argjson', 'v', '{"a":1}', '$v'])[1]
    assert_equal "[\"p\",\"q\"]\n", cli(['-nc', '$ARGS.positional', '--args', 'p', 'q'])[1]
    assert_equal "\"l1\"\n\"l2\"\n", cli(['-R', '.'], "l1\nl2\n")[1]
    assert_equal "{\"a\":1,\"b\":2}\n", cli(['-Sc', '.'], '{"b":2,"a":1}')[1]
  end

  def test_cli_held_back_operand_output_survives_halt
    assert_equal [0, "11\n", ''], cli(['-n', 'def f: 1, halt; 10 + f'])
    assert_equal [5, "11\n", ''], cli(['-n', 'def f: 1, halt_error; 10 + f'])
    assert_equal [1, "11\n", "bye\n"], cli(['-n', 'def f: 1, ("bye\n" | halt_error(1)); 10 + f'])
  end

  def test_cli_negative_number_filter
    assert_equal "-1\n", cli(['-n', '-1'])[1]
    assert_equal "-1\n", cli(['-n', '-10 % 3'])[1]
    assert_equal "5\n", cli(['-5 | abs'], '0')[1]
    assert_equal 2, cli(['-x', '.'])[0]
  end

  def test_cli_halt_error_null_prints_nothing
    status, out, err = cli(['-n', 'halt_error'])

    assert_equal [5, '', ''], [status, out, err]
  end

  def test_cli_input_line_number
    assert_equal "1\n1\n1\n", cli(['input_line_number'], "1 2\n3")[1]
    assert_equal "1\n4\n", cli(['input_line_number'], "{\"a\":1}\n\n\n{\"b\":2}\n")[1]
    assert_equal "1\n2\n", cli(['-R', 'input_line_number'], "a\nb\n")[1]
  end

  def test_cli_error_location
    assert_equal "rbjq: error (at <stdin>:2): Cannot index number with string (\"a\")\n",
                 cli(['.a'], "{}\n1\n")[2]
    assert_match(/\(at <unknown>\)/, cli(['-n', '1 | .a'])[2])
  end

  def test_cli_stack_overflow_is_reported
    status, _, err = cli(['-n', 'def f: if . == 0 then 0 else (. - 1 | f) end; 1000000 | f'])

    assert_equal 5, status
    assert_match(/stack overflow/, err)
  end

  def test_cli_exit_status
    assert_equal 1, cli(['-e', '.'], 'null')[0]
    assert_equal 4, cli(['-e', 'empty'], 'null')[0]
    assert_equal 5, cli(['error("x")'], 'null')[0]
    assert_equal 3, cli(['[1,'], 'null')[0]
    assert_equal 5, cli(['.'], '{bad')[0] # jq 1.8: invalid input is exit status 5
  end
end
