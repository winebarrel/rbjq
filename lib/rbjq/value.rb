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

    MAX_DEPTH = 10_000

    def compare(a, b, depth = 0, msg = 'Comparison too deep')
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
        raise JQError, msg if depth > MAX_DEPTH

        i = 0
        while i < a.length && i < b.length
          c = compare(a[i], b[i], depth + 1, msg)
          return c unless c.zero?

          i += 1
        end
        a.length <=> b.length
      when Hash
        raise JQError, msg if depth > MAX_DEPTH

        ka = a.keys.sort_by(&:b)
        kb = b.keys.sort_by(&:b)
        i = 0
        while i < ka.length && i < kb.length
          c = ka[i].b <=> kb[i].b
          return c unless c.zero?

          i += 1
        end
        c = ka.length <=> kb.length
        return c unless c.zero?

        ka.each do |k|
          c = compare(a[k], b[k], depth + 1, msg)
          return c unless c.zero?
        end
        0
      else
        0
      end
    end

    def equal?(a, b)
      compare(a, b, 0, 'Equality check too deep').zero?
    end

    def sort(arr)
      arr.each_with_index.sort { |(x, i), (y, j)| (c = compare(x, y)).zero? ? i <=> j : c }.map(&:first)
    end

    # Value dump shortened like jq 1.8 error messages: at most 29 bytes; a
    # longer dump keeps its first bytes (not splitting a character), then
    # "..." and the closing quote or bracket.
    def dump_trunc(v)
      s = Encoder.dump(v)
      return s if s.bytesize <= 29

      closing = ['"', '[', '{'].include?(s[0]) ? s[-1] : ''
      prefix = s.byteslice(0, 26 - closing.bytesize)
      prefix = prefix.byteslice(0, prefix.bytesize - 1) until prefix.valid_encoding?
      "#{prefix}...#{closing}"
    end

    REPLACEMENT = "\uFFFD"

    # Replace invalid UTF-8 the way jq does (jvp_utf8_next): a lead byte
    # followed by too few continuation bytes, or cut off by the end of the
    # string, becomes a single U+FFFD together with the bytes it consumed.
    def scrub_utf8(str)
      str = str.dup.force_encoding(Encoding::UTF_8)
      return str if str.valid_encoding?

      bytes = str.b
      out = +''
      i = 0
      n = bytes.bytesize
      while i < n
        c = bytes.getbyte(i)
        len = if c < 0x80 then 1
              elsif c.between?(0xC2, 0xDF) then 2
              elsif c.between?(0xE0, 0xEF) then 3
              elsif c.between?(0xF0, 0xF4) then 4
              else 0
              end
        if len.zero?
          out << REPLACEMENT
          i += 1
          next
        end
        if i + len > n
          out << REPLACEMENT
          break
        end

        j = 1
        j += 1 while j < len && (bytes.getbyte(i + j) & 0xC0) == 0x80
        seq = bytes.byteslice(i, j).force_encoding(Encoding::UTF_8)
        out << (j == len && seq.valid_encoding? ? seq : REPLACEMENT)
        i += j
      end
      out
    end

    # Float() for a decimal literal, without Ruby's "out of range" warning:
    # huge exponents become infinity and tiny ones zero, as strtod does.
    def parse_float(str)
      if (m = str.match(/\A([+-]?)(\d*)\.?(\d*)[eE]([+-]?\d+)\z/))
        sign, int, frac, exp = m.captures
        digits = (int + frac).sub(/\A0+/, '')
        unless digits.empty?
          magnitude = exp.to_i + int.sub(/\A0+/, '').length
          magnitude = exp.to_i - frac[/\A0*/].length if int.sub(/\A0+/, '').empty?
          return (sign == '-' ? -Float::INFINITY : Float::INFINITY) if magnitude > 400
          return (sign == '-' ? -1 : 1) * 0.0 if magnitude < -400 # keeps the sign of zero
        end
      end
      Float(str)
    end

    def desc(v)
      "#{type_name(v)} (#{dump_trunc(v)})"
    end

    def number?(v)
      v.is_a?(Integer) || v.is_a?(Float)
    end
  end
end
