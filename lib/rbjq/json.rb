# frozen_string_literal: true

require 'strscan'

module Rbjq
  # Streaming JSON parser: parses a sequence of whitespace-separated JSON texts.
  class JSONParser
    WS = /[ \t\r\n]*/
    NUMBER = /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/
    STR_CHUNK = /[^"\\\x00-\x1f]+/
    ESCAPES = { '"' => '"', '\\' => '\\', '/' => '/', 'b' => "\b", 'f' => "\f", 'n' => "\n", 'r' => "\r",
                't' => "\t" }.freeze

    def self.parse(src)
      p = new(src)
      v = p.next_value
      raise ParseError, "Expected JSON value (while parsing '#{src}')" if v.equal?(EOF)

      raise ParseError, "Unexpected extra JSON values (while parsing '#{src}')" unless p.next_value.equal?(EOF)

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
      src = Value.scrub_utf8(src) unless src.valid_encoding?
      src = src.delete_prefix('﻿') # byte order mark
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
      when ''
        error('Unfinished JSON term at EOF')
      when ']' then fail_at_char("Unmatched ']'")
      when '}' then fail_at_char("Unmatched '}'")
      when ':' then fail_at_char("Expected string key before ':'")
      when ',' then fail_at_char("Expected value before ','")
      when "'"
        @s.skip(LITERAL)
        error_after_token(%(Invalid string literal; expected ", but got '))
      else
        parse_literal
      end
    end

    # Characters of a bare token (anything up to a delimiter), like jq's tokenizer
    LITERAL = /[^ \t\r\n\[\]{},:"]+/
    NUMBER_LITERAL = /\A[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/

    def parse_literal
      tok = @s.scan(LITERAL) or error('Unfinished JSON term at EOF')
      case tok
      when 'true' then true
      when 'false' then false
      when 'null' then nil
      when 'nan', 'NaN', '-nan', '-NaN' then Float::NAN
      when 'Infinity', 'infinity' then Float::MAX
      when '-Infinity', '-infinity' then -Float::MAX
      else
        return parse_number(tok) if tok.match?(NUMBER_LITERAL)

        error_after_token(%w[t f n].include?(tok[0]) ? 'Invalid literal' : 'Invalid numeric literal')
      end
    end

    def parse_number(n)
      n = n.delete_prefix('+')
      if n.match?(/[.eE]/)
        f = Value.parse_float(n.sub(/\A(-?)\./, '\10.').sub(/\.(?![0-9])/, '.0'))
        f = Float::MAX if f == Float::INFINITY
        f = -Float::MAX if f == -Float::INFINITY
        Value.normalize_number(f)
      else
        # like jq without decNumber, numbers are doubles
        return -0.0 if n.match?(/\A-0+\z/)

        Value.normalize_number(n.to_i)
      end
    end

    # jq reports errors in a bare token after reading the delimiter that ends it
    def error_after_token(msg)
      raise ParseError, "#{msg} at line #{line}, column #{column + 1}" unless @s.eos?

      error("#{msg} at EOF")
    end

    # jq reports a misplaced token after reading it (and its delimiter)
    def unexpected_token(msg)
      if @s.skip(LITERAL)
        error_after_token(msg)
      elsif @s.peek(1) == '"'
        @s.pos += 1
        parse_string
        raise ParseError, "#{msg} at line #{line}, column #{column}"
      else
        fail_at_char(msg)
      end
    end

    # report an error after consuming the current (structural) character
    def fail_at_char(msg)
      @s.getch
      raise ParseError, "#{msg} at line #{line}, column #{column}"
    end

    MAX_PARSING_DEPTH = 10_000

    def enter
      @depth = (@depth || 0) + 1
      error('Exceeds depth limit for parsing') if @depth > MAX_PARSING_DEPTH
    end

    def leave
      @depth -= 1
    end

    def parse_object
      @s.pos += 1
      enter
      h = {}
      @s.skip(WS)
      if @s.skip(/\}/)
        leave
        return h
      end

      loop do
        @s.skip(WS)
        error('Unfinished JSON term at EOF') if @s.eos?
        if @s.peek(1) == "'"
          @s.skip(LITERAL)
          error_after_token(%(Invalid string literal; expected ", but got '))
        end
        unless @s.skip(/"/)
          case @s.peek(1)
          when '}' then fail_at_char('Expected another key-value pair')
          when ',' then fail_at_char("Expected value before ','")
          when ']' then fail_at_char("Unmatched ']'")
          end
          error_after_token('Object keys must be strings') if @s.skip(LITERAL)
          error('Object keys must be strings')
        end
        k = parse_string
        @s.skip(WS)
        error('Unfinished JSON term at EOF') if @s.eos?
        unless @s.skip(/:/)
          fail_at_char('Objects must consist of key:value pairs') if @s.peek(1) == ','
          unexpected_token('Expected separator between values')
        end
        h[k] = parse_value
        @s.skip(WS)
        next if @s.skip(/,/)
        break if @s.skip(/\}/)

        error('Unfinished JSON term at EOF') if @s.eos?
        fail_at_char("Unmatched ']'") if @s.peek(1) == ']'
        unexpected_token('Expected separator between values')
      end
      leave
      h
    end

    def parse_array
      @s.pos += 1
      enter
      a = []
      @s.skip(WS)
      if @s.skip(/\]/)
        leave
        return a
      end

      loop do
        @s.skip(WS)
        case @s.peek(1)
        when ']' then fail_at_char('Expected another array element')
        when ',' then fail_at_char("Expected value before ','")
        end
        a << parse_value
        @s.skip(WS)
        next if @s.skip(/,/)
        break if @s.skip(/\]/)

        error('Unfinished JSON term at EOF') if @s.eos?
        fail_at_char('Objects must consist of key:value pairs') if @s.peek(1) == '}'
        fail_at_char("':' not as part of an object") if @s.peek(1) == ':'
        unexpected_token('Expected separator between values')
      end
      leave
      a
    end

    # Like jq, the whole string is read first, then validated; errors are
    # reported at the closing quote.
    def parse_string
      buf = +''
      failure = nil
      loop do
        if (chunk = @s.scan(STR_CHUNK))
          buf << chunk
        end
        c = @s.getch
        case c
        when '"'
          error(failure) if failure
          return buf
        when '\\'
          e = @s.getch
          if (r = ESCAPES[e])
            buf << r
          elsif e == 'u'
            hex = @s.scan(/[0-9a-fA-F]{4}/)
            unless hex
              failure ||= 'Invalid \\uXXXX escape'
              next
            end
            cp = hex.to_i(16)
            if cp.between?(0xD800, 0xDBFF)
              if @s.match?(/\\u[dD][c-fC-F][0-9a-fA-F]{2}/)
                lo = @s.scan(/\\u..../)[2..].to_i(16)
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
              else
                failure ||= 'Invalid \\uXXXX\\uXXXX surrogate pair escape'
                next
              end
            elsif cp.between?(0xDC00, 0xDFFF)
              cp = 0xFFFD
            end
            buf << cp.chr(Encoding::UTF_8)
          elsif e.nil?
            error('Unfinished string at EOF')
          else
            failure ||= 'Invalid escape'
          end
        when nil
          error('Unfinished string at EOF')
        else
          failure ||= 'Invalid string: control characters from U+0000 through U+001F must be escaped'
          buf << c
        end
      end
    end
  end

  # JSON encoder with jq-compatible number formatting and pretty-printing.
  class Encoder
    DEFAULT_COLORS = {
      null: '0;90', false: '0;39', true: '0;39', number: '0;39', string: '0;32',
      array: '1;39', object: '1;39', key: '1;34'
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

    # pretty: nil means pretty-print when indenting (indent > 0 or tab)
    def initialize(indent: 0, tab: false, sort_keys: false, ascii: false, color: false, colors: nil, pretty: nil)
      @indent = indent
      @tab = tab
      @sort_keys = sort_keys
      @ascii = ascii
      @color = color
      @colors = colors || DEFAULT_COLORS
      @pretty = pretty.nil? ? (tab || indent.positive?) : pretty
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

    def self.escape_string(s, ascii = false) # rubocop:disable Style/OptionalBooleanParameter
      s = s.scrub('�') unless s.valid_encoding?
      out = s.gsub(/["\\\x00-\x1f\x7f]/) do |c|
        ESCAPE_MAP[c] || format('\\u%04x', c.ord)
      end
      if ascii
        out = out.gsub(/[^\x00-\x7f]/) do |c|
          cp = c.ord
          if cp >= 0x10000
            cp -= 0x10000
            format('\u%<hi>04x\u%<lo>04x', hi: 0xD800 + (cp >> 10), lo: 0xDC00 + (cp & 0x3FF))
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

    MAX_PRINT_DEPTH = 10_000

    def write(buf, v, level)
      if level > MAX_PRINT_DEPTH
        buf << '<skipped: too deep>'
        return
      end

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

    # Colored output follows jq 1.8: every bracket and separator is colored
    # and immediately reset.
    def punct(buf, c, text)
      if c
        buf << c << text << RESET
      else
        buf << text
      end
    end

    def write_array(buf, v, level)
      c = @color ? col(:array) : nil
      return punct(buf, c, '[]') if v.empty?

      punct(buf, c, '[')
      v.each_with_index do |e, i|
        punct(buf, c, ',') if i.positive?
        newline_indent(buf, level + 1)
        write(buf, e, level + 1)
      end
      newline_indent(buf, level)
      punct(buf, c, ']')
    end

    def write_object(buf, v, level)
      c = @color ? col(:object) : nil
      return punct(buf, c, '{}') if v.empty?

      punct(buf, c, '{')
      keys = @sort_keys ? v.keys.sort_by(&:b) : v.keys
      keys.each_with_index do |k, i|
        punct(buf, c, ',') if i.positive?
        newline_indent(buf, level + 1)
        punct(buf, c && col(:key), Encoder.escape_string(k, @ascii))
        punct(buf, c, ':')
        buf << ' ' if @pretty
        write(buf, v[k], level + 1)
      end
      newline_indent(buf, level)
      punct(buf, c, '}')
    end
  end
end
