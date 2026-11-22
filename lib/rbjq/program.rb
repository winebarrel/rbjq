# frozen_string_literal: true

require 'set'

module Rbjq
  # A compiled jq program.
  class Program
    class << self
      def prelude
        @prelude ||= begin
          defs = Parser.new(Lexer.new(PRELUDE).tokenize).parse_defs
          h = {}
          defs.each do |(_, name, params, body)|
            h["#{name}/#{params.size}"] = FuncDef.new(name, params, body, nil)
          end
          Builtins.const_set(:PRELUDE_KEYS, h.keys.freeze) unless Builtins.const_defined?(:PRELUDE_KEYS)
          h.freeze
        end
      end

      def known_functions
        @known_functions ||= Set.new(prelude.keys + Builtins::NATIVES.keys).freeze
      end

      # Convert arbitrary Ruby data into jq values (symbol keys -> strings, etc.)
      def normalize_value(v)
        case v
        when nil, true, false, String then v
        when Integer then v
        when Float then Value.normalize_number(v)
        when Symbol then v.to_s
        when Array then v.map { |e| normalize_value(e) }
        when Hash then v.each_with_object({}) { |(k, x), h| h[k.to_s] = normalize_value(x) }
        else
          if v.respond_to?(:to_h) then normalize_value(v.to_h)
          elsif v.respond_to?(:to_a) then normalize_value(v.to_a)
          else v.to_s
          end
        end
      end
    end

    attr_reader :source, :ast

    # vars: Hash of variable name (without '$') => value
    # options: :stderr (IO for debug/stderr), :filename_proc
    def initialize(source, vars: {}, **options)
      @source = source
      @ast = Parser.parse(source)
      @vars = vars.each_with_object({}) { |(k, v), h| h[k.to_s.delete_prefix('$')] = self.class.normalize_value(v) }
      Checker.new(self.class.known_functions).check(@ast, @vars.keys)
      @options = options
      # Holding back an operand's first output (see Interpreter#each_operand)
      # would reorder side effects, so keep strict streaming for such programs.
      @side_effects = calls_any?(@ast, SIDE_EFFECT_CALLS)
    end

    SIDE_EFFECT_CALLS = %w[input inputs debug stderr input_line_number].freeze

    # Yields each output for the given input.
    # inputs: an Enumerator/Proc used by `input`/`inputs`.
    def each(input, inputs: nil, &blk)
      return enum_for(:each, input, inputs: inputs) unless blk

      interp = Interpreter.new(prelude: self.class.prelude, natives: Builtins::NATIVES,
                               options: @options.merge(defer_operands: !@side_effects))
      interp.input_provider = make_provider(inputs) if inputs
      env = nil
      @vars.each { |k, v| env = Env.bind_var(env, k, v) }
      interp.run(@ast, self.class.normalize_value(input), env, &blk)
    end

    def run(input, inputs: nil)
      out = []
      each(input, inputs: inputs) { |v| out << v }
      out
    end

    alias call run

private

    def calls_any?(node, names)
      return false unless node.is_a?(Array)
      return true if node[0] == :call && names.include?(node[1])

      node.any? { |c| c.is_a?(Array) && calls_any?(c, names) }
    end

    def make_provider(inputs)
      case inputs
      when Proc then inputs
      else
        e = inputs.each
        lambda do
          self.class.normalize_value(e.next)
        rescue StopIteration
          JSONParser::EOF
        end
      end
    end
  end
end
