# frozen_string_literal: true

module Rbjq
  # Helpers for jq value semantics on plain Ruby objects:
  # nil, true, false, Integer, Float, String, Array, Hash(String => value)
  module Value
    MAX_SAFE = 2**53
    DBL_MAX = Float::MAX

    module_function

    def normalize_number(n)
      case n
      when Integer
        n.abs > MAX_SAFE ? n.to_f : n
      when Float
        if n.finite? && n == n.floor && n.abs <= MAX_SAFE && !(n.zero? && (1.0 / n).negative?)
          n.to_i
        else
          n
        end
      else
        n
      end
    end

    def type_name(v)
      case v
      when nil then 'null'
      when true, false then 'boolean'
      when Integer, Float then 'number'
      when String then 'string'
      when Array then 'array'
      when Hash then 'object'
      else raise TypeError, "not a jq value: #{v.inspect}"
      end
    end

    def truthy?(v)
      !(v.nil? || v == false)
    end

    KIND_ORDER = { NilClass => 0, FalseClass => 1, TrueClass => 2, Integer => 3, Float => 3,
                   String => 4, Array => 5, Hash => 6 }.freeze

    def kind_order(v)
      KIND_ORDER[v.class] || raise(TypeError, "not a jq value: #{v.inspect}")
    end

    def compare(a, b)
      ka = kind_order(a)
      kb = kind_order(b)
      return ka <=> kb if ka != kb

      case a
      when Integer, Float
        a_nan = a.is_a?(Float) && a.nan?
        b_nan = b.is_a?(Float) && b.nan?
        return -1 if a_nan
        return 1 if b_nan

        a <=> b
      when String
        a.b <=> b.b
      when Array
        i = 0
        while i < a.length && i < b.length
          c = compare(a[i], b[i])
          return c unless c.zero?

          i += 1
        end
        a.length <=> b.length
      when Hash
        ka = a.keys.sort_by(&:b)
        kb = b.keys.sort_by(&:b)
        c = compare(ka, kb)
        return c unless c.zero?

        ka.each do |k|
          c = compare(a[k], b[k])
          return c unless c.zero?
        end
        0
      else
        0
      end
    end

    def equal?(a, b)
      compare(a, b).zero?
    end

    def sort(arr)
      arr.each_with_index.sort { |(x, i), (y, j)| (c = compare(x, y)).zero? ? i <=> j : c }.map(&:first)
    end

    # Value dump truncated like jq error messages
    def dump_trunc(v, max = 11)
      s = Encoder.dump(v)
      if s.bytesize > max + 3
        s = s.byteslice(0, max).scrub('') + '...'
      end
      s
    end

    def desc(v)
      "#{type_name(v)} (#{dump_trunc(v)})"
    end

    def number?(v)
      v.is_a?(Integer) || v.is_a?(Float)
    end

    def to_f(v)
      v.to_f
    end
  end
end
