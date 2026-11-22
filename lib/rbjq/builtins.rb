# frozen_string_literal: true

require 'date'
require 'time'
require_relative 'bessel'

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

    # Same behavior as jq 1.7.1, whose manual tests expect
    # `[repeat(.*2, error)?]` on 1 to give [2]: the outputs of f applied to
    # the input are produced over and over.
    special('repeat', 1) do |interp, input, path, args, env, &blk|
      loop { interp.eval_node(args[0], input, path, env, &blk) }
    end

    special('nth', 2) do |interp, input, path, args, env, &blk|
      interp.eval_node(args[0], input, nil, env) do |n|
        num(n)
        err("nth doesn't support negative indices") if n.negative?

        count = 0
        tag = Object.new
        catch(tag) do
          interp.eval_node(args[1], input, path, env) do |v, p|
            if count >= n
              blk.call(v, p)
              throw tag
            end
            count += 1
          end
        end
      end
    end

    fn('bsearch', 1) do |v, target|
      err("#{Value.desc(v)} cannot be searched from") unless v.is_a?(Array)
      lo = 0
      hi = v.length - 1
      found = nil
      while lo <= hi
        mid = (lo + hi) / 2
        c = Value.compare(v[mid], target)
        if c.zero?
          found = mid
          break
        elsif c.negative?
          lo = mid + 1
        else
          hi = mid - 1
        end
      end
      found || -1 - lo
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
        err('Range bounds must be numeric') unless Value.number?(n)
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
          err("limit doesn't support negative count")
        end
      end
    end

    special('skip', 2) do |interp, input, path, args, env, &blk|
      interp.eval_node(args[0], input, nil, env) do |n|
        num(n)
        err("skip doesn't support negative count") if n.negative?

        count = 0
        interp.eval_node(args[1], input, path, env) do |v, p|
          blk.call(v, p) if count >= n
          count += 1
        end
      end
    end

    special('last', 1) do |interp, input, path, args, env, &blk|
      got = nil
      interp.eval_node(args[0], input, nil, env) { |v| got = [v] }
      blk.call(got[0], path && INVALID) if got
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

    special('input_line_number', 0) do |interp, _input, path, _args, _env, &blk|
      blk.call(interp.options[:line_proc]&.call || 0, path && INVALID)
    end

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

    special('get_jq_origin', 0) do |interp, _input, path, _args, _env, &blk|
      blk.call(interp.options.fetch(:jq_origin) { File.expand_path('../../exe', __dir__) }, path && INVALID)
    end

    special('get_prog_origin', 0) do |interp, _input, path, _args, _env, &blk|
      blk.call(interp.options.fetch(:prog_origin) { Dir.pwd }, path && INVALID)
    end

    def ltrimstr(v, pre)
      err('startswith() requires string inputs') unless v.is_a?(String) && pre.is_a?(String)
      v.start_with?(pre) ? v[pre.length..] : v
    end

    def rtrimstr(v, suf)
      err('endswith() requires string inputs') unless v.is_a?(String) && suf.is_a?(String)
      v.end_with?(suf) ? v[0, v.length - suf.length] : v
    end

    fn('ltrimstr', 1) { |v, pre| ltrimstr(v, pre) }
    fn('rtrimstr', 1) { |v, suf| rtrimstr(v, suf) }
    fn('trimstr', 1) { |v, x| rtrimstr(ltrimstr(v, x), x) }

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

    def contains?(a, b, depth = 0)
      if (a.is_a?(Hash) || a.is_a?(Array)) && depth > Value::MAX_DEPTH
        err('Containment check too deep')
      end

      if a.is_a?(Hash) && b.is_a?(Hash)
        b.all? { |k, bv| a.key?(k) && contains?(a[k], bv, depth + 1) }
      elsif a.is_a?(Array) && b.is_a?(Array)
        b.all? { |bv| a.any? { |av| contains?(av, bv, depth + 1) } }
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

    TONUMBER_RE = /\A[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/

    fn('tonumber', 0) do |v|
      next v if Value.number?(v)

      err("#{Value.desc(v)} cannot be parsed as a number") unless v.is_a?(String)
      case v
      when 'nan', 'NaN', '-nan', '-NaN' then Float::NAN
      when 'infinity', 'Infinity' then Float::MAX
      when '-infinity', '-Infinity' then -Float::MAX
      else
        err("#{Value.desc(v)} cannot be parsed as a number") unless v.match?(TONUMBER_RE)
        JSONParser.new(v).send(:parse_number, v)
      end
    end

    fn('toboolean', 0) do |v|
      case v
      when true, false then v
      when 'true' then true
      when 'false' then false
      else err("#{Value.desc(v)} cannot be parsed as a boolean")
      end
    end

    fn('ascii_downcase', 0) do |v|
      err('explode input must be a string') unless v.is_a?(String)
      v.tr('A-Z', 'a-z')
    end

    fn('ascii_upcase', 0) do |v|
      err('explode input must be a string') unless v.is_a?(String)
      v.tr('a-z', 'A-Z')
    end

    fn('explode', 0) do |v|
      err('explode input must be a string') unless v.is_a?(String)
      v.codepoints
    end

    fn('implode', 0) do |v|
      err('implode input must be an array') unless v.is_a?(Array)
      v.map do |cp|
        unless Value.number?(cp) && !(cp.is_a?(Float) && cp.nan?)
          err("#{Value.desc(cp)} can't be imploded, unicode codepoint needs to be numeric")
        end

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

    WS_CHARS = "\t\n\v\f\r \u0085   -     　"
    WS_L = /\A[#{WS_CHARS}]+/
    WS_R = /[#{WS_CHARS}]+\z/

    def trim_input(v)
      err('trim input must be a string') unless v.is_a?(String)
      v
    end

    fn('trim', 0) { |v| trim_input(v).sub(WS_L, '').sub(WS_R, '') }
    fn('ltrim', 0) { |v| trim_input(v).sub(WS_L, '') }
    fn('rtrim', 0) { |v| trim_input(v).sub(WS_R, '') }

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
            when true, false, Integer, Float then Encoder.dump(x)
            else x # arrays and objects make the addition fail, like jq
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

    def flatten_input(v)
      case v
      when Array then v
      when Hash then v.values
      else err("Cannot iterate over #{Value.desc(v)}")
      end
    end

    fn('flatten', 0) { |v| flatten(flatten_input(v), -1) }

    fn('flatten', 1) do |v, d|
      err('flatten depth must not be negative') if Value.number?(d) && d.negative?
      flatten(flatten_input(v), d.to_i)
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
      not_iterable(v, keys) unless v.is_a?(Array)
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
      not_iterable(v, keys) unless v.is_a?(Array)
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

    def not_iterable(v, keys = v)
      err("#{Value.desc(v)} and #{Value.desc(keys)} cannot be iterated over")
    end

    fn('min', 0) do |v|
      not_iterable(v) unless v.is_a?(Array)
      v.each_with_index.reduce(nil) { |m, (x, i)| i.zero? || Value.compare(x, m).negative? ? x : m }
    end

    fn('max', 0) do |v|
      not_iterable(v) unless v.is_a?(Array)
      v.each_with_index.reduce(nil) { |m, (x, i)| i.zero? || Value.compare(x, m) >= 0 ? x : m }
    end

    fn('unique', 0) do |v|
      require_array(v, 'sorted')
      out = []
      Value.sort(v).each { |x| out << x if out.empty? || !Value.equal?(out.last, x) }
      out
    end

    # codepoint offsets of every (possibly overlapping) occurrence
    def strindices(v, i)
      out = []
      return out if i.empty?

      pos = 0
      while (idx = v.index(i, pos))
        out << idx
        pos = idx + 1
      end
      out
    end

    fn('_strindices', 1) do |v, i|
      err("#{Value.desc(v)} cannot be searched, as it is not a string") unless v.is_a?(String)
      err("#{Value.desc(i)} is not a string") unless i.is_a?(String)
      strindices(v, i)
    end

    # def indices($i): if type == "array" and ($i|type) == "array" then .[$i]
    #   elif type == "array" then .[[$i]]
    #   elif type == "string" and ($i|type) == "string" then _strindices($i)
    #   else .[$i] end;
    fn('indices', 1) do |v, i|
      if v.is_a?(Array)
        Ops.index(v, i.is_a?(Array) ? i : [i])
      elsif v.is_a?(String) && i.is_a?(String)
        strindices(v, i)
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
        k = %w[key Key name Name].reduce(nil) { |acc, n| Value.truthy?(acc) ? acc : Ops.index(e, n) }
        err("Cannot use #{Value.desc(k)} as object key") unless k.is_a?(String)
        has_value = case e
                    when Hash then e.key?('value')
                    when nil then false
                    else err("Cannot check whether #{Value.type_name(e)} has a string key")
                    end
        h[k] = has_value ? e['value'] : Ops.index(e, 'Value')
      end
    end

    fn('format', 1) do |v, f|
      err("#{Value.desc(f)} is not a valid format") unless f.is_a?(String)
      Formats.apply(f, v)
    end

    fn('infinite', 0) { |_| Float::INFINITY }
    fn('nan', 0) { |_| Float::NAN }
    fn('isinfinite', 0) { |v| v.is_a?(Float) && v.infinite? ? true : false }
    fn('isnan', 0) { |v| v.is_a?(Float) && v.nan? }
    fn('isnormal', 0) do |v|
      next false unless Value.number?(v)

      f = v.to_f
      f.finite? && !f.zero? && f.abs >= Float::MIN
    end

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

    # Kahan's accurate expm1 / log1p
    def expm1(x)
      # |x| <= 1: sum the series exactly so that the result is correctly rounded
      if x.finite? && x.abs <= 1
        return x if x.zero?

        r = Rational(x)
        term = r
        sum = r
        k = 1
        while term.abs > sum.abs * Rational(1, 10**25)
          k += 1
          term = term * r / k
          sum += term
        end
        return sum.to_f
      end

      u = Math.exp(x)
      return x if u == 1.0
      return -1.0 if u - 1.0 == -1.0
      return u if u.infinite?

      (u - 1.0) * x / Math.log(u)
    end

    def log1p(x)
      u = 1.0 + x
      return x if u == 1.0
      return Math.log(u) if u.infinite? || u <= 0

      Math.log(u) * x / (u - 1.0)
    end

    # C rounding functions keep the sign of zero: ceil(-0.5) is -0
    def signed(x, r)
      r.zero? && (x.negative? || (x.zero? && (1.0 / x).negative?)) ? -0.0 : r
    end

    def round_half_even(f)
      return f unless f.finite?

      f.round(half: :even).to_f
    end

    MATH1 = {
      'floor' => ->(x) { x.is_a?(Integer) ? x : (x.finite? ? x.floor.to_f : x) },
      'ceil' => ->(x) { x.is_a?(Integer) ? x : Builtins.signed(x, x.finite? ? x.ceil.to_f : x) },
      'round' => ->(x) { x.is_a?(Integer) ? x : Builtins.signed(x, x.finite? ? x.round.to_f : x) },
      'trunc' => ->(x) { x.is_a?(Integer) ? x : Builtins.signed(x, x.finite? ? x.truncate.to_f : x) },
      'nearbyint' => ->(x) { x.is_a?(Integer) ? x : Builtins.signed(x, Builtins.round_half_even(x)) },
      'rint' => ->(x) { x.is_a?(Integer) ? x : Builtins.signed(x, Builtins.round_half_even(x)) },
      'fabs' => ->(x) { x.abs },
      'sqrt' => ->(x) { Math.sqrt(x) },
      'cbrt' => ->(x) { Math.cbrt(x) },
      'exp' => ->(x) { Math.exp(x) },
      'exp2' => ->(x) { 2.0**x },
      'exp10' => ->(x) { 10.0**x },
      'erf' => ->(x) { Math.erf(x) },
      'erfc' => ->(x) { Math.erfc(x) },
      'j0' => ->(x) { Bessel.jn(0, x) },
      'j1' => ->(x) { Bessel.jn(1, x) },
      'y0' => ->(x) { Bessel.y0(x) },
      'y1' => ->(x) { Bessel.y1(x) },
      'expm1' => ->(x) { Builtins.expm1(x.to_f) },
      'log' => ->(x) { x.zero? ? -Float::INFINITY : Math.log(x) },
      'log2' => ->(x) { x.zero? ? -Float::INFINITY : Math.log2(x) },
      'log10' => ->(x) { x.zero? ? -Float::INFINITY : Math.log10(x) },
      'log1p' => ->(x) { Builtins.log1p(x.to_f) },
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
      'remainder' => ->(a, b) { b.zero? ? Float::NAN : a - b * Builtins.round_half_even(a.to_f / b) },
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
    fn('jn', 2) { |_v, n, x| mathcall { Bessel.jn(num(n), num(x)) } }
    fn('yn', 2) { |_v, n, x| mathcall { Bessel.yn(num(n), num(x)) } }

    # ------------------------------------------------------------- regex

    REGEX_CACHE = {}

    def translate_regex(re)
      out = +''
      i = 0
      in_class = false
      has_named = re.match?(/\(\?<[a-zA-Z_]/)
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
            out << '\]' # a leading ] belongs to the class
            i += 1
          end
        elsif c == '^'
          out << '\\A'
        elsif c == '$'
          out << '\z'
        elsif c == '(' && has_named && re[i + 1] != '?'
          gen += 1
          out << "(?<__rbjq_#{gen}>"
        else
          out << c
        end
        i += 1
      end
      out
    end

    def compile_regex(re, flags)
      err("#{Value.desc(re)} is not a string") unless re.is_a?(String)
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
        err("Regex failure: #{e.message.sub(/: \/.*\z/m, '')}")
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
        regexp, _, noempty, = compile_regex(re, flags)
        noempty ? !match_all(v, re, flags)[0].empty? : regexp.match?(v)
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
      # Like jq 1.7.1: the n-th output of the replacement is used for every
      # match, giving one result per output.
      results = []
      prev = 0
      ms.each do |m|
        gap = input[prev...m.begin(0)]
        inserts = []
        interp.eval_node(str_node, capture_object(m, names), nil, env) { |s| inserts << s }
        inserts.each_with_index do |ins, ix|
          results[ix] = Ops.add(Ops.add(results[ix], gap), ins)
        end
        prev = m.end(0)
      end
      rest = input[prev..]
      results = results.map { |res| Ops.add(res, rest) }.select { |res| Value.truthy?(res) }
      results = [input] if results.empty?
      results.each { |res| blk.call(res, path && INVALID) }
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

    # [year, month, mday, hours, minutes, seconds, ...] with missing fields as 0
    def tm_fields(bd, name)
      err("#{name} requires parsed datetime inputs") unless bd.all? { |x| Value.number?(x) }
      f = bd[0, 6].map(&:floor)
      f[0] ||= 1900
      f.fill(0, f.length...6)
    end

    def timegm(bd)
      y, mon, d, h, mi, s = tm_fields(bd, 'mktime')
      y += mon.div(12)
      mon %= 12
      days = days_from_civil(y, mon + 1, 1) + (d - 1)
      days * 86_400 + h * 3600 + mi * 60 + s
    end

    # jq's set_tm_wday / set_tm_yday, which also handle a day of month of 0
    def tm_wday(year, mon, mday)
      century = year / 100
      y = year % 100
      y -= 1 if mon < 2
      m = mon - 1
      m += 12 if m < 1
      wday = (mday + (2.6 * m - 0.2).floor + y + (y / 4.0).floor + (century / 4.0).floor - 2 * century).remainder(7)
      wday.negative? ? wday + 7 : wday
    end

    CUMULATIVE_DAYS = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334].freeze

    def tm_yday(year, mon, mday)
      leap = mon > 1 && ((year % 4).zero? && (year % 100 != 0) || (year % 400).zero?) ? 1 : 0
      CUMULATIVE_DAYS[mon.abs % 12] + leap + mday - 1
    end

    fn('gmtime', 0) do |v|
      err('gmtime() requires numeric inputs') unless Value.number?(v)
      t, frac = time_from_number(v)
      broken_down(t, frac)
    end

    fn('localtime', 0) do |v|
      err('localtime() requires numeric inputs') unless Value.number?(v)
      t, frac = time_from_number(v, local: true)
      broken_down(t, frac)
    end

    fn('mktime', 0) do |v|
      err('mktime requires array inputs') unless v.is_a?(Array)
      secs = timegm(v)
      err('invalid gmtime representation') if secs < MIN_TIME

      secs
    end

    DAY_NAMES = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze
    MONTH_NAMES = %w[January February March April May June July August September October November December].freeze

    # The broken-down time [year, month, mday, hours, minutes, seconds, wday, yday]
    # that jq hands to strftime(3): fields are used as given (not normalized);
    # missing ones are 0 (the year is 1900).
    def strftime_fields(v, name, local)
      if Value.number?(v)
        return broken_down(time_from_number(v, local: local)[0]).map { |x| x.floor }
      end

      err("#{name} requires parsed datetime inputs") unless v.is_a?(Array)
      err("#{name} requires parsed datetime inputs") unless v.all? { |x| Value.number?(x) }

      f = v[0, 8].map(&:floor)
      f[0] ||= 1900
      f.fill(0, f.length...8)
      # jq normalizes the fields with timegm(3), which fails before 1900;
      # then the fields are formatted as given
      secs = timegm(f)
      return f if secs < MIN_TIME

      t = Time.at(secs)
      t = local ? Time.local(t.utc.year, t.utc.month, t.utc.day, t.utc.hour, t.utc.min, t.utc.sec) : t.utc
      broken_down(t).map { |x| x.floor }
    end

    MIN_TIME = -2_208_988_800 # 1900-01-01T00:00:00Z

    # strftime(3) in the C locale over raw fields. Directives that need a
    # normalized date (week numbers etc.) are delegated to Time#strftime.
    def format_time(fields, fmt, local)
      year, mon, mday, hour, min, sec, wday, yday = fields
      normalized = lambda do
        t = Time.at(timegm(fields)).utc
        local ? Time.local(t.year, t.month, t.day, t.hour, t.min, t.sec) : t
      end
      day = DAY_NAMES[wday % 7]
      month = MONTH_NAMES[mon % 12]
      fmt.gsub(/%([-_0^#]?)([a-zA-Z%+])/) do
        flag = Regexp.last_match(1)
        c = Regexp.last_match(2)
        next normalized.call.strftime("%#{flag}#{c}") unless flag.empty?

        case c
        when 'Y' then year.to_s
        when 'C' then format('%02d', year / 100)
        when 'y' then format('%02d', year % 100)
        when 'm' then format('%02d', mon + 1)
        when 'd' then format('%02d', mday)
        when 'e' then format('%2d', mday)
        when 'H' then format('%02d', hour)
        when 'k' then format('%2d', hour)
        when 'I' then format('%02d', (hour % 12).zero? ? 12 : hour % 12)
        when 'l' then format('%2d', (hour % 12).zero? ? 12 : hour % 12)
        when 'M' then format('%02d', min)
        when 'S' then format('%02d', sec)
        when 'p' then hour < 12 ? 'AM' : 'PM'
        when 'j' then format('%03d', yday + 1)
        when 'a' then day[0, 3]
        when 'A' then day
        when 'b', 'h' then month[0, 3]
        when 'B' then month
        when 'u' then (wday % 7).zero? ? '7' : (wday % 7).to_s
        when 'w' then (wday % 7).to_s
        when 'n' then "\n"
        when 't' then "\t"
        when '%' then '%'
        when 'D' then format_time(fields, '%m/%d/%y', local)
        when 'F' then format_time(fields, '%Y-%m-%d', local)
        when 'T' then format_time(fields, '%H:%M:%S', local)
        when 'R' then format_time(fields, '%H:%M', local)
        when 'r' then format_time(fields, '%I:%M:%S %p', local)
        when 'c' then format_time(fields, '%a %b %e %H:%M:%S %Y', local)
        when 'x' then format_time(fields, '%m/%d/%y', local)
        when 'X' then format_time(fields, '%H:%M:%S', local)
        when 's' then (local ? normalized.call.to_i : timegm(fields)).to_s
        when 'Z' then local ? normalized.call.strftime('%Z') : 'UTC'
        when 'z' then local ? normalized.call.strftime('%z') : '+0000'
        else normalized.call.strftime("%#{c}")
        end
      end
    end

    fn('strftime', 1) do |v, fmt|
      err('strftime/1 requires a string format') unless fmt.is_a?(String)
      format_time(strftime_fields(v, 'strftime/1', false), fmt, false)
    end

    fn('strflocaltime', 1) do |v, fmt|
      err('strflocaltime/1 requires a string format') unless fmt.is_a?(String)
      format_time(strftime_fields(v, 'strflocaltime/1', true), fmt, true)
    end

    fn('strptime', 1) do |v, fmt|
      err("strptime/1 requires string inputs and arguments") unless v.is_a?(String) && fmt.is_a?(String)
      h = Date._strptime(v, fmt)
      err("date \"#{v}\" does not match format \"#{fmt}\"") if h.nil? || h.key?(:leftover)
      next broken_down(Time.at(h[:seconds]).utc) if h[:seconds]

      # like strptime(3): fields that are not parsed stay 0 (the year is 1900)
      year = h[:year] || 1900
      mon = (h[:mon] || 1) - 1
      mday = h[:mday] || 0
      [year, mon, mday, h[:hour] || 0, h[:min] || 0, h[:sec] || 0,
       tm_wday(year, mon, mday), tm_yday(year, mon, mday)]
    end
  end
end
