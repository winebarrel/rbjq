# frozen_string_literal: true

require 'date'
require 'time'

module Rbjq
  # Builtin functions implemented in Ruby.
  module Builtins
    NATIVES = {}
    INVALID = Interpreter::INVALID

    module_function

    # Special forms: receive closures (AST nodes) and full control.
    def special(name, arity, &impl)
      NATIVES["#{name}/#{arity}"] = impl
    end

    # Plain value functions: arguments are evaluated (cartesian product).
    def fn(name, arity, &impl)
      NATIVES["#{name}/#{arity}"] =
        if arity.zero?
          lambda do |_interp, input, path, _args, _env, &blk|
            blk.call(impl.call(input), path && INVALID)
          end
        else
          lambda do |interp, input, path, args, env, &blk|
            interp.each_args(args, input, env) do |a|
              blk.call(impl.call(input, *a), path && INVALID)
            end
          end
        end
    end

    def err(msg)
      raise JQError, msg
    end

    def num(v, name = nil)
      return v if Value.number?(v)

      err("#{Value.desc(v)} number required")
    end

    # --------------------------------------------------------------- core

    special('empty', 0) { |*| nil }

    special('error', 0) { |_i, input, *| raise JQError.new(input) }

    special('error', 1) do |interp, input, _path, args, env|
      interp.each_args(args, input, env) { |(msg)| raise JQError.new(msg) }
    end

    special('not', 0) { |_i, input, path, _a, _e, &blk| blk.call(!Value.truthy?(input), path && INVALID) }

    special('path', 1) do |interp, input, path, args, env, &blk|
      interp.eval_node(args[0], input, [], env) do |v, p|
        interp.check_path!(v, p)
        blk.call(p, path && INVALID)
      end
    end

    special('getpath', 1) do |interp, input, path, args, env, &blk|
      interp.each_args(args, input, env) do |(p)|
        v = begin
          Ops.getpath(input, p)
        rescue JQError
          raise unless p.is_a?(Array)

          raise
        end
        if path
          interp.check_path!(input, path)
          blk.call(v, path + p)
        else
          blk.call(v, nil)
        end
      end
    end

    fn('setpath', 2) { |input, p, v| Ops.setpath(input, p, v) }
    fn('delpaths', 1) { |input, ps| Ops.delpaths(input, ps) }

    special('select', 1) do |interp, input, path, args, env, &blk|
      interp.eval_node(args[0], input, nil, env) do |c|
        blk.call(input, path) if Value.truthy?(c)
      end
    end

    special('recurse', 0) do |_interp, input, path, _args, _env, &blk|
      stack = [[input, path]]
      until stack.empty?
        v, p = stack.pop
        blk.call(v, p)
        case v
        when Array
          (v.length - 1).downto(0) { |i| stack.push([v[i], p && p + [i]]) }
        when Hash
          v.keys.reverse_each { |k| stack.push([v[k], p && p + [k]]) }
        end
      end
    end

    special('recurse', 1) do |interp, input, path, args, env, &blk|
      f = args[0]
      stack = [[input, path]]
      until stack.empty?
        v, p = stack.pop
        blk.call(v, p)
        children = []
        interp.eval_node(f, v, p, env) { |cv, cp| children << [cv, cp] }
        children.reverse_each { |c| stack.push(c) }
      end
    end

    special('repeat', 1) do |interp, input, path, args, env, &blk|
      f = args[0]
      stack = [[input, path]]
      until stack.empty?
        v, p = stack.pop
        blk.call(v, p)
        children = []
        interp.eval_node(f, v, p, env) { |cv, cp| children << [cv, cp] }
        children.reverse_each { |c| stack.push(c) }
      end
    end

    special('while', 2) do |interp, input, path, args, env, &blk|
      cond, update = args
      stack = [[input, path]]
      until stack.empty?
        v, p = stack.pop
        items = []
        interp.eval_node(cond, v, nil, env) do |c|
          next unless Value.truthy?(c)

          items << [:emit, v, p]
          interp.eval_node(update, v, p, env) { |uv, up| items << [:eval, uv, up] }
        end
        # process in order: emit first, then recurse into each update result
        work = []
        items.each { |it| work << it }
        work.reverse_each do |kind, wv, wp|
          if kind == :emit
            stack.push([:emit, wv, wp])
          else
            stack.push([wv, wp])
          end
        end
        while !stack.empty? && stack.last[0] == :emit
          _, ev, ep = stack.pop
          blk.call(ev, ep)
        end
      end
    end

    special('until', 2) do |interp, input, path, args, env, &blk|
      cond, update = args
      stack = [[input, path]]
      until stack.empty?
        top = stack.pop
        if top[0] == :emit
          blk.call(top[1], top[2])
          next
        end
        v, p = top
        items = []
        interp.eval_node(cond, v, nil, env) do |c|
          if Value.truthy?(c)
            items << [:emit, v, p]
          else
            interp.eval_node(update, v, p, env) { |uv, up| items << [uv, up] }
          end
        end
        items.reverse_each { |it| stack.push(it) }
      end
    end

    special('range', 1) do |interp, input, path, args, env, &blk|
      inv = path && INVALID
      interp.eval_node(args[0], input, nil, env) do |n|
        num(n)
        i = 0
        while i < n
          blk.call(i, inv)
          i += 1
        end
      end
    end

    special('range', 2) do |interp, input, path, args, env, &blk|
      inv = path && INVALID
      interp.eval_node(args[0], input, nil, env) do |from|
        interp.eval_node(args[1], input, nil, env) do |upto|
          err('Range bounds must be numeric') unless Value.number?(from) && Value.number?(upto)
          i = from
          while i < upto
            blk.call(i, inv)
            i = Value.normalize_number(i + 1)
          end
        end
      end
    end

    special('range', 3) do |interp, input, path, args, env, &blk|
      inv = path && INVALID
      interp.eval_node(args[0], input, nil, env) do |from|
        interp.eval_node(args[1], input, nil, env) do |upto|
          interp.eval_node(args[2], input, nil, env) do |by|
            err('Range bounds must be numeric') unless [from, upto, by].all? { |x| Value.number?(x) }
            i = from
            if by.positive?
              while i < upto
                blk.call(i, inv)
                i = Value.normalize_number(i + by)
              end
            elsif by.negative?
              while i > upto
                blk.call(i, inv)
                i = Value.normalize_number(i + by)
              end
            end
          end
        end
      end
    end

    special('limit', 2) do |interp, input, path, args, env, &blk|
      interp.eval_node(args[0], input, nil, env) do |n|
        num(n)
        if n.positive?
          count = 0
          tag = Object.new
          catch(tag) do
            interp.eval_node(args[1], input, path, env) do |v, p|
              count += 1
              blk.call(v, p)
              throw tag if count >= n
            end
          end
        elsif n.negative?
          interp.eval_node(args[1], input, path, env, &blk)
        end
      end
    end

    special('first', 1) do |interp, input, path, args, env, &blk|
      tag = Object.new
      got = nil
      catch(tag) do
        interp.eval_node(args[0], input, path, env) do |v, p|
          got = [v, p]
          throw tag
        end
      end
      blk.call(*got) if got
    end

    special('isempty', 1) do |interp, input, path, args, env, &blk|
      found, = interp.first_value(args[0], input, env)
      blk.call(!found, path && INVALID)
    end

    special('input', 0) do |interp, _input, path, _args, _env, &blk|
      blk.call(interp.next_input, path && INVALID)
    end

    special('inputs', 0) do |interp, _input, path, _args, _env, &blk|
      provider = interp.input_provider
      next unless provider

      loop do
        v = provider.call
        break if v.equal?(JSONParser::EOF)

        blk.call(v, path && INVALID)
      end
    end

    special('debug', 0) do |interp, input, path, _args, _env, &blk|
      (interp.options[:stderr] || $stderr).write("#{Encoder.dump(['DEBUG:', input])}\n")
      blk.call(input, path)
    end

    special('stderr', 0) do |interp, input, path, _args, _env, &blk|
      (interp.options[:stderr] || $stderr).write(Encoder.dump(input))
      blk.call(input, path)
    end

    special('input_filename', 0) do |interp, _input, path, _args, _env, &blk|
      blk.call(interp.current_filename, path && INVALID)
    end

    fn('input_line_number', 0) { |_| 0 }

    special('halt', 0) { |*| raise HaltError.new(nil, 0, false) }

    special('halt_error', 1) do |interp, input, _path, args, env|
      interp.each_args(args, input, env) do |(code)|
        err('halt_error/1: number required') unless Value.number?(code)
        raise HaltError.new(input, code.to_i, true)
      end
    end

    special('builtins', 0) do |_interp, _input, path, _args, _env, &blk|
      names = (NATIVES.keys + PRELUDE_KEYS).reject { |k| k.start_with?('_') }.uniq
      blk.call(names, path && INVALID)
    end

    fn('now', 0) { |_| Time.now.to_f }

    special('ltrimstr', 1) do |interp, input, path, args, env, &blk|
      interp.each_args(args, input, env) do |(pre)|
        r = input.is_a?(String) && pre.is_a?(String) && input.start_with?(pre) ? input[pre.length..] : input
        blk.call(r, path && INVALID)
      end
    end

    special('rtrimstr', 1) do |interp, input, path, args, env, &blk|
      interp.each_args(args, input, env) do |(suf)|
        r = if input.is_a?(String) && suf.is_a?(String) && input.end_with?(suf) && !suf.empty?
              input[0, input.length - suf.length]
            else
              input
            end
        blk.call(r, path && INVALID)
      end
    end

    # ---------------------------------------------------------- types etc

    fn('type', 0) { |v| Value.type_name(v) }

    fn('length', 0) do |v|
      case v
      when nil then 0
      when true, false then err("#{Value.desc(v)} has no length")
      when Integer, Float then Value.normalize_number(v.abs)
      when String, Array, Hash then v.length
      end
    end

    fn('utf8bytelength', 0) do |v|
      err("#{Value.desc(v)} only strings have UTF-8 byte length") unless v.is_a?(String)
      v.bytesize
    end

    fn('keys', 0) do |v|
      case v
      when Hash then v.keys.sort_by(&:b)
      when Array then (0...v.length).to_a
      else err("#{Value.desc(v)} has no keys")
      end
    end

    fn('keys_unsorted', 0) do |v|
      case v
      when Hash then v.keys
      when Array then (0...v.length).to_a
      else err("#{Value.desc(v)} has no keys")
      end
    end

    fn('has', 1) do |v, k|
      if v.is_a?(Hash) && k.is_a?(String)
        v.key?(k)
      elsif v.is_a?(Array) && Value.number?(k)
        k >= 0 && k < v.length
      elsif v.nil?
        false
      else
        err("Cannot check whether #{Value.type_name(v)} has a #{Value.type_name(k)} key")
      end
    end

    fn('contains', 1) do |a, b|
      if Value.kind_order(a) != Value.kind_order(b)
        err("#{Value.desc(a)} and #{Value.desc(b)} cannot have their containment checked")
      end

      contains?(a, b)
    end

    def contains?(a, b)
      if a.is_a?(Hash) && b.is_a?(Hash)
        b.all? { |k, bv| a.key?(k) && contains?(a[k], bv) }
      elsif a.is_a?(Array) && b.is_a?(Array)
        b.all? { |bv| a.any? { |av| contains?(av, bv) } }
      elsif a.is_a?(String) && b.is_a?(String)
        a.include?(b)
      elsif Value.kind_order(a) == Value.kind_order(b)
        Value.equal?(a, b)
      else
        false
      end
    end

    fn('add', 0) do |v|
      vals = case v
             when Array then v
             when Hash then v.values
             when nil then []
             else err("Cannot iterate over #{Value.desc(v)}")
             end
      vals.reduce(nil) { |acc, x| Ops.add(acc, x) }
    end

    fn('tostring', 0) { |v| Ops.tostring(v) }
    fn('tojson', 0) { |v| Encoder.dump(v) }

    fn('fromjson', 0) do |v|
      err("#{Value.desc(v)} only strings can be parsed") unless v.is_a?(String)
      begin
        JSONParser.parse(v)
      rescue ParseError => e
        msg = e.message
        msg += " (while parsing '#{v}')" unless msg.include?('while parsing')
        err(msg)
      end
    end

    fn('tonumber', 0) do |v|
      case v
      when Integer, Float then v
      when String
        s = v.strip
        if s == 'nan' || s == 'NaN'
          Float::NAN
        elsif s.match?(/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/) ||
              s.match?(/\A-?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/)
          if s.match?(/[.eE]/)
            f = Float(s.sub(/\A(-?)\./, '\10.').sub(/\.(?![0-9])/, '.0'))
            f = f.positive? ? Float::MAX : -Float::MAX if f.infinite?
            Value.normalize_number(f)
          else
            Integer(s, 10)
          end
        else
          err("Cannot parse '#{v}' as JSON")
        end
      else
        err("#{Value.desc(v)} cannot be parsed as a number")
      end
    end

    fn('ascii_downcase', 0) do |v|
      err("#{Value.desc(v)} cannot be lowercased") unless v.is_a?(String)
      v.tr('A-Z', 'a-z')
    end

    fn('ascii_upcase', 0) do |v|
      err("#{Value.desc(v)} cannot be uppercased") unless v.is_a?(String)
      v.tr('a-z', 'A-Z')
    end

    fn('explode', 0) do |v|
      err("#{Value.desc(v)} cannot be exploded, as it is not a string") unless v.is_a?(String)
      v.codepoints
    end

    fn('implode', 0) do |v|
      err("#{Value.desc(v)} cannot be imploded, as it is not an array") unless v.is_a?(Array)
      v.map do |cp|
        err("Unicode codepoint must be numeric") unless Value.number?(cp)
        cp = cp.to_i
        cp = 0xFFFD if cp.negative? || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)
        cp.chr(Encoding::UTF_8)
      end.join.force_encoding(Encoding::UTF_8)
    end

    fn('startswith', 1) do |v, s|
      err('startswith() requires string inputs') unless v.is_a?(String) && s.is_a?(String)
      v.start_with?(s)
    end

    fn('endswith', 1) do |v, s|
      err('endswith() requires string inputs') unless v.is_a?(String) && s.is_a?(String)
      v.end_with?(s)
    end

    WS_L = /\A[ \t\n\r\f\v]+/
    WS_R = /[ \t\n\r\f\v]+\z/

    fn('trim', 0) do |v|
      err("#{Value.desc(v)} cannot be trimmed") unless v.is_a?(String)
      v.sub(WS_L, '').sub(WS_R, '')
    end

    fn('ltrim', 0) do |v|
      err("#{Value.desc(v)} cannot be trimmed") unless v.is_a?(String)
      v.sub(WS_L, '')
    end

    fn('rtrim', 0) do |v|
      err("#{Value.desc(v)} cannot be trimmed") unless v.is_a?(String)
      v.sub(WS_R, '')
    end

    fn('split', 1) do |v, sep|
      err('split input and separator must be strings') unless v.is_a?(String) && sep.is_a?(String)
      Ops.split_string(v, sep)
    end

    fn('join', 1) do |v, sep|
      vals = case v
             when Array then v
             when Hash then v.values
             else err("Cannot iterate over #{Value.desc(v)}")
             end
      acc = nil
      vals.each do |x|
        acc = acc.nil? ? '' : Ops.add(acc, sep)
        s = case x
            when nil then ''
            when String then x
            else Encoder.dump(x)
            end
        acc = Ops.add(acc, s)
      end
      acc.nil? ? '' : acc
    end

    def flatten(arr, depth)
      arr.each_with_object([]) do |x, out|
        if x.is_a?(Array) && depth != 0
          out.concat(flatten(x, depth - 1))
        else
          out << x
        end
      end
    end

    fn('flatten', 0) do |v|
      err("Cannot iterate over #{Value.desc(v)}") unless v.is_a?(Array)
      flatten(v, -1)
    end

    fn('flatten', 1) do |v, d|
      err('flatten depth must not be negative') if Value.number?(d) && d.negative?
      err("Cannot iterate over #{Value.desc(v)}") unless v.is_a?(Array)
      flatten(v, d.to_i)
    end

    def require_array(v, what)
      err("#{Value.desc(v)} cannot be #{what}, as it is not an array") unless v.is_a?(Array)
    end

    fn('sort', 0) do |v|
      require_array(v, 'sorted')
      Value.sort(v)
    end

    def sort_by_keys(v, keys)
      require_array(v, 'sorted')
      v.each_with_index.sort do |(_, i), (_, j)|
        c = Value.compare(keys[i], keys[j])
        c.zero? ? i <=> j : c
      end.map { |(x, i)| [x, keys[i]] }
    end

    fn('_sort_by_impl', 1) { |v, keys| sort_by_keys(v, keys).map(&:first) }

    fn('_group_by_impl', 1) do |v, keys|
      groups = []
      last = nil
      sort_by_keys(v, keys).each do |x, k|
        if groups.empty? || !Value.equal?(last, k)
          groups << [x]
          last = k
        else
          groups.last << x
        end
      end
      groups
    end

    fn('_unique_by_impl', 1) do |v, keys|
      out = []
      last = nil
      first = true
      sort_by_keys(v, keys).each do |x, k|
        if first || !Value.equal?(last, k)
          out << x
          last = k
          first = false
        end
      end
      out
    end

    fn('_min_by_impl', 1) do |v, keys|
      require_array(v, 'iterated over')
      best = nil
      bk = nil
      v.each_with_index do |x, i|
        if i.zero? || Value.compare(keys[i], bk).negative?
          best = x
          bk = keys[i]
        end
      end
      best
    end

    fn('_max_by_impl', 1) do |v, keys|
      require_array(v, 'iterated over')
      best = nil
      bk = nil
      v.each_with_index do |x, i|
        if i.zero? || Value.compare(keys[i], bk) >= 0
          best = x
          bk = keys[i]
        end
      end
      best
    end

    fn('min', 0) do |v|
      require_array(v, 'iterated over')
      v.each_with_index.reduce(nil) { |m, (x, i)| i.zero? || Value.compare(x, m).negative? ? x : m }
    end

    fn('max', 0) do |v|
      require_array(v, 'iterated over')
      v.each_with_index.reduce(nil) { |m, (x, i)| i.zero? || Value.compare(x, m) >= 0 ? x : m }
    end

    fn('unique', 0) do |v|
      require_array(v, 'sorted')
      out = []
      Value.sort(v).each { |x| out << x if out.empty? || !Value.equal?(out.last, x) }
      out
    end

    fn('indices', 1) do |v, i|
      case v
      when nil then nil
      when String
        err("Cannot determine indices of #{Value.desc(i)} in a string") unless i.is_a?(String)
        if i.empty?
          nil
        else
          out = []
          pos = 0
          while (idx = v.index(i, pos))
            out << idx
            pos = idx + 1
          end
          out
        end
      when Array
        i.is_a?(Array) ? Ops.indices_of(v, i) : Ops.indices_of(v, [i])
      else
        Ops.index(v, i)
      end
    end

    fn('to_entries', 0) do |v|
      case v
      when Hash then v.map { |k, x| { 'key' => k, 'value' => x } }
      when Array then v.each_with_index.map { |x, i| { 'key' => i, 'value' => x } }
      else err("#{Value.desc(v)} has no keys")
      end
    end

    fn('from_entries', 0) do |v|
      vals = case v
             when Array then v
             when Hash then v.values
             else err("Cannot iterate over #{Value.desc(v)}")
             end
      vals.each_with_object({}) do |e, h|
        k = nil
        val = nil
        if e.is_a?(Hash)
          k = e['key']
          if k.nil? || k == false && !e.key?('key')
            k = %w[k name Name K Key].map { |n| e[n] }.find { |x| Value.truthy?(x) }
          end
          val = e.key?('value') ? e['value'] : e['v']
        elsif e.nil?
          k = nil
        else
          Ops.index(e, 'key')
        end
        k = case k
            when String then k
            when Integer, Float, true, false then Encoder.dump(k)
            else err("Cannot use #{Value.desc(k)} as object key")
            end
        h[k] = val
      end
    end

    fn('format', 1) do |v, f|
      err("#{Value.desc(f)} is not a valid format") unless f.is_a?(String)
      Formats.apply(f, v)
    end

    fn('infinite', 0) { |_| Float::INFINITY }
    fn('nan', 0) { |_| Float::NAN }
    fn('isinfinite', 0) { |v| num(v).is_a?(Float) && v.infinite? ? true : false }
    fn('isnan', 0) { |v| num(v).is_a?(Float) && v.nan? }
    fn('isnormal', 0) do |v|
      num(v)
      f = v.to_f
      f.finite? && !f.zero? && f.abs >= Float::MIN
    end

    fn('abs', 0) do |v|
      err("#{Value.desc(v)} has no absolute value") unless Value.number?(v)
      v.negative? ? Value.normalize_number(-v) : v
    end

    fn('toarray', 0) { |v| v.is_a?(Array) ? v : [v] }
    fn('have_literal_numbers', 0) { |_| true }
    fn('have_decnum', 0) { |_| false }

    # ------------------------------------------------------------- math

    def mathcall
      r = yield
      r = r.to_f if r.is_a?(Rational)
      Value.normalize_number(r)
    rescue Math::DomainError
      Float::NAN
    rescue FloatDomainError
      Float::NAN
    end

    def round_half_even(f)
      return f unless f.finite?

      f.round(half: :even).to_f
    end

    MATH1 = {
      'floor' => ->(x) { x.is_a?(Integer) ? x : (x.finite? ? x.floor.to_f : x) },
      'ceil' => ->(x) { x.is_a?(Integer) ? x : (x.finite? ? x.ceil.to_f : x) },
      'round' => ->(x) { x.is_a?(Integer) ? x : (x.finite? ? x.round.to_f : x) },
      'trunc' => ->(x) { x.is_a?(Integer) ? x : (x.finite? ? x.truncate.to_f : x) },
      'nearbyint' => ->(x) { x.is_a?(Integer) ? x : Builtins.round_half_even(x) },
      'rint' => ->(x) { x.is_a?(Integer) ? x : Builtins.round_half_even(x) },
      'fabs' => ->(x) { x.abs },
      'sqrt' => ->(x) { Math.sqrt(x) },
      'cbrt' => ->(x) { Math.cbrt(x) },
      'exp' => ->(x) { Math.exp(x) },
      'exp2' => ->(x) { 2.0**x },
      'exp10' => ->(x) { 10.0**x },
      'pow10' => ->(x) { 10.0**x },
      'expm1' => ->(x) { x.abs < 1e-5 ? x + x * x / 2.0 + x * x * x / 6.0 : Math.exp(x) - 1 },
      'log' => ->(x) { x.zero? ? -Float::INFINITY : Math.log(x) },
      'log2' => ->(x) { x.zero? ? -Float::INFINITY : Math.log2(x) },
      'log10' => ->(x) { x.zero? ? -Float::INFINITY : Math.log10(x) },
      'log1p' => ->(x) { x.abs < 1e-5 ? x - x * x / 2.0 + x * x * x / 3.0 : Math.log(1 + x) },
      'logb' => ->(x) { x.zero? ? -Float::INFINITY : (x.to_f.finite? ? Math.frexp(x)[1] - 1 : x.abs.to_f) },
      'significand' => ->(x) { x.zero? || !x.to_f.finite? ? x : Math.frexp(x)[0] * 2 },
      'gamma' => ->(x) { Math.lgamma(x)[0] },
      'lgamma' => ->(x) { Math.lgamma(x)[0] },
      'tgamma' => ->(x) { Math.gamma(x) },
      'sin' => ->(x) { Math.sin(x) },
      'cos' => ->(x) { Math.cos(x) },
      'tan' => ->(x) { Math.tan(x) },
      'asin' => ->(x) { Math.asin(x) },
      'acos' => ->(x) { Math.acos(x) },
      'atan' => ->(x) { Math.atan(x) },
      'sinh' => ->(x) { Math.sinh(x) },
      'cosh' => ->(x) { Math.cosh(x) },
      'tanh' => ->(x) { Math.tanh(x) },
      'asinh' => ->(x) { Math.asinh(x) },
      'acosh' => ->(x) { Math.acosh(x) },
      'atanh' => ->(x) { Math.atanh(x) }
    }.freeze

    MATH1.each do |name, f|
      fn(name, 0) { |v| mathcall { f.call(num(v)) } }
    end

    fn('frexp', 0) do |v|
      num(v)
      f = v.to_f
      if f.zero? || !f.finite?
        [Value.normalize_number(f), 0]
      else
        m, e = Math.frexp(f)
        [Value.normalize_number(m), e]
      end
    end

    fn('modf', 0) do |v|
      num(v)
      f = v.to_f
      if f.infinite?
        [0.0, f]
      else
        i = f.truncate.to_f
        [Value.normalize_number(f - i), Value.normalize_number(i)]
      end
    end

    fn('lgamma_r', 0) do |v|
      r, s = Math.lgamma(num(v))
      [Value.normalize_number(r), s]
    end

    MATH2 = {
      'pow' => ->(a, b) { a.to_f**b },
      'atan2' => ->(a, b) { Math.atan2(a, b) },
      'fmin' => ->(a, b) { [a, b].min },
      'fmax' => ->(a, b) { [a, b].max },
      'fmod' => ->(a, b) { b.zero? ? Float::NAN : a.to_f.remainder(b) },
      'hypot' => ->(a, b) { Math.hypot(a, b) },
      'copysign' => ->(a, b) { (b.to_f.negative? || (b.to_f.zero? && (1.0 / b.to_f).negative?)) ? -a.to_f.abs : a.to_f.abs },
      'drem' => ->(a, b) { b.zero? ? Float::NAN : a - b * Builtins.round_half_even(a.to_f / b) },
      'fdim' => ->(a, b) { a > b ? a - b : 0 },
      'ldexp' => ->(a, b) { Math.ldexp(a, b.to_i) },
      'scalb' => ->(a, b) { a * (2.0**b) },
      'scalbln' => ->(a, b) { Math.ldexp(a, b.to_i) },
      'nextafter' => ->(a, b) { a == b ? b.to_f : (b > a ? a.to_f.next_float : a.to_f.prev_float) },
      'nexttoward' => ->(a, b) { a == b ? b.to_f : (b > a ? a.to_f.next_float : a.to_f.prev_float) }
    }.freeze

    MATH2.each do |name, f|
      fn(name, 2) { |_v, a, b| mathcall { f.call(num(a), num(b)) } }
    end

    fn('fma', 3) { |_v, a, b, c| mathcall { num(a) * num(b) + num(c) } }

    # ------------------------------------------------------------- regex

    REGEX_CACHE = {}

    def translate_regex(re)
      out = +''
      i = 0
      in_class = false
      has_named = re.match?(/\(\?<[a-zA-Z_]/) || re.match?(/\(\?P<[a-zA-Z_]/)
      gen = 0
      while i < re.length
        c = re[i]
        if c == '\\'
          out << re[i, 2]
          i += 2
          next
        end
        if in_class
          in_class = false if c == ']'
          out << c
        elsif c == '['
          in_class = true
          out << c
          if re[i + 1] == '^'
            out << '^'
            i += 1
          end
          if re[i + 1] == ']'
            out << ']'
            i += 1
          end
        elsif c == '^'
          out << '\\A'
        elsif c == '$'
          out << '\z'
        elsif c == '(' && has_named && re[i + 1] != '?'
          gen += 1
          out << "(?<__rbjq_#{gen}>"
        elsif c == '(' && re[i + 1, 3] == '?P<'
          out << '(?<'
          i += 3
        else
          out << c
        end
        i += 1
      end
      out
    end

    def compile_regex(re, flags)
      err("#{Value.desc(re)} cannot be matched, as it is not a string") unless re.is_a?(String)
      unless flags.nil? || flags.is_a?(String)
        err("#{Value.desc(flags)} is not a string")
      end

      key = [re, flags]
      cached = REGEX_CACHE[key]
      return cached if cached

      global = false
      noempty = false
      opts = 0
      (flags || '').each_char do |f|
        case f
        when 'g' then global = true
        when 'i' then opts |= Regexp::IGNORECASE
        when 'x' then opts |= Regexp::EXTENDED
        when 's' then nil
        when 'p' then opts |= Regexp::MULTILINE
        when 'n' then noempty = true
        when 'l' then nil
        else err("#{flags} is not a valid modifier string")
        end
      end
      begin
        regexp = Regexp.new(translate_regex(re), opts)
      rescue RegexpError => e
        err("#{re} (at offset 0) is not a valid regex: #{e.message}")
      end
      names = {}
      regexp.named_captures.each do |name, idxs|
        idxs.each { |i| names[i] = name.start_with?('__rbjq_') ? nil : name }
      end
      REGEX_CACHE.clear if REGEX_CACHE.size > 1000
      REGEX_CACHE[key] = [regexp, global, noempty, names]
    end

    def match_all(str, re, flags)
      err("#{Value.desc(str)} cannot be matched, as it is not a string") unless str.is_a?(String)
      regexp, global, noempty, names = compile_regex(re, flags)
      results = []
      pos = 0
      while pos <= str.length
        m = regexp.match(str, pos)
        break unless m

        if m[0].empty?
          results << m unless noempty
          pos = m.begin(0) + 1
        else
          results << m
          pos = m.end(0)
        end
        break unless global
      end
      [results, names]
    end

    def match_object(m, names)
      caps = (1...m.size).map do |i|
        if m[i].nil?
          { 'offset' => -1, 'string' => nil, 'length' => 0, 'name' => names[i] }
        else
          { 'offset' => m.begin(i), 'length' => m[i].length, 'string' => m[i], 'name' => names[i] }
        end
      end
      { 'offset' => m.begin(0), 'length' => m[0].length, 'string' => m[0], 'captures' => caps }
    end

    fn('_match_impl', 3) do |v, re, flags, test|
      if test
        err("#{Value.desc(v)} cannot be matched, as it is not a string") unless v.is_a?(String)
        regexp, = compile_regex(re, flags)
        regexp.match?(v)
      else
        ms, names = match_all(v, re, flags)
        ms.map { |m| match_object(m, names) }
      end
    end

    def capture_object(m, names)
      h = {}
      (1...m.size).each do |i|
        n = names[i]
        h[n] = m[i] if n
      end
      h
    end

    def sub_impl(interp, input, path, str_node, env, re, flags, &blk)
      ms, names = match_all(input, re, flags)
      if ms.empty?
        blk.call(input, path && INVALID)
        return
      end
      gen = lambda do |i, acc, prev|
        if i == ms.size
          blk.call(acc + input[prev..], path && INVALID)
          return
        end
        m = ms[i]
        interp.eval_node(str_node, capture_object(m, names), nil, env) do |s|
          err("#{Value.desc(acc)} and #{Value.desc(s)} cannot be added") unless s.is_a?(String)
          gen.call(i + 1, acc + input[prev...m.begin(0)] + s, m.end(0))
        end
      end
      gen.call(0, +'', 0)
    end

    special('sub', 2) do |interp, input, path, args, env, &blk|
      interp.eval_node(args[0], input, nil, env) do |re|
        sub_impl(interp, input, path, args[1], env, re, nil, &blk)
      end
    end

    special('sub', 3) do |interp, input, path, args, env, &blk|
      interp.eval_node(args[2], input, nil, env) do |flags|
        interp.eval_node(args[0], input, nil, env) do |re|
          sub_impl(interp, input, path, args[1], env, re, flags, &blk)
        end
      end
    end

    special('gsub', 2) do |interp, input, path, args, env, &blk|
      interp.eval_node(args[0], input, nil, env) do |re|
        sub_impl(interp, input, path, args[1], env, re, 'g', &blk)
      end
    end

    special('gsub', 3) do |interp, input, path, args, env, &blk|
      interp.eval_node(args[2], input, nil, env) do |flags|
        interp.eval_node(args[0], input, nil, env) do |re|
          sub_impl(interp, input, path, args[1], env, re, "#{flags}g", &blk)
        end
      end
    end

    fn('split', 2) do |v, re, flags|
      ms, = match_all(v, re, "#{flags}g")
      out = []
      prev = 0
      ms.each do |m|
        out << v[prev...m.begin(0)]
        prev = m.end(0)
      end
      out << v[prev..]
      out
    end

    # -------------------------------------------------------------- dates

    def broken_down(t, frac = 0)
      sec = t.sec + frac
      [t.year, t.month - 1, t.day, t.hour, t.min, Value.normalize_number(sec), t.wday, t.yday - 1]
    end

    def time_from_number(n, local: false)
      i = n.floor
      frac = n - i
      t = Time.at(i)
      t = local ? t.localtime : t.utc
      [t, Value.normalize_number(frac)]
    end

    def days_from_civil(y, m, d)
      y -= 1 if m <= 2
      era = (y >= 0 ? y : y - 399) / 400
      yoe = y - era * 400
      doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
      doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
      era * 146_097 + doe - 719_468
    end

    def timegm(bd)
      unless bd.is_a?(Array) && bd.length >= 6 && bd[0, 6].all? { |x| Value.number?(x) }
        err('mktime requires array of 6 numbers')
      end
      y, mon, d, h, mi, s = bd[0, 6].map { |x| x.floor }
      y += mon.div(12)
      mon %= 12
      days = days_from_civil(y, mon + 1, 1) + (d - 1)
      days * 86_400 + h * 3600 + mi * 60 + s
    end

    def time_from_broken_down(bd, local: false)
      err('strftime/1 requires parsed datetime inputs') unless bd.is_a?(Array) && bd.length >= 6 && bd[0, 6].all? { |x| Value.number?(x) }
      secs = timegm(bd)
      if local
        y, mon, d, h, mi, s = bd[0, 6].map(&:floor)
        Time.local(y, mon + 1, d, h, mi, s)
      else
        Time.at(secs).utc
      end
    end

    fn('gmtime', 0) do |v|
      err('gmtime() requires a number') unless Value.number?(v)
      t, frac = time_from_number(v)
      broken_down(t, frac)
    end

    fn('localtime', 0) do |v|
      err('localtime() requires a number') unless Value.number?(v)
      t, frac = time_from_number(v, local: true)
      broken_down(t, frac)
    end

    fn('mktime', 0) do |v|
      err('mktime requires array of 6 numbers') unless v.is_a?(Array)
      timegm(v)
    end

    fn('strftime', 1) do |v, fmt|
      err('strftime/1 requires a string format') unless fmt.is_a?(String)
      t = if Value.number?(v)
            time_from_number(v)[0]
          else
            time_from_broken_down(v)
          end
      t.strftime(fmt)
    end

    fn('strflocaltime', 1) do |v, fmt|
      err('strflocaltime/1 requires a string format') unless fmt.is_a?(String)
      t = if Value.number?(v)
            time_from_number(v, local: true)[0]
          else
            time_from_broken_down(v, local: true)
          end
      t.strftime(fmt)
    end

    fn('strptime', 1) do |v, fmt|
      err("strptime/1 requires string inputs and arguments") unless v.is_a?(String) && fmt.is_a?(String)
      h = Date._strptime(v, fmt)
      err("date \"#{v}\" does not match format \"#{fmt}\"") if h.nil? || h.key?(:leftover)
      t = if h[:seconds]
            Time.at(h[:seconds]).utc
          else
            Time.utc(h[:year] || 1900, h[:mon] || 1, h[:mday] || 1, h[:hour] || 0, h[:min] || 0, h[:sec] || 0)
          end
      broken_down(t)
    end
  end
end
