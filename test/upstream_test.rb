# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/jq_test_file'
require 'stringio'

# Runs jq's own test suite (test/jq/*.test from jq 1.8.2, downloaded by
# `rake jq:download`, which `rake test` runs first).
#
# The semantics follow jq's test runner (src/jq_test.c):
# - the outputs must equal the expected values, compared as JSON values;
# - a runtime error after all expected outputs have been produced is not a
#   failure;
# - %%FAIL cases must fail to compile. The error message is not compared,
#   because rbjq's compile error messages differ from jq's.
#
# Each case runs in its own thread: some cases nest values 10,000 levels
# deep, which needs the large thread stack that the Rakefile configures.
class UpstreamTest < Minitest::Test
  DIR = File.join(__dir__, 'jq')

  SKIP = {
    # modules
    'import "a" as foo; import "b" as bar; def fooa: foo::a; [fooa, bar::a, bar::b, foo::a]' => :modules,
    'import "c" as foo; [foo::a, foo::c]' => :modules,
    'include "c"; [a, c]' => :modules,
    'import "data" as $e; import "data" as $d; [$d[].this,$e[].that,$d::d[].this,$e::e[].that]|join(";")' => :modules,
    'import "data" as $a; import "data" as $b; def f: {$a, $b}; f' => :modules,
    'include "shadow1"; e' => :modules,
    'include "shadow1"; include "shadow2"; e' => :modules,
    'import "shadow1" as f; import "shadow2" as f; import "shadow1" as e; [e::e, f::e]' => :modules,
    'import "test_bind_order" as check; check::check' => :modules,
    'modulemeta' => :modules,
    'modulemeta | .deps | length' => :modules,
    'modulemeta | .defs | length' => :modules,
    # number literals are not preserved (no decNumber)
    '9E999999999, 9999999999E999999990, 1E-999999999, 0.000000001E-999999990' => :decnum,
    # depends on the environment of jq's test runner
    '$ENV.PAGER' => :environment,
    'env.PAGER' => :environment
  }.freeze

  REASONS = {
    modules: 'import/include (modules) are not supported',
    decnum: 'number literals are not preserved (no decNumber support)',
    environment: "depends on the environment of jq's test runner"
  }.freeze

  if Dir[File.join(DIR, '*.test')].empty?
    define_method(:test_jq_test_suite) { skip "jq's test suite is not downloaded; run `rake jq:download`" }
  end

  Dir[File.join(DIR, '*.test')].each do |path|
    JqTestFile.parse(path).each do |c|
      name = "test_#{c.file.sub('.test', '')}_line_#{format('%04d', c.line)}"
      define_method(name) do
        if (reason = SKIP[c.program])
          skip REASONS.fetch(reason)
        end

        if c.fail
          assert_raises(Rbjq::CompileError, "#{c.file}:#{c.line}: #{c.program}") { Rbjq.compile(c.program) }
        else
          Thread.new do
            Thread.current.report_on_exception = false
            run_case(c)
          end.join
        end
      end
    end
  end

  private

  def run_case(c)
    expected = c.outputs.map { |o| Rbjq.parse_json(o) }
    actual = []
    begin
      Rbjq.compile(c.program, stderr: StringIO.new).each(Rbjq.parse_json(c.input)) { |v| actual << v }
    rescue Rbjq::JQError => e
      error = e
    end
    msg = "#{c.file}:#{c.line}: #{c.program}\ninput: #{c.input}\n" \
          "actual: #{Rbjq.dump_json(actual)}#{"\nerror: #{error.message}" if error}"

    assert Rbjq::Value.equal?(expected, actual), msg
  end
end
