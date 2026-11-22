# frozen_string_literal: true

require 'strscan'

module Rbjq
  # Streaming JSON parser: parses a sequence of whitespace-separated JSON texts.
  class JSONParser
    WS = /[ \t\r\n]*/
    NUMBER = /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/
    STR_CHUNK = /[^"\\\x00-\x1f]+/
    ESCAPES = { '"' => '"', '\\' => '\\', '/' => '/', 'b' => "\b", 'f' => "\f", 'n' => "\n", 'r' => "\r", 't' => "\t" }.freeze

    def self.parse(src)
      p = new(src)
      v = p.next_value
      raise ParseError, "Expected JSON value (while parsing '#{src}')" if v.equal?(EOF)

      unless p.next_value.equal?(EOF)
        raise ParseError, "Unexpected extra JSON values (while parsing '#{src}')"
      end

      v
    end

    def self.parse_all(src)
      p = new(src)
      out = []
      loop do
        v = p.next_value
        break if v.equal?(EOF)

        out << v
      end
      out
    end

    EOF = Object.new.freeze

    attr_reader :scanner

    def initialize(src)
      src = src.dup.force_encoding(Encoding::UTF_8)
      src = src.scrub("�") unless src.valid_encoding?
      @src = src
      @s = StringScanner.new(src)
      @counted_pos = 0
      @counted_lines = 0
      @line_number = 0
    end

    # Line number as reported by jq's input_line_number: jq reads its input
    # line by line, so this is the number of newlines up to and including the
    # end of the line on which the last parsed value ended.
    attr_reader :line_number

    # Returns the next value or EOF
    def next_value
      @s.skip(WS)
      return EOF if @s.eos?

      v = parse_value
      nl = @src.byteindex("\n", @s.pos)
      @line_number = count_lines_upto(nl ? nl + 1 : @src.bytesize)
      v
    end

    def line
      @src.byteslice(0, @s.pos).count("\n") + 1
    end

    private

    def count_lines_upto(pos)
      if pos > @counted_pos
        @counted_lines += @src.byteslice(@counted_pos, pos - @counted_pos).count("\n")
        @counted_pos = pos
      end
      @counted_lines
    end

    def error(msg)
      raise ParseError, "#{msg} at line #{line}, column #{column}"
    end

    def column
      before = @src.byteslice(0, @s.pos)
      nl = before.rindex("\n")
      nl ? before.length - nl - 1 : before.length
    end

    def parse_value
      @s.skip(WS)
      c = @s.peek(1)
      case c
      when '{' then parse_object
      when '[' then parse_array
      when '"'
        @s.pos += 1
        parse_string
      when 't'
        @s.skip(/true/) or error('Invalid literal')
        true
      when 'f'
        @s.skip(/false/) or error('Invalid literal')
        false
      when 'n'
        if @s.skip(/null/)
          nil
        elsif @s.skip(/nan/)
          Float::NAN
        else
          error('Invalid literal')
        end
      when 'N'
        @s.skip(/NaN/) or error('Invalid literal')
        Float::NAN
      when ''
        error('Unfinished JSON term at EOF')
      else
        if (n = @s.scan(NUMBER))
          if @s.match?(/[a-zA-Z0-9_]/)
            error('Invalid numeric literal')
          end
          parse_number(n)
        else
          error('Invalid numeric literal')
        end
      end
    end

    def parse_number(n)
      if n.include?('.') || n.include?('e') || n.include?('E')
        f = n.to_f
        f = Float::MAX if f == Float::INFINITY
        f = -Float::MAX if f == -Float::INFINITY
        Value.normalize_number(f)
      else
        i = n.to_i
        # keep large integer literals exact (like jq 1.7 literal preservation)
        i
      end
    end

    def parse_object
      @s.pos += 1
      h = {}
      @s.skip(WS)
      return h if @s.skip(/\}/)

      loop do
        @s.skip(WS)
        error('Object keys must be strings') unless @s.skip(/"/)
        k = parse_string
        @s.skip(WS)
        error("Objects must consist of key:value pairs") unless @s.skip(/:/)
        h[k] = parse_value
        @s.skip(WS)
        next if @s.skip(/,/)
        break if @s.skip(/\}/)

        error(@s.eos? ? 'Unfinished JSON term at EOF' : "Expected separator between values")
      end
      h
    end

    def parse_array
      @s.pos += 1
      a = []
      @s.skip(WS)
      return a if @s.skip(/\]/)

      loop do
        a << parse_value
        @s.skip(WS)
        next if @s.skip(/,/)
        break if @s.skip(/\]/)

        error(@s.eos? ? 'Unfinished JSON term at EOF' : 'Expected separator between values')
      end
      a
    end

    def parse_string
      buf = +''
      loop do
        if (chunk = @s.scan(STR_CHUNK))
          buf << chunk
        end
        c = @s.getch
        case c
        when '"'
          return buf
        when '\\'
          e = @s.getch
          if (r = ESCAPES[e])
            buf << r
          elsif e == 'u'
            hex = @s.scan(/[0-9a-fA-F]{4}/) or error('Invalid escape')
            cp = hex.to_i(16)
            if cp >= 0xD800 && cp <= 0xDBFF
              if @s.match?(/\\u[dD][c-fC-F][0-9a-fA-F]{2}/)
                lo = @s.scan(/\\u..../)[2..].to_i(16)
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
              else
                cp = 0xFFFD
              end
            elsif cp >= 0xDC00 && cp <= 0xDFFF
              cp = 0xFFFD
            end
            buf << cp.chr(Encoding::UTF_8)
          else
            error('Invalid escape')
          end
        when nil
          error('Unfinished JSON term at EOF')
        else
          # control character inside a string: accept as-is (jq rejects some)
          buf << c
        end
      end
    end
  end

  # JSON encoder with jq-compatible number formatting and pretty-printing.
  class Encoder
    DEFAULT_COLORS = {
      null: '0;90', false: '0;39', true: '0;39', number: '0;39', string: '0;32',
      array: '1;39', object: '1;39', key: '34;1'
    }.freeze
    COLOR_KEYS = %i[null false true number string array object key].freeze

    def self.dump(v)
      new.encode(v)
    end

    def self.parse_colors(spec)
      colors = DEFAULT_COLORS.dup
      return colors if spec.nil? || spec.empty?

      spec.split(':').each_with_index do |c, i|
        break if i >= COLOR_KEYS.size

        colors[COLOR_KEYS[i]] = c
      end
      colors
    end

    def initialize(indent: 0, tab: false, sort_keys: false, ascii: false, color: false, colors: nil)
      @indent = indent
      @tab = tab
      @sort_keys = sort_keys
      @ascii = ascii
      @color = color
      @colors = colors || DEFAULT_COLORS
      @pretty = tab || indent.positive?
    end

    def encode(v)
      buf = +''
      write(buf, v, 0)
      buf
    end

    def self.format_number(n)
      case n
      when Integer
        n.to_s
      when Float
        return 'null' if n.nan?
        return '1.7976931348623157e+308' if n == Float::INFINITY
        return '-1.7976931348623157e+308' if n == -Float::INFINITY

        format_float(n)
      end
    end

    # Port of jq's jvp_dtoa_fmt (shortest round-trip digits, %.17g-like layout)
    def self.format_float(f)
      return (1.0 / f).negative? ? '-0' : '0' if f.zero?

      s = f.abs.to_s # shortest repr, e.g. "1.0e+20", "0.1", "123.456", "1.0e-05"
      mant, exp = s.split('e')
      exp = exp.to_i
      int, frac = mant.split('.')
      frac = '' if frac == '0'
      digits = (int + frac)
      lead = digits.length - digits.sub(/\A0+/, '').length
      digits = digits.sub(/\A0+/, '')
      decpt = int.length + exp - lead
      digits = digits.sub(/0+\z/, '')
      digits = '0' if digits.empty?
      nd = digits.length
      sign = f.negative? ? '-' : ''

      if decpt <= -4 || decpt > nd + 15
        e = decpt - 1
        m = digits[0]
        m += ".#{digits[1..]}" if nd > 1
        es = e.negative? ? '-' : '+'
        ea = e.abs
        "#{sign}#{m}e#{es}#{ea < 10 ? "0#{ea}" : ea}"
      elsif decpt <= 0
        "#{sign}0.#{'0' * -decpt}#{digits}"
      elsif decpt >= nd
        "#{sign}#{digits}#{'0' * (decpt - nd)}"
      else
        "#{sign}#{digits[0, decpt]}.#{digits[decpt..]}"
      end
    end

    ESCAPE_MAP = {
      '"' => '\\"', '\\' => '\\\\', "\n" => '\\n', "\t" => '\\t', "\r" => '\\r', "\b" => '\\b', "\f" => '\\f'
    }.freeze

    def self.escape_string(s, ascii = false)
      s = s.scrub("�") unless s.valid_encoding?
      out = s.gsub(/["\\\x00-\x1f\x7f]/) do |c|
        ESCAPE_MAP[c] || format('\\u%04x', c.ord)
      end
      if ascii
        out = out.gsub(/[^\x00-\x7f]/) do |c|
          cp = c.ord
          if cp >= 0x10000
            cp -= 0x10000
            format('\\u%04x\\u%04x', 0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF))
          else
            format('\\u%04x', cp)
          end
        end
      end
      "\"#{out}\""
    end

    private

    def col(kind)
      "\e[#{@colors[kind]}m"
    end

    RESET = "\e[0m"

    def newline_indent(buf, level)
      return unless @pretty

      buf << "\n"
      buf << (@tab ? "\t" * level : ' ' * (@indent * level))
    end

    def write(buf, v, level)
      case v
      when nil
        scalar(buf, :null, 'null')
      when true
        scalar(buf, :true, 'true')
      when false
        scalar(buf, :false, 'false')
      when Integer, Float
        scalar(buf, :number, Encoder.format_number(v))
      when String
        scalar(buf, :string, Encoder.escape_string(v, @ascii))
      when Array
        write_array(buf, v, level)
      when Hash
        write_object(buf, v, level)
      else
        raise TypeError, "cannot encode #{v.class}"
      end
    end

    def scalar(buf, kind, text)
      if @color
        buf << col(kind) << text << RESET
      else
        buf << text
      end
    end

    def write_array(buf, v, level)
      c = @color ? col(:array) : nil
      if v.empty?
        buf << c if c
        buf << '[]'
        buf << RESET if c
        return
      end
      buf << c if c
      buf << '['
      v.each_with_index do |e, i|
        if i.positive?
          buf << c if c
          buf << ','
        end
        newline_indent(buf, level + 1)
        write(buf, e, level + 1)
      end
      buf << c if c
      newline_indent(buf, level)
      buf << c if c
      buf << ']'
      buf << RESET if c
    end

    def write_object(buf, v, level)
      c = @color ? col(:object) : nil
      if v.empty?
        buf << c if c
        buf << '{}'
        buf << RESET if c
        return
      end
      buf << c if c
      buf << '{'
      keys = @sort_keys ? v.keys.sort_by(&:b) : v.keys
      keys.each_with_index do |k, i|
        if i.positive?
          buf << c if c
          buf << ','
        end
        newline_indent(buf, level + 1)
        if c
          buf << RESET << col(:key) << Encoder.escape_string(k, @ascii) << RESET
          buf << c << ':'
          buf << ' ' if @pretty
          buf << RESET
        else
          buf << Encoder.escape_string(k, @ascii) << ':'
          buf << ' ' if @pretty
        end
        write(buf, v[k], level + 1)
      end
      buf << c if c
      newline_indent(buf, level)
      buf << c if c
      buf << '}'
      buf << RESET if c
    end
  end
end
