# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/jq_test_file'
require 'rbjq/unparser'

# Rbjq::Unparser: parsing the generated source gives the same AST, for every
# program in jq's test suite and the spec tests.
class UnparserTest < Minitest::Test
  FILES = Dir[File.join(__dir__, 'jq', '*.test')] + Dir[File.join(__dir__, 'spec', '*.test')]

  # Differences that do not change the program: $__loc__ lines, and number
  # literals outside the double range, which parse as infinite.
  def normalize(node)
    return node unless node.is_a?(Array)

    case node.map { |n| normalize(n) }
    in [:loc, _] then [:loc]
    in [:call, 'infinite', []] then [:literal, Float::INFINITY]
    in [:neg, [:literal, Numeric => n]] then [:literal, -n]
    in other then other
    end
  end

  def test_round_trip
    programs = FILES.flat_map { |f| JqTestFile.parse(f) }.reject(&:fail).map(&:program).uniq

    assert_operator programs.size, :>, 100
    programs.each do |program|
      ast = begin
        Rbjq::Parser.parse(program)
      rescue Rbjq::CompileError
        next
      end
      source = Rbjq::Unparser.unparse(ast)

      assert_equal normalize(ast), normalize(Rbjq::Parser.parse(source)), "#{program}\n=> #{source}"
    end
  end

  def test_unknown_node
    assert_raises(ArgumentError) { Rbjq::Unparser.unparse([:unknown]) }
  end
end
