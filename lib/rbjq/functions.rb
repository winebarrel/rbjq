# frozen_string_literal: true

module Rbjq
  # jq functions implemented in Ruby by the user.
  #
  # A function receives the input and its arguments as evaluated values (like
  # jq's `$x` parameters): when an argument produces several values, the
  # function is called for each combination. It returns one value. Raising
  # Rbjq::JQError makes a jq error that `try` can catch.
  #
  # The number of jq arguments is the callable's arity minus one (the input).
  # For a callable with optional or rest parameters, give it in the name:
  # "name/arity".
  module Functions
    NAME = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/
    @global = {}
    @lock = Mutex.new

    class << self
      # Hash of "name/arity" => native implementation
      def global
        @lock.synchronize { @global.dup }
      end

      def define_global(name, callable)
        key, native = build(name, callable)
        @lock.synchronize { @global[key] = native }
        key
      end

      # name: "name/arity", or "name" to remove every arity
      def undefine_global(name)
        name = name.to_s
        @lock.synchronize do
          if name.include?('/')
            !@global.delete(name).nil?
          else
            keys = @global.keys.select { |k| k.start_with?("#{name}/") }
            keys.each { |k| @global.delete(k) }
            !keys.empty?
          end
        end
      end

      # Hash of name => callable to Hash of "name/arity" => native implementation
      def build_all(functions)
        functions.to_h { |name, callable| build(name, callable) }
      end

      def build(name, callable)
        raise ArgumentError, "function #{name.inspect} must respond to #call" unless callable.respond_to?(:call)

        name, arity = parse_name(name.to_s, callable)
        [key_for(name, arity), native(callable, arity)]
      end

      private

      def key_for(name, arity)
        "#{name}/#{arity}"
      end

      def parse_name(name, callable)
        base, explicit = name.split('/', 2)
        raise ArgumentError, "invalid function name: #{name.inspect}" unless base.match?(NAME)

        if explicit
          raise ArgumentError, "invalid arity in #{name.inspect}" unless explicit.match?(/\A\d+\z/)

          return [base, explicit.to_i]
        end

        params = callable.respond_to?(:arity) ? callable.arity : -1
        if params.negative?
          raise ArgumentError, "the number of arguments of #{name.inspect} is not fixed; " \
                               "give it as \"#{name}/N\""
        end
        raise ArgumentError, "function #{name.inspect} must take the input as its first argument" if params.zero?

        [base, params - 1]
      end

      def native(callable, arity)
        invalid = Interpreter::INVALID
        lambda do |interp, input, path, args, env, &blk|
          if arity.zero?
            blk.call(Program.normalize_value(callable.call(input)), path && invalid)
          else
            interp.each_args(args, input, env) do |values|
              blk.call(Program.normalize_value(callable.call(input, *values)), path && invalid)
            end
          end
        end
      end
    end
  end

  class << self
    # Define a jq function for every program compiled afterwards.
    #
    #   Rbjq.define_function('double') { |input| input * 2 }
    #   Rbjq.define_function('add_n') { |input, n| input + n }
    #   Rbjq.query(3, 'double, add_n(10)') #=> [6, 13]
    #
    # Functions given to Rbjq.compile(functions:) take precedence, and jq
    # definitions (`def`) in a program take precedence over both. Returns the
    # "name/arity" key.
    def define_function(name, callable = nil, &block)
      Functions.define_global(name, callable || block)
    end

    # Remove a function defined with define_function ("name/arity", or
    # "name" for every arity). Returns whether one was removed.
    def undefine_function(name)
      Functions.undefine_global(name)
    end
  end
end
