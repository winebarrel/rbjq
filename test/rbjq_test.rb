# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'
require 'rbjq/cli'

class RbjqTest < Minitest::Test
  def q(filter, input = nil, **opts)
    Rbjq.query(input, filter, **opts)
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
    assert_equal 'Cannot index number with string "a"', e.message
  end

  def test_try_does_not_catch_downstream_errors
    assert_raises(Rbjq::JQError) { q('(try 1) | error("x")') }
    assert_equal ['x'], q('try ((try 1) | error("x")) catch .')
  end

  def test_deep_recursion_is_linear_in_stack
    assert_equal [6765], q('def fib: if . < 2 then . else (. - 1 | fib) + (. - 2 | fib) end; 20 | fib')
  end

  def test_large_integers_are_preserved
    assert_equal '12345678901234567890', Rbjq.dump_json(q('.', Rbjq.parse_json('12345678901234567890')).first)
    assert_equal ['9007199254740992'], q('9007199254740993 + 0').map { |v| Rbjq.dump_json(v) }
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

  def test_limit_is_lazy
    assert_equal [[0, 1, 2]], q('[limit(3; range(1e9))]')
    assert_equal [[1, 2, 4, 8]], q('[limit(4; 1 | repeat(. * 2))]')
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

  def test_cli_exit_status
    assert_equal 1, cli(['-e', '.'], 'null')[0]
    assert_equal 4, cli(['-e', 'empty'], 'null')[0]
    assert_equal 5, cli(['error("x")'], 'null')[0]
    assert_equal 3, cli(['[1,'], 'null')[0]
    assert_equal 2, cli(['.'], '{bad')[0]
  end
end
