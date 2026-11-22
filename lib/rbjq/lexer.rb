# frozen_string_literal: true

module Rbjq
  Token = Struct.new(:type, :value, :line) do
    def to_s
      case type
      when :ident, :field, :var, :format, :num then value.to_s
      when :str then 'string'
      when :eof then 'end of file'
      else type.to_s
      end
    end
  end

  class Lexer
    KEYWORDS = %w[
      def if then elif else end as reduce foreach try catch label import include and or __loc__
    ].freeze

    PUNCTS = [
      '?//', '|=', '+=', '-=', '*=', '/=', '%=', '//=', '==', '!=', '<=', '>=', '//', '..',
      '|', ',', '+', '-', '*', '/', '%', '=', '<', '>', '.', '[', ']', '{', '}', '(', ')', ':', ';', '?'
    ].freeze

    IDENT_RE = /[a-zA-Z_][a-zA-Z_0-9]*(?:::[a-zA-Z_][a-zA-Z_0-9]*)*/
    NUM_RE = /(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?/

    def initialize(src)
      @src = src
      @pos = 0
      @line = 1
    end

    def tokenize
      tokens = lex(false)
      tokens << Token.new(:eof, nil, @line)
      tokens
    end

    private

    def error(msg)
      raise CompileError, "syntax error: #{msg} at line #{@line}"
    end

    # Lex until EOF, or (when in_interp) until the closing paren of a string interpolation.
    def lex(in_interp)
      tokens = []
      depth = 0
      loop do
        skip_space
        if @pos >= @src.length
          error('unterminated string interpolation') if in_interp
          return tokens
        end

        c = @src[@pos]
        if c == '"'
          @pos += 1
          tokens << Token.new(:str, lex_string, @line)
        elsif (m = match(NUM_RE)) && !(c == '.' && @src[@pos + 1] !~ /[0-9]/)
          @pos += m.length
          tokens << Token.new(:num, parse_number(m), @line)
        elsif c == '.' && (m = match(/\.([a-zA-Z_][a-zA-Z_0-9]*)/))
          @pos += m.length
          tokens << Token.new(:field, m[1..], @line)
        elsif c == '$' && (m = match(/\$(#{IDENT_RE})/o))
          @pos += m.length
          name = m[1..]
          tokens << (name == '__loc__' ? Token.new(:loc, @line, @line) : Token.new(:var, name, @line))
        elsif c == '@' && (m = match(/@([a-zA-Z0-9_]+)/))
          @pos += m.length
          tokens << Token.new(:format, m[1..], @line)
        elsif (m = match(IDENT_RE))
          @pos += m.length
          tokens << (KEYWORDS.include?(m) ? Token.new(m.to_sym, m, @line) : Token.new(:ident, m, @line))
        else
          p = PUNCTS.find { |s| @src[@pos, s.length] == s }
          error("unexpected character #{c.inspect}") unless p
          if in_interp
            if p == '('
              depth += 1
            elsif p == ')'
              if depth.zero?
                @pos += 1
                return tokens
              end
              depth -= 1
            end
          end
          @pos += p.length
          tokens << Token.new(p.to_sym, p, @line)
        end
      end
    end

    def match(re)
      m = re.match(@src, @pos)
      m && m.begin(0) == @pos ? m[0] : nil
    end

    def skip_space
      while @pos < @src.length
        c = @src[@pos]
        if c == "\n"
          @line += 1
          @pos += 1
        elsif [' ', "\t", "\r"].include?(c)
          @pos += 1
        elsif c == '#'
          @pos += 1 while @pos < @src.length && @src[@pos] != "\n"
        else
          break
        end
      end
    end

    def parse_number(s)
      if s.match?(/[.eE]/)
        f = Value.parse_float(s.start_with?('.') ? "0#{s}" : s.sub(/\.(?![0-9])/, '.0'))
        Value.normalize_number(f)
      else
        Value.normalize_number(Integer(s, 10))
      end
    end

    # Returns an array of parts: String or Array (tokens of an interpolation)
    def lex_string
      parts = []
      buf = +''
      loop do
        error('unterminated string') if @pos >= @src.length
        c = @src[@pos]
        if c == '"'
          @pos += 1
          parts << buf unless buf.empty? && !parts.empty?
          return parts
        elsif c == '\\'
          e = @src[@pos + 1]
          @pos += 2
          case e
          when 'n' then buf << "\n"
          when 't' then buf << "\t"
          when 'r' then buf << "\r"
          when 'b' then buf << "\b"
          when 'f' then buf << "\f"
          when '"' then buf << '"'
          when '\\' then buf << '\\'
          when '/' then buf << '/'
          when 'u'
            hex = @src[@pos, 4]
            error('invalid \\u escape') unless hex&.match?(/\A[0-9a-fA-F]{4}\z/)
            @pos += 4
            cp = hex.to_i(16)
            lo = @src[@pos + 2, 4] if @src[@pos, 2] == '\\u'
            if cp.between?(0xD800, 0xDBFF) && lo&.match?(/\A[dD][c-fC-F][0-9a-fA-F]{2}\z/)
              @pos += 6
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo.to_i(16) - 0xDC00)
            elsif cp.between?(0xD800, 0xDBFF)
              # like jq: a high surrogate must be followed by a low one
              error('Invalid \\uXXXX\\uXXXX surrogate pair escape')
            elsif cp.between?(0xDC00, 0xDFFF)
              cp = 0xFFFD
            end
            buf << cp.chr(Encoding::UTF_8)
          when '('
            parts << buf
            buf = +''
            toks = lex(true)
            toks << Token.new(:eof, nil, @line)
            parts << toks
          else
            error("invalid escape \\#{e}")
          end
        else
          @line += 1 if c == "\n"
          buf << c
          @pos += 1
        end
      end
    end
  end
end
