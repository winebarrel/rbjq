# frozen_string_literal: true

require_relative 'rbjq/version'

module Rbjq
  class Error < StandardError; end

  # Syntax or compile-time (undefined function/variable) errors.
  class CompileError < Error; end

  # Runtime error raised by a jq program. `value` is the error value
  # (usually a String message, but `error({...})` can raise any value).
  class JQError < Error
    attr_reader :value

    def initialize(value = nil)
      @value = value
      super(value.is_a?(String) ? value : "#{Encoder.dump(value)} (not a string)")
    end
  end

  # Invalid JSON text.
  class ParseError < JQError; end

  # Raised by halt / halt_error.
  class HaltError < Error
    attr_reader :value, :code

    def initialize(value, code, has_value)
      @value = value
      @code = code
      @has_value = has_value
      super("halt (#{code})")
    end

    def value?
      @has_value
    end
  end
end

require_relative 'rbjq/value'
require_relative 'rbjq/json'
require_relative 'rbjq/lexer'
require_relative 'rbjq/parser'
require_relative 'rbjq/env'
require_relative 'rbjq/interpreter'
require_relative 'rbjq/ops'
require_relative 'rbjq/formats'
require_relative 'rbjq/builtins'
require_relative 'rbjq/prelude'
require_relative 'rbjq/checker'
require_relative 'rbjq/program'

module Rbjq
  class << self
    # Compile a jq filter.
    #
    #   prog = Rbjq.compile('.[] | select(.age > $min)', vars: { 'min' => 20 })
    #   prog.run(data) #=> [...]
    def compile(filter, vars: {}, **)
      Program.new(filter, vars: vars, **)
    end

    # Run a jq filter against a Ruby value and return all outputs as an Array.
    #
    #   Rbjq.query({ 'a' => [1, 2] }, '.a[]') #=> [1, 2]
    def query(input, filter, vars: {}, **)
      compile(filter, vars: vars, **).run(input)
    end

    # Run a jq filter against JSON text (which may contain several values)
    # and return the outputs as an Array of Ruby values.
    def query_json(json, filter, vars: {}, **)
      prog = compile(filter, vars: vars, **)
      JSONParser.parse_all(json).flat_map { |v| prog.run(v) }
    end

    # Parse JSON text into Ruby values (jq-compatible numbers).
    def parse_json(json)
      JSONParser.parse(json)
    end

    # Encode a Ruby value as JSON text the way jq prints it.
    def dump_json(value, indent: 0, sort_keys: false)
      Encoder.new(indent: indent, sort_keys: sort_keys).encode(Program.normalize_value(value))
    end
  end
end
