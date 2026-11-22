# frozen_string_literal: true

module Rbjq
  # Core value operations: indexing, slicing, paths and arithmetic.
  module Ops
    module_function

    def tostring(v)
      v.is_a?(String) ? v : Encoder.dump(v)
    end

    MAX_PATH_DEPTH = 10_000
    MAX_ARRAY_INDEX = 536_870_911

    def index_error(t, k)
      raise JQError, "Cannot index #{Value.type_name(t)} with #{Value.type_name(k)} (#{Value.dump_trunc(k)})"
    end

    # A path component that selects a slice: {"start": n|null, "end": n|null}
    def slice_key?(k)
      k.is_a?(Hash)
    end

    def check_slice_key(k)
      return if k.key?('start') && k.key?('end')

      raise JQError, 'Array/string slice indices must be integers'
    end

    def index(t, k)
      case t
      when Hash
        return t[k] if k.is_a?(String)

        index_error(t, k)
      when Array
        case k
        when Integer
          k += t.length if k.negative?
          k.negative? ? nil : t[k]
        when Float
          return nil if k.nan? || k.infinite?

          i = k.floor
          i += t.length if i.negative?
          i.negative? ? nil : t[i]
        when Hash
          check_slice_key(k)
          slice(t, k['start'], k['end'])
        when Array
          indices_of(t, k)
        else
          index_error(t, k)
        end
      when nil
        case k
        when String, Integer, Float, Hash, Array, nil then nil
        else index_error(t, k)
        end
      when String
        if k.is_a?(Hash)
          check_slice_key(k)
          slice(t, k['start'], k['end'])
        else
          index_error(t, k)
        end
      else
        index_error(t, k)
      end
    end

    def indices_of(arr, sub)
      return [] if sub.empty?

      out = []
      (0..(arr.length - sub.length)).each do |i|
        out << i if sub.each_with_index.all? { |e, j| Value.equal?(arr[i + j], e) }
      end
      out
    end

    def slice_bounds(len, from, to)
      unless (from.nil? || Value.number?(from)) && (to.nil? || Value.number?(to))
        raise JQError, 'Start and end indices of an array slice must be numbers'
      end

      # NaN bounds behave like omitted ones
      ds = from.nil? || (from.is_a?(Float) && from.nan?) ? 0.0 : from.to_f
      de = to.nil? || (to.is_a?(Float) && to.nan?) ? len.to_f : to.to_f
      ds += len if ds.negative?
      de += len if de.negative?
      ds = ds.clamp(0.0, len.to_f)
      de = de.clamp(0.0, len.to_f)
      s = ds.floor
      e = de.ceil
      e = s if e < s
      [s, e]
    end

    def slice(t, from, to)
      case t
      when nil then nil
      when Array
        s, e = slice_bounds(t.length, from, to)
        t[s...e]
      when String
        s, e = slice_bounds(t.length, from, to)
        t[s...e]
      else
        index_error(t, { 'start' => from, 'end' => to })
      end
    end

    def check_path(path)
      raise JQError, 'Path must be specified as an array' unless path.is_a?(Array)
      raise JQError, 'Path too deep' if path.size > MAX_PATH_DEPTH
    end

    def getpath(t, path)
      check_path(path)
      path.each do |k|
        return nil if t.nil?

        t = index(t, k)
      end
      t
    end

    # Returns a copy of `t` whose element at key `k` is replaced by `v`.
    def set_child(t, k, v)
      case k
      when String
        index_error(t, k) unless t.nil? || t.is_a?(Hash)

        h = t.nil? ? {} : t.dup
        h[k] = v
        h
      when Integer, Float
        index_error(t, k) unless t.nil? || t.is_a?(Array)
        raise JQError, 'Cannot set array element at NaN index' if k.is_a?(Float) && k.nan?

        a = t.nil? ? [] : t.dup
        idx = k.to_f.floor
        if idx.negative?
          idx += a.length
          raise JQError, 'Out of bounds negative array index' if idx.negative?
        end
        raise JQError, 'Array index too large' if idx > MAX_ARRAY_INDEX

        a[idx] = v
        a
      when Hash
        case t
        when nil, Array
          check_slice_key(k)
          a = t.nil? ? [] : t
          s, e = slice_bounds(a.length, k['start'], k['end'])
          raise JQError, 'A slice of an array can only be assigned another array' unless v.is_a?(Array)

          a[0...s] + v + a[e..]
        when String
          raise JQError, 'Cannot update string slices'
        else
          index_error(t, k)
        end
      when Array
        raise JQError, 'Cannot update field at array index of array' if t.is_a?(Array)

        index_error(t, k)
      else
        index_error(t, k)
      end
    end

    # Iterative, so that paths of up to MAX_PATH_DEPTH components work with
    # the default Ruby stack.
    def setpath(t, path, v)
      check_path(path)
      return v if path.empty?

      # walk down, remembering each container
      containers = [t]
      cur = t
      path[0...-1].each do |k|
        cur = setpath_child(cur, k)
        containers << cur
      end
      # rebuild bottom-up
      (path.size - 1).downto(0) do |i|
        v = set_child(containers[i], path[i], v)
      end
      v
    end

    # The current value at `k` while descending for setpath
    def setpath_child(t, k)
      return nil if t.nil?

      if k.is_a?(Hash) && (t.is_a?(Array) || t.nil?)
        check_slice_key(k)
        s, e = slice_bounds(t.length, k['start'], k['end'])
        return t[s...e]
      end
      # validate the key against the container type the same way set_child does
      case k
      when String then index_error(t, k) unless t.is_a?(Hash)
      when Integer, Float then index_error(t, k) unless t.is_a?(Array)
      when Array then raise JQError, 'Cannot update field at array index of array' if t.is_a?(Array)
      end
      index(t, k)
    end

    def delpaths(t, paths)
      raise JQError, 'Paths must be specified as an array' unless paths.is_a?(Array)

      normalized = paths.flat_map do |p|
        raise JQError, "Path must be specified as array, not #{Value.type_name(p)}" unless p.is_a?(Array)

        check_path(p)
        normalize_path(t, p)
      end
      sorted = Value.sort(normalized)
      sorted = sorted.each_with_index.reject { |q, i| i.positive? && Value.equal?(q, sorted[i - 1]) }.map(&:first)
      sorted.reverse_each { |p| t = delpath(t, p) }
      t
    end

    # Resolve negative array indices against the value and expand a trailing
    # slice into its indices, so that deleting several paths at once removes
    # the elements they referred to in the original value (like jq).
    # Paths that point outside an array are dropped.
    def normalize_path(t, path)
      out = []
      cur = t
      path.each_with_index do |k, i|
        last = i == path.size - 1
        if cur.is_a?(Array) && Value.number?(k)
          return [] if k.is_a?(Float) && k.nan?

          k = k.to_f.floor
          k += cur.length if k.negative?
          return [] if k.negative? || k >= cur.length
        elsif cur.is_a?(Array) && k.is_a?(Hash) && last
          check_slice_key(k)
          s, e = slice_bounds(cur.length, k['start'], k['end'])
          return (s...e).map { |j| out + [j] }
        end
        out << k
        break if last

        cur = cur.nil? ? nil : index(cur, k)
      end
      [out]
    end

    def delete_child(t, k)
      case t
      when Hash
        raise JQError, "Cannot delete #{Value.type_name(k)} field of object" unless k.is_a?(String)

        h = t.dup
        h.delete(k)
        h
      when Array
        case k
        when Integer, Float
          idx = k.to_f.floor
          idx += t.length if idx.negative?
          raise JQError, 'Out of bounds negative array index' if idx.negative?
          return t if idx >= t.length

          a = t.dup
          a.delete_at(idx)
          a
        when Hash
          check_slice_key(k)
          s, e = slice_bounds(t.length, k['start'], k['end'])
          t[0...s] + t[e..]
        else
          raise JQError, "Cannot delete #{Value.type_name(k)} element of array"
        end
      else
        raise JQError, "Cannot delete fields from #{Value.type_name(t)}"
      end
    end

    # Iterative delete of one path
    def delpath(t, path)
      return nil if path.empty?

      containers = [t]
      cur = t
      path[0...-1].each do |k|
        return t if cur.nil?

        cur = index(cur, k)
        containers << cur
      end
      return t if cur.nil?

      v = delete_child(cur, path[-1])
      (path.size - 2).downto(0) do |i|
        k = path[i]
        parent = containers[i]
        v = if k.is_a?(Hash)
              s, e = slice_bounds(parent.length, k['start'], k['end'])
              parent[0...s] + v + parent[e..]
            else
              set_child(parent, k, v)
            end
      end
      v
    end

    # ------------------------------------------------------------ arithmetic

    def binop(op, l, r)
      case op
      when :+ then add(l, r)
      when :- then subtract(l, r)
      when :* then multiply(l, r)
      when :/ then divide(l, r)
      when :% then modulo(l, r)
      when :== then Value.equal?(l, r)
      when :'!=' then !Value.equal?(l, r)
      when :< then Value.compare(l, r).negative?
      when :<= then Value.compare(l, r) <= 0
      when :> then Value.compare(l, r).positive?
      when :>= then Value.compare(l, r) >= 0
      else raise JQError, "unknown operator #{op}"
      end
    end

    def add(l, r)
      return r if l.nil?
      return l if r.nil?

      if Value.number?(l) && Value.number?(r)
        Value.normalize_number(dbl(l) + dbl(r))
      elsif l.is_a?(String) && r.is_a?(String)
        l + r
      elsif l.is_a?(Array) && r.is_a?(Array)
        l + r
      elsif l.is_a?(Hash) && r.is_a?(Hash)
        l.merge(r)
      else
        raise JQError, "#{Value.desc(l)} and #{Value.desc(r)} cannot be added"
      end
    end

    def subtract(l, r)
      if Value.number?(l) && Value.number?(r)
        Value.normalize_number(dbl(l) - dbl(r))
      elsif l.is_a?(Array) && r.is_a?(Array)
        l.reject { |x| r.any? { |y| Value.equal?(x, y) } }
      else
        raise JQError, "#{Value.desc(l)} and #{Value.desc(r)} cannot be subtracted"
      end
    end

    def multiply(l, r)
      if Value.number?(l) && Value.number?(r)
        Value.normalize_number(dbl(l) * dbl(r))
      elsif (l.is_a?(String) && Value.number?(r)) || (Value.number?(l) && r.is_a?(String))
        s, n = l.is_a?(String) ? [l, r] : [r, l]
        return nil if n.is_a?(Float) && n.nan?
        return nil if n.negative?

        n = n.infinite? ? 2**31 : n.floor if n.is_a?(Float)
        raise JQError, 'Repeat string result too long' if s.bytesize * n > 2_147_483_647

        s * n
      elsif l.is_a?(Hash) && r.is_a?(Hash)
        deep_merge(l, r, 0)
      else
        raise JQError, "#{Value.desc(l)} and #{Value.desc(r)} cannot be multiplied"
      end
    end

    def deep_merge(a, b, depth)
      raise JQError, 'Object merge too deep' if depth > Value::MAX_DEPTH

      out = a.dup
      b.each do |k, v|
        out[k] = if out[k].is_a?(Hash) && v.is_a?(Hash)
                   deep_merge(out[k], v, depth + 1)
                 else
                   v
                 end
      end
      out
    end

    def divide(l, r)
      if Value.number?(l) && Value.number?(r)
        raise JQError, "#{Value.desc(l)} and #{Value.desc(r)} cannot be divided because the divisor is zero" if r.zero?

        Value.normalize_number(l.to_f / r)
      elsif l.is_a?(String) && r.is_a?(String)
        split_string(l, r)
      else
        raise JQError, "#{Value.desc(l)} and #{Value.desc(r)} cannot be divided"
      end
    end

    def split_string(s, sep)
      return [] if s.empty?
      return s.chars if sep.empty?

      s.split(Regexp.new(Regexp.escape(sep)), -1)
    end

    INTMAX_MAX = (2**63) - 1
    INTMAX_MIN = -2**63

    # jq computes on doubles: integers that a double cannot represent exactly
    # are converted before the operation, not after.
    def dbl(n)
      n.is_a?(Integer) && n.abs > Value::MAX_SAFE ? n.to_f : n
    end

    # Like jq's dtoi: double -> intmax_t, clamped to the int64 range.
    def to_intmax(n)
      n = dbl(n)
      return n if n.is_a?(Integer)
      return 0 if n.nan?
      return INTMAX_MAX if n >= 9.223372036854775807e18
      return INTMAX_MIN if n <= -9.223372036854775808e18

      n.truncate
    end

    def modulo(l, r)
      unless Value.number?(l) && Value.number?(r)
        raise JQError, "#{Value.desc(l)} and #{Value.desc(r)} cannot be divided (remainder)"
      end
      return Float::NAN if (l.is_a?(Float) && l.nan?) || (r.is_a?(Float) && r.nan?)

      a = to_intmax(l)
      b = to_intmax(r)
      if b.zero?
        raise JQError,
              "#{Value.desc(l)} and #{Value.desc(r)} cannot be divided (remainder) because the divisor is zero"
      end

      Value.normalize_number(a.remainder(b))
    end
  end
end
