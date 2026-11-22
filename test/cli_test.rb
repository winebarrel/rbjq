# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'
require 'tmpdir'
require 'rbjq/cli'

# Command line behavior. The expectations were checked against jq 1.8.2
# (apart from the "rbjq" program name in messages).
class CLITest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def file(name, content)
    path = File.join(@dir, name)
    File.write(path, content)
    path
  end

  def cli(args, stdin = '', env: {})
    out = StringIO.new
    err = StringIO.new
    saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
    env.each { |k, v| ENV[k] = v }
    status = Rbjq::CLI.start(args, stdin: StringIO.new(stdin), stdout: out, stderr: err)
    [status, out.string, err.string]
  ensure
    saved&.each { |k, v| ENV[k] = v }
  end

  def test_output_formats
    assert_equal "[\n\t1\n]\n", cli(['--tab', '.'], '[1]')[1]
    assert_equal "[\n    1\n]\n", cli(['--indent', '4', '.'], '[1]')[1]
    assert_equal "[\n1,\n[\n2\n]\n]\n", cli(['--indent', '0', '.'], '[1,[2]]')[1]
    assert_equal "[\n\t1\n]\n", cli(['--indent', '-1', '.'], '[1]')[1]
    assert_equal "{\"a\":1,\"b\":2}\n", cli(['-S', '-c', '.'], '{"b":2,"a":1}')[1]
    assert_equal "[\"\\u00e9\\ud83d\\ude00\"]\n", cli(['-ac', '.'], '["é😀"]')[1]
    assert_equal "\"\\u00e9\"\n", cli(['-a', '-r', '.'], '"é"')[1]
    assert_equal 'ab', cli(['-j', '.[]'], '["a","b"]')[1]
    assert_equal "a\0b\0", cli(['--raw-output0', '.[]'], '["a","b"]')[1]
    assert_equal "\x1e1\n\x1e2\n", cli(['--seq', '.'], "\x1e1\x1e2")[1]
  end

  def test_colors
    out = cli(['-C', '-c', '.'], '{"a":[1,null,"s"]}')[1]
    assert_equal "\e[1;39m{\e[0m\e[1;34m\"a\"\e[0m\e[1;39m:\e[0m\e[1;39m[\e[0m\e[0;39m1\e[0m" \
                 "\e[1;39m,\e[0m\e[0;90mnull\e[0m\e[1;39m,\e[0m\e[0;32m\"s\"\e[0m\e[1;39m]\e[0m\e[1;39m}\e[0m\n", out
    out = cli(['-C', '.'], '[]', env: { 'JQ_COLORS' => '0;31:0;32:0;33:0;34:0;35:4;36' })[1]
    assert_equal "\e[4;36m[]\e[0m\n", out
    assert_equal "[]\n", cli(['-M', '.'], '[]')[1]
  end

  def test_inputs
    a = file('a.json', "1\n{\"x\":2}\n")
    b = file('b.json', '"s"')
    assert_equal "[1,{\"x\":2},\"s\"]\n", cli(['-c', '-s', '.', a, b])[1]
    assert_equal "\"#{a}\"\n\"#{a}\"\n\"#{b}\"\n", cli(['input_filename', a, b])[1]
    assert_equal "[1,1]\n[{\"x\":2},2]\n", cli(['-c', '[., input_line_number]', a])[1]
    assert_equal "\"<stdin>\"\n", cli(['input_filename'], '1')[1]
    assert_equal "null\n", cli(['-n', 'input_filename'])[1]
    assert_equal "[1,{\"x\":2},\"s\"]\n", cli(['-nc', '[inputs]', a, b])[1]
    assert_equal "\"l1\"\n\"l2\"\n", cli(['-R', '.'], "l1\nl2")[1]
    assert_equal "\"l1\\nl2\\n\"\n", cli(['-Rs', '.'], "l1\nl2\n")[1]
    assert_equal "[\"l1\",\"l2\"]\n", cli(['-nRc', '[inputs]'], "l1\nl2\n")[1]
    assert_equal "[[\"a\"],1]\n[[\"a\"]]\n", cli(['-c', '--stream', '.'], '{"a":1}')[1]
  end

  def test_variables
    raw = file('raw.txt', "raw\n")
    json = file('v.json', '1 2')
    assert_equal "\"raw\\n\"\n", cli(['-n', '--rawfile', 'r', raw, '$r'])[1]
    assert_equal "[1,2]\n", cli(['-nc', '--slurpfile', 's', json, '$s'])[1]
    assert_equal "{\"positional\":[1,{\"a\":2}],\"named\":{}}\n",
                 cli(['-nc', '--jsonargs', '$ARGS', '1', '{"a":2}'])[1]
    assert_equal "[\"x\",\"y\"]\n", cli(['-nc', '[$a, $b]', '--arg', 'a', 'x', '--arg', 'b', 'y'])[1]
  end

  def test_from_file
    prog = file('prog.jq', "def f: . + 1;\n.a | f")
    data = file('d.json', '{"a":1}')
    assert_equal "2\n", cli(['-f', prog, data])[1]
    assert_equal "\"#{@dir}\"\n", cli(['-f', file('o.jq', 'get_prog_origin'), '-n'])[1]
  end

  def test_usage_errors
    status, _, err = cli(['-x', '.'])
    assert_equal 2, status
    assert_equal "rbjq: Unknown option -x\nUse rbjq --help for help with command-line options,\n" \
                 "or see the jq manpage, or online docs at https://jqlang.org\n", err
    assert_match(/--indent takes a number between -1 and 7/, cli(['--indent', '8', '.'])[2])
    assert_match(/--arg takes two parameters/, cli(['--arg', 'x'])[2])
    assert_match(/invalid JSON text passed to --argjson/, cli(['--argjson', 'x', '{', '.'])[2])
    assert_match(/invalid JSON text passed to --jsonargs/, cli(['-n', '--jsonargs', '.', '{'])[2])
    assert_match(/Usage:/, cli(['-h'])[1])
    assert_match(/\Arbjq-\d/, cli(['--version'])[1])
  end

  def test_errors_and_exit_status
    assert_equal [5, '', "rbjq: parse error: Unfinished JSON term at EOF at line 1, column 1\n"], cli(['.'], '[')
    assert_equal [5, "1\n", "rbjq: parse error: Unfinished JSON term at EOF at line 1, column 3\n"], cli(['.'], '1 [')
    # the last input decides the exit status
    assert_equal 0, cli(['.a'], '"x" {"a":1}')[0]
    assert_equal 5, cli(['.a'], '{"a":1} "x"')[0]
    assert_equal 5, cli(['-e', '.a'], '{"a":1} "x"')[0]
    status, out, err = cli(['.', File.join(@dir, 'missing.json'), file('one.json', '1')])
    assert_equal [2, "1\n"], [status, out]
    assert_match(/Could not open file .*missing.json: No such file or directory/, err)
    assert_equal "rbjq: error (at <unknown>) (not a string): {}\n", cli(['-n', 'error({})'])[2]
  end

  def test_halt
    assert_equal [0, '', ''], cli(['-n', 'halt'])
    assert_equal [1, '', 'bye'], cli(['-n', '"bye" | halt_error(1)'])
    assert_equal [5, '', "{\"a\":1}\n"], cli(['-n', '{"a":1} | halt_error'])
  end

  def test_seq_input
    status, out, err = cli(['-c', '--seq', '.'], 'x')
    assert_equal [0, ''], [status, out]
    assert_match(/ignoring parse error: Unfinished abandoned text/, err)
  end

  def test_long_options
    prog = file('p.jq', '.[0]')
    assert_equal "\"a\"\n", cli(['--null-input', '--raw-input', 'input'], "a\n")[1]
    assert_equal "[1,2]\n", cli(['--slurp', '--compact-output', '.'], '1 2')[1]
    assert_equal "a\nb\n", cli(['--raw-output', '.[]'], '["a","b"]')[1]
    assert_equal 'ab', cli(['--join-output', '.[]'], '["a","b"]')[1]
    assert_equal "\"\\u00e9\"\n", cli(['--ascii-output', '.'], '"é"')[1]
    assert_equal "{\"a\":1,\"b\":2}\n", cli(['--sort-keys', '-c', '.'], '{"b":2,"a":1}')[1]
    assert_equal "\e[0;39m1\e[0m\n", cli(['--color-output', '.'], '1')[1]
    assert_equal "1\n", cli(['--monochrome-output', '.'], '1')[1]
    assert_equal 1, cli(['--exit-status', '.'], 'false')[0]
    assert_equal "1\n", cli(['--from-file', prog], '[1]')[1]
  end

  def test_no_filter
    # without a terminal, the filter defaults to "."
    assert_equal [0, "{\n  \"a\": 1\n}\n", ''], cli([], '{"a":1}')

    tty = ->(io) { io.define_singleton_method(:tty?) { true } && io }
    out = tty.call(StringIO.new)
    err = StringIO.new
    status = Rbjq::CLI.start([], stdin: tty.call(StringIO.new), stdout: out, stderr: err)
    assert_equal [2, ''], [status, out.string]
    assert_match(/Usage:/, err.string)
  end

  def test_double_dash_and_library_options
    assert_equal "1\n", cli(['-n', '--', '1'])[1]
    assert_equal "1\n", cli(['-L', @dir, '-n', '1'])[1]
    assert_equal "1\n", cli(['--unbuffered', '-n', '1'])[1]
  end
end
