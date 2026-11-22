# frozen_string_literal: true

module Rbjq
  # Linked-list lexical environment holding variables, functions and labels.
  class Env
    attr_reader :kind, :name, :parent
    attr_accessor :value

    def initialize(kind, name, value, parent)
      @kind = kind
      @name = name
      @value = value
      @parent = parent
    end

    def self.root
      nil
    end

    def self.bind_var(env, name, value)
      Env.new(:var, name, value, env)
    end

    def self.lookup(env, kind, name)
      e = env
      while e
        return e if e.kind == kind && e.name == name

        e = e.parent
      end
      nil
    end
  end

  # A user-defined (or prelude) function
  FuncDef = Struct.new(:name, :params, :body, :env)
  # A closure argument passed to a function parameter
  Closure = Struct.new(:node, :env, :value_param)
end
