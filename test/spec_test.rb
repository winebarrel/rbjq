# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/jq_test_file'
require 'stringio'

# Specification tests in jq's test format (test/spec/*.test), grouped by
# area. The expected outputs were recorded from jq 1.8.2 run with
# LC_ALL=C and TZ=UTC, so the local-time functions are checked in UTC.
#
# Outputs are compared as printed JSON, so that e.g. infinite and
# 1.7976931348623157e+308 are told apart only where jq prints them
# differently. A runtime error after all expected outputs is not a
# failure, as in jq's own test runner.
class SpecTest < Minitest::Test
  DIR = File.join(__dir__, 'spec')

  def setup
    @tz = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'UTC'
  end

  def teardown
    ENV['TZ'] = @tz
  end

  Dir[File.join(DIR, '*.test')].sort.each do |path|
    JqTestFile.parse(path).each do |c|
      define_method("test_#{c.file.sub('.test', '')}_line_#{format('%04d', c.line)}") do
        expected = c.outputs.map { |o| Rbjq.dump_json(Rbjq.parse_json(o)) }
        actual = []
        begin
          Rbjq.compile(c.program, stderr: StringIO.new).each(Rbjq.parse_json(c.input)) do |v|
            actual << Rbjq.dump_json(v)
          end
        rescue Rbjq::JQError => e
          error = e
        end
        msg = "#{c.file}:#{c.line}: #{c.program}\ninput: #{c.input}" \
              "#{error ? "\nerror: #{error.message}" : ''}"
        assert_equal expected, actual, msg
      end
    end
  end
end
