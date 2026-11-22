# frozen_string_literal: true

module Rbjq
  # Static check that every referenced function, variable and label is defined.
  class Checker
    Scope = Struct.new(:funcs, :vars, :labels) do
      def with_func(key)
        Scope.new(funcs.dup.add(key), vars, labels)
      end

      def with_vars(names)
        Scope.new(funcs, vars | names, labels)
      end

      def with_label(name)
        Scope.new(funcs, vars, labels.dup.add(name))
      end
    end

    GLOBAL_VARS = %w[ENV __loc__].freeze

    def initialize(known_funcs)
      @known = known_funcs
    end

    def check(ast, vars)
      walk(ast, Scope.new(Set.new, Set.new(vars + GLOBAL_VARS), Set.new))
    end

    private

    def walk(node, s)
      return if node.nil?

      case node[0]
      when :identity, :literal, :format, :loc
        nil
      when :index, :pipe, :comma, :and, :or, :alt
        walk(node[1], s)
        walk(node[2], s)
      when :binop
        walk(node[2], s)
        walk(node[3], s)
      when :assign
        walk(node[2], s)
        walk(node[3], s)
      when :iterate, :neg, :array
        walk(node[1], s)
      when :slice
        walk(node[1], s)
        walk(node[2], s)
        walk(node[3], s)
      when :if
        walk(node[1], s)
        walk(node[2], s)
        walk(node[3], s)
      when :try
        walk(node[1], s)
        walk(node[2], s)
      when :var
        raise CompileError, "$#{node[1]} is not defined" unless s.vars.include?(node[1])
      when :object
        node[1].each do |k, v|
          raise CompileError, "Cannot use #{Value.desc(k[1])} as object key" if k[0] == :literal && !k[1].is_a?(String)

          walk(k, s)
          walk(v, s)
        end
      when :string
        node[1].each { |p| walk(p, s) unless p.is_a?(String) }
      when :call
        key = "#{node[1]}/#{node[2].size}"
        raise CompileError, "#{key} is not defined" unless s.funcs.include?(key) || @known.include?(key)

        node[2].each { |a| walk(a, s) }
      when :func_def
        _, name, params, body, rest = node
        key = "#{name}/#{params.size}"
        fs = s.with_func(key)
        bs = fs
        params.each do |p|
          bs = if p.start_with?('$')
                 bs.with_func("#{p[1..]}/0").with_vars([p[1..]])
               else
                 bs.with_func("#{p}/0")
               end
        end
        walk(body, bs)
        walk(rest, fs)
      when :as
        _, src, patterns, body = node
        walk(src, s)
        walk(body, s.with_vars(check_patterns(patterns, s)))
      when :reduce
        _, src, patterns, init, update = node
        walk(src, s)
        walk(init, s)
        walk(update, s.with_vars(check_patterns(patterns, s)))
      when :foreach
        _, src, patterns, init, update, extract = node
        walk(src, s)
        walk(init, s)
        ps = s.with_vars(check_patterns(patterns, s))
        walk(update, ps)
        walk(extract, ps)
      when :label
        walk(node[2], s.with_label(node[1]))
      when :break
        raise CompileError, "$*label-#{node[1]} is not defined" unless s.labels.include?(node[1])
      else
        raise CompileError, "unknown node #{node[0]}"
      end
    end

    def check_patterns(patterns, s)
      names = []
      patterns.each { |p| collect_pattern(p, s, names) }
      names
    end

    def collect_pattern(p, s, names)
      case p[0]
      when :pvar
        names << p[1]
      when :parray
        p[1].each { |e| collect_pattern(e, s, names) }
      when :pobject
        p[1].each do |key, var, sub|
          if key[0] == :literal && !key[1].is_a?(String)
            raise CompileError, "Cannot use #{Value.desc(key[1])} as object key"
          end

          names << var if var
          walk(key, s.with_vars(names))
          collect_pattern(sub, s, names) if sub
        end
      end
    end
  end
end
