# frozen_string_literal: true

module Rbjq
  # Raised from inside a `try` body's downstream so the try does not catch
  # errors that happen after the body has produced a value.
  class DownstreamError < StandardError
    attr_reader :error, :marker

    def initialize(error, marker)
      super(error.message)
      @error = error
      @marker = marker
    end
  end

  # Tree-walking evaluator. Every evaluation yields (value, path) pairs.
  # `path` is nil when paths are not being tracked, an Array of path
  # components when they are, or INVALID when the value is not a path.
  class Interpreter
    INVALID = Object.new.freeze

    attr_reader :options
    attr_accessor :input_provider, :global_env

    def initialize(prelude:, natives:, options: {})
      @prelude = prelude
      @natives = natives
      @options = options
      @global_env = nil
      @input_provider = nil
      @defer_operands = options.fetch(:defer_operands, true)
    end

    def run(ast, input, env = @global_env, &blk)
      return enum_for(:run, ast, input, env) unless blk

      eval_node(ast, input, nil, env) { |v, _| blk.call(v) }
    end

    # ---------------------------------------------------------------- eval

    def eval_node(node, input, path, env, &blk)
      case node[0]
      when :identity
        yield input, path
      when :literal
        yield node[1], path && INVALID
      when :index
        eval_index(node, input, path, env, &blk)
      when :pipe
        rhs = node[2]
        eval_node(node[1], input, path, env) { |v, p| eval_node(rhs, v, p, env, &blk) }
      when :comma
        eval_node(node[1], input, path, env, &blk)
        eval_node(node[2], input, path, env, &blk)
      when :call
        call_function(node, input, path, env, &blk)
      when :iterate
        eval_node(node[1], input, path, env) do |t, tp|
          check_iterate_path!(t, tp) if path
          iterate(t, tp, &blk)
        end
      when :slice
        eval_slice(node, input, path, env, &blk)
      when :binop
        op = node[1]
        lhs = node[2]
        each_operand(node[3], input, env) do |r|
          eval_node(lhs, input, nil, env) do |l|
            yield Ops.binop(op, l, r), path && INVALID
          end
        end
      when :and
        rhs = node[2]
        each_operand(node[1], input, env) do |l|
          if Value.truthy?(l)
            eval_node(rhs, input, nil, env) { |r| yield Value.truthy?(r), path && INVALID }
          else
            yield false, path && INVALID
          end
        end
      when :or
        rhs = node[2]
        each_operand(node[1], input, env) do |l|
          if Value.truthy?(l)
            yield true, path && INVALID
          else
            eval_node(rhs, input, nil, env) { |r| yield Value.truthy?(r), path && INVALID }
          end
        end
      when :alt
        found = false
        eval_node(node[1], input, path, env) do |v, p|
          if Value.truthy?(v)
            found = true
            yield v, p
          end
        end
        eval_node(node[2], input, path, env, &blk) unless found
      when :neg
        eval_node(node[1], input, nil, env) do |v|
          raise JQError, "#{Value.desc(v)} cannot be negated" unless Value.number?(v)

          yield(v.zero? && v.is_a?(Integer) ? -0.0 : Value.normalize_number(-v), path && INVALID)
        end
      when :if
        cond = node[1]
        eval_node(cond, input, nil, env) do |c|
          if Value.truthy?(c)
            eval_node(node[2], input, path, env, &blk)
          elsif node[3]
            eval_node(node[3], input, path, env, &blk)
          else
            yield input, path
          end
        end
      when :try
        eval_try(node, input, path, env, &blk)
      when :var
        yield lookup_var(node[1], env), path && INVALID
      when :as
        eval_as(node, input, path, env, &blk)
      when :array
        arr = []
        eval_node(node[1], input, nil, env) { |v| arr << v } if node[1]
        yield arr, path && INVALID
      when :object
        build_object(node[1], 0, {}, input, env) { |h| yield h, path && INVALID }
      when :string
        eval_string(node[1], node[1].size - 1, '', node[2], input, env) { |s| yield s, path && INVALID }
      when :format
        yield Formats.apply(node[1], input), path && INVALID
      when :reduce
        eval_reduce(node, input, path, env, &blk)
      when :foreach
        eval_foreach(node, input, path, env, &blk)
      when :func_def
        _, name, params, body, rest = node
        fenv = Env.new(:func, "#{name}/#{params.size}", nil, env)
        fenv.value = FuncDef.new(name, params, body, fenv)
        eval_node(rest, input, path, fenv, &blk)
      when :assign
        eval_assign(node, input, path, env, &blk)
      when :label
        tag = Object.new
        lenv = Env.new(:label, node[1], tag, env)
        catch(tag) { eval_node(node[2], input, path, lenv, &blk) }
      when :break
        l = Env.lookup(env, :label, node[1])
        raise JQError, "$*label-#{node[1]} is not defined" unless l

        throw l.value
      when :loc
        yield({ 'file' => '<top-level>', 'line' => node[1] }, path && INVALID)
      else
        raise JQError, "unknown node #{node[0]}"
      end
    end

    def check_path!(v, p)
      return unless p.equal?(INVALID)

      raise JQError, "Invalid path expression with result #{Value.dump_trunc(v)}"
    end

    # Messages follow jq; values are shortened like other error messages
    def check_access_path!(t, tp, k)
      return unless tp.equal?(INVALID)

      raise JQError, 'Invalid path expression near attempt to access element ' \
                     "#{Value.dump_trunc(k)} of #{Value.dump_trunc(t)}"
    end

    def check_iterate_path!(t, tp)
      return unless tp.equal?(INVALID)

      raise JQError, "Invalid path expression near attempt to iterate through #{Value.dump_trunc(t)}"
    end

    def eval_index(node, input, path, env, &)
      target = node[1]
      key = node[2]
      if key[0] == :literal
        k = key[1]
        eval_node(target, input, path, env) do |t, tp|
          if path
            check_access_path!(t, tp, k)
            yield Ops.index(t, k), tp + [k]
          else
            yield Ops.index(t, k), nil
          end
        end
      else
        eval_node(key, input, nil, env) do |k|
          eval_node(target, input, path, env) do |t, tp|
            if path
              check_access_path!(t, tp, k)
              yield Ops.index(t, k), tp + [k]
            else
              yield Ops.index(t, k), nil
            end
          end
        end
      end
    end

    def eval_slice(node, input, path, env, &)
      _, target, from_n, to_n = node
      each_opt(from_n, input, env) do |from|
        each_opt(to_n, input, env) do |to|
          eval_node(target, input, path, env) do |t, tp|
            v = Ops.slice(t, from, to)
            if path
              check_access_path!(t, tp, { 'start' => from, 'end' => to })
              yield v, tp + [{ 'start' => from, 'end' => to }]
            else
              yield v, nil
            end
          end
        end
      end
    end

    def each_opt(node, input, env, &)
      if node.nil?
        yield nil
      else
        eval_node(node, input, nil, env, &)
      end
    end

    def iterate(t, tp)
      case t
      when Array
        if tp
          t.each_with_index { |e, i| yield e, tp + [i] }
        else
          t.each { |e| yield e, nil }
        end
      when Hash
        if tp
          t.each { |k, v| yield v, tp + [k] }
        else
          t.each_value { |v| yield v, nil }
        end
      else
        raise JQError, "Cannot iterate over #{Value.desc(t)}"
      end
    end

    def eval_try(node, input, path, env, &)
      body = node[1]
      handler = node[2]
      marker = Object.new
      begin
        eval_node(body, input, path, env) do |v, p|
          yield v, p
        rescue JQError => e
          raise DownstreamError.new(e, marker)
        end
      rescue JQError => e
        # the handler's input keeps the path only if it is the try's input itself
        eval_node(handler, e.value, path && (e.value.equal?(input) ? path : INVALID), env, &) if handler
      rescue DownstreamError => e
        raise e.error if e.marker.equal?(marker)

        raise
      end
    end

    def lookup_var(name, env)
      e = Env.lookup(env, :var, name)
      return e.value if e

      case name
      when 'ENV' then ENV.to_h
      else raise JQError, "$#{name} is not defined"
      end
    end

    def eval_as(node, input, path, env, &blk)
      _, src, patterns, body = node
      eval_node(src, input, nil, env) do |v|
        if patterns.size == 1
          bind_pattern(patterns[0], v, input, env) { |e2| eval_node(body, input, path, e2, &blk) }
        else
          eval_alternatives(patterns, v, input, env, body, path, &blk)
        end
      end
    end

    def eval_alternatives(patterns, v, input, env, body, path, &blk)
      names = patterns.flat_map { |pt| pattern_vars(pt) }.uniq
      base = names.reduce(env) { |e, n| Env.bind_var(e, n, nil) }
      patterns.each_with_index do |pat, i|
        if i == patterns.size - 1
          bind_pattern(pat, v, input, base) { |e2| eval_node(body, input, path, e2, &blk) }
          break
        end

        marker = Object.new
        begin
          bind_pattern(pat, v, input, base) do |e2|
            eval_node(body, input, path, e2) do |o, op|
              yield o, op
            rescue JQError => e
              raise DownstreamError.new(e, marker)
            end
          end
          break
        rescue JQError
          next
        rescue DownstreamError => e
          raise e.error if e.marker.equal?(marker)

          raise
        end
      end
    end

    def pattern_vars(pat)
      case pat[0]
      when :pvar then [pat[1]]
      when :parray then pat[1].flat_map { |pt| pattern_vars(pt) }
      when :pobject
        pat[1].flat_map do |(_, var, sub)|
          (var ? [var] : []) + (sub ? pattern_vars(sub) : [])
        end
      end
    end

    def bind_pattern(pat, v, input, env, &)
      case pat[0]
      when :pvar
        yield Env.bind_var(env, pat[1], v)
      when :parray
        bind_array(pat[1], 0, v, input, env, &)
      when :pobject
        bind_object(pat[1], 0, v, input, env, &)
      end
    end

    def bind_array(pats, i, v, input, env, &blk)
      if i == pats.size
        yield env
        return
      end
      Ops.index_error(v, i) unless v.nil? || v.is_a?(Array)

      bind_pattern(pats[i], Ops.index(v, i), input, env) do |e2|
        bind_array(pats, i + 1, v, input, e2, &blk)
      end
    end

    def bind_object(entries, i, v, input, env, &blk)
      if i == entries.size
        yield env
        return
      end
      key_node, var, sub = entries[i]
      eval_node(key_node, input, nil, env) do |k|
        raise JQError, "Cannot index #{Value.type_name(v)} with #{Value.type_name(k)}" unless k.is_a?(String)

        val = Ops.index(v, k)
        e2 = var ? Env.bind_var(env, var, val) : env
        if sub
          bind_pattern(sub, val, input, e2) { |e3| bind_object(entries, i + 1, v, input, e3, &blk) }
        else
          bind_object(entries, i + 1, v, input, e2, &blk)
        end
      end
    end

    def build_object(entries, i, acc, input, env, &blk)
      if i == entries.size
        yield acc
        return
      end
      key_node, val_node = entries[i]
      each_operand(key_node, input, env) do |k|
        raise JQError, "Cannot use #{Value.desc(k)} as object key" unless k.is_a?(String)

        each_operand(val_node, input, env) do |v|
          h = acc.dup
          h[k] = v
          build_object(entries, i + 1, h, input, env, &blk)
        end
      end
    end

    def eval_string(parts, i, suffix, fmt, input, env, &blk)
      if i.negative?
        yield suffix
        return
      end
      part = parts[i]
      if part.is_a?(String)
        eval_string(parts, i - 1, part + suffix, fmt, input, env, &blk)
      else
        each_operand(part, input, env) do |v|
          s = fmt ? Formats.apply(fmt, v) : Ops.tostring(v)
          eval_string(parts, i - 1, s + suffix, fmt, input, env, &blk)
        end
      end
    end

    def eval_reduce(node, input, path, env)
      _, src, patterns, init, update = node
      eval_node(init, input, path, env) do |iv, ip|
        state = iv
        eval_node(src, input, nil, env) do |x|
          bind_for_loop(patterns, x, input, env) do |e2|
            got = false
            last = nil
            eval_node(update, state, state_path(state, iv, ip), e2) do |v, _|
              got = true
              last = v
            end
            state = got ? last : nil
          end
        end
        yield state, state_path(state, iv, ip)
      end
    end

    # jq tracks paths by value identity: a loop state has the path of the
    # initial value only while it still is that value.
    def state_path(state, init, init_path)
      return nil if init_path.nil?

      state.equal?(init) ? init_path : INVALID
    end

    def eval_foreach(node, input, path, env, &block)
      _, src, patterns, init, update, extract = node
      eval_node(init, input, path, env) do |iv, ip|
        state = iv
        eval_node(src, input, nil, env) do |x|
          bind_for_loop(patterns, x, input, env) do |e2|
            eval_node(update, state, state_path(state, iv, ip), e2) do |v, p|
              state = v
              if extract
                eval_node(extract, v, p, e2, &block)
              else
                yield v, p
              end
            end
          end
        end
      end
    end

    def bind_for_loop(patterns, x, input, env, &blk)
      if patterns.size == 1
        bind_pattern(patterns[0], x, input, env, &blk)
      else
        names = patterns.flat_map { |pt| pattern_vars(pt) }.uniq
        base = names.reduce(env) { |e, n| Env.bind_var(e, n, nil) }
        patterns.each_with_index do |pat, i|
          if i == patterns.size - 1
            bind_pattern(pat, x, input, base, &blk)
          else
            envs = []
            begin
              bind_pattern(pat, x, input, base) { |e2| envs << e2 }
            rescue JQError
              next
            end
            envs.each(&blk)
          end
          break
        end
      end
    end

    # ------------------------------------------------------------ paths

    def collect_paths(node, input, env)
      paths = []
      eval_node(node, input, [], env) do |v, p|
        check_path!(v, p)
        paths << p
      end
      paths
    end

    def eval_assign(node, input, path, env, &)
      _, op, lhs, rhs = node
      inv = path && INVALID
      case op
      when :'='
        eval_node(rhs, input, nil, env) do |rv|
          result = input
          collect_paths(lhs, input, env).each { |p| result = Ops.setpath(result, p, rv) }
          yield result, inv
        end
      when :'|='
        yield modify(lhs, input, env) { |old, emit| eval_node(rhs, old, nil, env) { |v| emit.call(v) } }, inv
      else
        bop = op.to_s.chomp('=').to_sym
        eval_node(rhs, input, nil, env) do |rv|
          result = modify(lhs, input, env) do |old, emit|
            if bop == :'//'
              emit.call(Value.truthy?(old) ? old : rv)
            else
              emit.call(Ops.binop(bop, old, rv))
            end
          end
          yield result, inv
        end
      end
    end

    # Implements _modify(paths; update): first output of update replaces the
    # value at each path; paths where update is empty are deleted.
    def modify(lhs, input, env, &updater)
      result = input
      dels = []
      collect_paths(lhs, input, env).each do |p|
        old = Ops.getpath(result, p)
        tag = Object.new
        found = false
        newv = nil
        catch(tag) do
          updater.call(old, lambda do |v|
            found = true
            newv = v
            throw tag
          end)
        end
        if found
          result = Ops.setpath(result, p, newv)
        else
          dels << p
        end
      end
      result = Ops.delpaths(result, dels) unless dels.empty?
      result
    end

    # ---------------------------------------------------------- functions

    def call_function(node, input, path, env, &)
      key = "#{node[1]}/#{node[2].size}"
      e = Env.lookup(env, :func, key)
      if e
        f = e.value
        if f.is_a?(Closure)
          eval_node(f.node, input, path, f.env, &)
        else
          call_funcdef(f, node[2], input, path, env, &)
        end
      elsif (f = @prelude[key])
        call_funcdef(f, node[2], input, path, env, &)
      elsif (nf = @natives[key])
        nf.call(self, input, path, node[2], env, &)
      else
        raise JQError, "#{key} is not defined"
      end
    end

    def call_funcdef(f, args, input, path, caller_env, &blk)
      params = f.params
      if params.empty?
        eval_node(f.body, input, path, f.env, &blk)
        return
      end

      e = f.env
      value_params = nil
      params.each_with_index do |p, i|
        if p.start_with?('$')
          pname = p[1..]
          e = Env.new(:func, "#{pname}/0", Closure.new(args[i], caller_env), e)
          (value_params ||= []) << [pname, args[i]]
        else
          e = Env.new(:func, "#{p}/0", Closure.new(args[i], caller_env), e)
        end
      end

      if value_params
        bind_value_params(value_params, 0, input, caller_env, e) do |e2|
          eval_node(f.body, input, path, e2, &blk)
        end
      else
        eval_node(f.body, input, path, e, &blk)
      end
    end

    def bind_value_params(vps, i, input, caller_env, env, &blk)
      if i == vps.size
        yield env
        return
      end
      name, node = vps[i]
      each_operand(node, input, caller_env) do |v|
        bind_value_params(vps, i + 1, input, caller_env, Env.bind_var(env, name, v), &blk)
      end
    end

    # Evaluate native-function arguments as a cartesian product
    # (the last argument varies slowest, like jq's cfunctions).
    def each_args(args, input, env, i = args.size - 1, acc = [], &blk)
      if i.negative?
        yield acc
        return
      end
      each_operand(args[i], input, env) do |v|
        each_args(args, input, env, i - 1, [v] + acc, &blk)
      end
    end

    # Calls whose outputs should always be streamed (generators / side effects).
    STREAMING_CALLS = %w[
      range recurse repeat while until limit first input inputs debug stderr empty error
    ].to_set.freeze

    # Evaluates an operand whose outputs drive an outer loop.
    #
    # Running the consumer inside the operand's yield stacks the consumer's
    # frames on top of the operand's, so code such as
    # `(. - 1 | f) + (. - 2 | f)` would need stack exponential in the
    # recursion depth. For operands that end in a function call, the first
    # output is held back until either the operand finishes (the common
    # single-output case, consumed after the operand's frames are gone) or a
    # second output arrives (from then on everything is streamed). On an
    # error or a break, the held-back output is consumed first, so jq's
    # output order is preserved.
    def each_operand(node, input, env)
      unless @defer_operands && deferrable?(node)
        eval_node(node, input, nil, env) { |v, _| yield v }
        return
      end

      pending = false
      buffered = nil
      streaming = false
      completed = false
      raised = false
      begin
        eval_node(node, input, nil, env) do |v, _|
          if streaming
            yield v
          elsif pending
            streaming = true
            pending = false
            yield buffered
            yield v
          else
            buffered = v
            pending = true
          end
        end
        completed = true
      rescue Exception => e # rubocop:disable Lint/RescueException
        raised = true
        if pending && (e.is_a?(JQError) || e.is_a?(HaltError))
          pending = false
          yield buffered
        end
        raise
      ensure
        # normal completion, or unwinding by throw (label/break, limit, first)
        if pending && (completed || !raised)
          pending = false
          yield buffered
        end
      end
    end

    def deferrable?(node)
      case node[0]
      when :call then !STREAMING_CALLS.include?(node[1])
      when :pipe then single?(node[1]) && deferrable?(node[2])
      else false
      end
    end

    # Statically known to produce exactly one output (or an error).
    def single?(node)
      case node[0]
      when :literal, :var, :identity, :loc, :format, :array then true
      when :index then single?(node[1]) && single?(node[2])
      when :slice then single?(node[1]) && (node[2].nil? || single?(node[2])) && (node[3].nil? || single?(node[3]))
      when :binop then single?(node[2]) && single?(node[3])
      when :neg then single?(node[1])
      when :and, :or then single?(node[1]) && single?(node[2])
      when :object then node[1].all? { |k, v| single?(k) && single?(v) }
      when :string then node[1].all? { |p| p.is_a?(String) || single?(p) }
      when :pipe then single?(node[1]) && single?(node[2])
      else false
      end
    end

    def first_value(node, input, env)
      tag = Object.new
      result = nil
      found = false
      catch(tag) do
        eval_node(node, input, nil, env) do |v|
          result = v
          found = true
          throw tag
        end
      end
      [found, result]
    end

    def next_input
      # jq raises "break" when there are no more inputs (`inputs` catches it)
      raise JQError, 'break' unless @input_provider

      v = @input_provider.call
      raise JQError, 'break' if v.equal?(JSONParser::EOF)

      v
    end

    def current_filename
      @options[:filename_proc]&.call
    end
  end
end
