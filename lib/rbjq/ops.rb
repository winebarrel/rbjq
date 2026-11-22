# frozen_string_literal: true

module Rbjq
  # Core value operations: indexing, slicing, paths and arithmetic.
  module Ops
    module_function

    def tostring(v)
      v.is_a?(String) ? v : Encoder.dump(v)
    end

    def index_error(t, k)
      if k.is_a?(String)
        raise JQError, "Cannot index #{Value.type_name(t)} with string #{Encoder.escape_string(k)}"
      end

      raise JQError, "Cannot index #{Value.type_name(t)} with #{Value.type_name(k)}"
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
          return nil if k.nan?
          return nil if k.infinite?

          i = k.floor
          i += t.length if i.negative?
          i.negative? ? nil : t[i]
        when Hash
          slice(t, k['start'], k['end'])
        when Array
          indices_of(t, k)
        else
          index_error(t, k)
        end
      when nil
        case k
        when String, Integer, Float, Hash, nil then nil
        else index_error(t, k)
        end
      when String
        if k.is_a?(Hash) && (k.key?('start') || k.key?('end'))
          slice(t, k['start'], k['end'])
        else
          index_error(t, k)
        end
      else
        index_error(t, k)
      end
    end

    def indices_of(arr, sub)
      return nil if sub.empty?

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

      ds = from.nil? ? 0.0 : from.to_f
      de = to.nil? ? len.to_f : to.to_f
      ds += len if ds.negative?
      de += len if de.negative?
      ds = 0.0 if ds.negative?
      ds = len.to_f if ds > len
      de = len.to_f if de > len
      de = ds if de < ds
      s = ds.floor
      e = de > de.floor ? de.floor + 1 : de.floor
      e = len if e > len
      [s, e]
    end

    def slice(t, from, to)
      case t
      when nil then nil
      when Array
        s, e = slice_bounds(t.length, from, to)
        t[s...e]
      when String
        chars = t.length
        s, e = slice_bounds(chars, from, to)
        t[s...e]
      else
        raise JQError, "Cannot index #{Value.type_name(t)} with object"
      end
    end

    def getpath(t, path)
      unless path.is_a?(Array)
        raise JQError, 'Path must be specified as an array'
      end

      path.each do |k|
        return nil if t.nil?

        t = index(t, k)
      end
      t
    end

    def setpath(t, path, v, i = 0)
      raise JQError, 'Path must be specified as an array' unless path.is_a?(Array)
      return v if i == path.size

      k = path[i]
      case k
      when String
        unless t.nil? || t.is_a?(Hash)
          raise JQError, "Cannot index #{Value.type_name(t)} with #{Encoder.escape_string(k)}"
        end

        h = t.nil? ? {} : t.dup
        h[k] = setpath(h[k], path, v, i + 1)
        h
      when Integer, Float
        unless t.nil? || t.is_a?(Array)
          raise JQError, "Cannot index #{Value.type_name(t)} with number"
        end

        a = t.nil? ? [] : t.dup
        idx = k.to_f.floor
        if idx.negative?
          idx += a.length
          raise JQError, 'Out of bounds negative array index' if idx.negative?
        end
        a[idx] = setpath(a[idx], path, v, i + 1)
        a
      when Hash
        case t
        when nil, Array
          a = t.nil? ? [] : t
          s, e = slice_bounds(a.length, k['start'], k['end'])
          nv = setpath(a[s...e], path, v, i + 1)
          raise JQError, 'A slice of an array can only be assigned another array' unless nv.is_a?(Array)

          a[0...s] + nv + a[e..]
        when String
          raise JQError, 'Cannot update string slices'
        else
          raise JQError, "Cannot update field at object index of #{Value.type_name(t)}"
        end
      when nil
        raise JQError, "Cannot index #{Value.type_name(t)} with null" unless t.nil? || t.is_a?(Hash)

        setpath(t, path, v, i + 1)
      else
        raise JQError, "Invalid path component #{Value.desc(k)}"
      end
    end

    def delpaths(t, paths)
      raise JQError, 'Paths must be specified as an array' unless paths.is_a?(Array)

      Value.sort(paths).reverse_each do |p|
        raise JQError, 'Path must be specified as an array' unless p.is_a?(Array)

        t = delpath(t, p)
      end
      t
    end

    def delpath(t, path)
      return nil if path.empty?
      return nil if t.nil?

      k = path[0]
      if path.size == 1
        case t
        when Hash
          raise JQError, "Cannot delete field at index of object" unless k.is_a?(String)

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
            s, e = slice_bounds(t.length, k['start'], k['end'])
            t[0...s] + t[e..]
          else
            raise JQError, "Cannot delete field at index of array"
          end
        else
          raise JQError, "Cannot delete field at index of #{Value.type_name(t)}"
        end
      else
        child = index(t, k)
        return t if child.nil?

        nc = delpath(child, path[1..])
        if k.is_a?(Hash)
          s, e = slice_bounds(t.length, k['start'], k['end'])
          t[0...s] + nc + t[e..]
        else
          setpath(t, [k], nc)
        end
      end
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
        s * n
      elsif l.is_a?(Hash) && r.is_a?(Hash)
        deep_merge(l, r)
      else
        raise JQError, "#{Value.desc(l)} and #{Value.desc(r)} cannot be multiplied"
      end
    end

    def deep_merge(a, b)
      out = a.dup
      b.each do |k, v|
        out[k] = if out[k].is_a?(Hash) && v.is_a?(Hash)
                   deep_merge(out[k], v)
                 else
                   v
                 end
      end
      out
    end

    def divide(l, r)
      if Value.number?(l) && Value.number?(r)
        if r.zero?
          raise JQError, "#{Value.desc(l)} and #{Value.desc(r)} cannot be divided because the divisor is zero"
        end

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

    INTMAX_MAX = 2**63 - 1
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
      if Value.number?(l) && Value.number?(r)
        a = to_intmax(l)
        b = to_intmax(r)
        if b.zero?
          raise JQError, "#{Value.desc(l)} and #{Value.desc(r)} cannot be divided (remainder) because the divisor is zero"
        end

        Value.normalize_number(a.remainder(b))
      else
        raise JQError, "#{Value.desc(l)} and #{Value.desc(r)} cannot be divided"
      end
    end
  end
end
