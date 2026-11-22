# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

# Cases whose expected outputs were recorded from the real jq (1.8.2).
class JqCompatTest < Minitest::Test
  FIXTURE = File.join(__dir__, 'fixtures', 'jq_compat.tsv')

  File.readlines(FIXTURE, chomp: true, encoding: 'UTF-8').each_with_index do |line, i|
    filter, input, expected = line.split("\t", 3)
    define_method("test_case_#{format('%03d', i + 1)}") do
      prog = Rbjq.compile(filter)
      actual = []
      Rbjq::JSONParser.parse_all(input).each do |v|
        prog.each(v) { |o| actual << Rbjq::Encoder.dump(o) }
      end
      assert_equal JSON.parse(expected), actual, "filter: #{filter}\ninput: #{input}"
    end
  end
end
