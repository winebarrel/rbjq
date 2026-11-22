# frozen_string_literal: true

module Rbjq
  # Recursive-descent parser producing an array-based AST.
  #
  # Precedence (lowest to highest):
  #   def / as / label  <  |  <  ,  <  //  <  = |= += ...  <  or  <  and
  #   <  == != < <= > >=  <  + -  <  * / %  <  unary -  <  postfix (?, [], .foo)
  class Parser
    ASSIGN_OPS = %i[= |= += -= *= /= %= //=].freeze
    COMPARE_OPS = %i[== != < <= > >=].freeze

    def self.parse(src)
      tokens = Lexer.new(src).tokenize
      parser = new(tokens)
      ast = parser.parse_program
      ast
    end

    def initialize(tokens)
      @tokens = tokens
      @pos = 0
    end

    def parse_program
      skip_module_directives
      ast = if peek.type == :eof
              [:identity]
            else
              parse_pipe
            end
      expect(:eof)
      ast
    end

    # Parses only function definitions (used for library / prelude code).
    def parse_defs
      defs = []
      defs << parse_funcdef while peek.type == :def
      expect(:eof)
      defs
    end

    private

    def peek(offset = 0)
      @tokens[@pos + offset]
    end

    def advance
      t = @tokens[@pos]
      @pos += 1
      t
    end

    def accept(type)
      return nil unless peek.type == type

      advance
    end

    def expect(type)
      t = peek
      unless t.type == type
        raise CompileError, "syntax error, unexpected #{t} (expecting #{type}) at line #{t.line}"
      end

      advance
    end

    def unexpected!
      t = peek
      raise CompileError, "syntax error, unexpected #{t} at line #{t.line}"
    end

    def skip_module_directives
      while %i[import include].include?(peek.type)
        raise CompileError, 'import/include is not supported'
      end
      return unless peek.type == :ident && peek.value == 'module'

      raise CompileError, 'module directive is not supported'
    end

    def parse_pipe
      if peek.type == :def
        fd = parse_funcdef
        body = parse_pipe
        return [:func_def, fd[1], fd[2], fd[3], body]
      end

      lhs = parse_comma
      if accept(:|)
        [:pipe, lhs, parse_pipe]
      else
        lhs
      end
    end

    def parse_funcdef
      expect(:def)
      name_tok = advance
      unless name_tok.type == :ident || Lexer::KEYWORDS.include?(name_tok.value.to_s)
        raise CompileError, "syntax error, unexpected #{name_tok} in def at line #{name_tok.line}"
      end

      params = []
      if accept(:'(')
        loop do
          t = advance
          case t.type
          when :var then params << "$#{t.value}"
          when :ident then params << t.value
          else
            raise CompileError, "syntax error, unexpected #{t} in parameter list at line #{t.line}"
          end
          break unless accept(:';')
        end
        expect(:')')
      end
      expect(:':')
      body = parse_pipe
      expect(:';')
      [:def, name_tok.value, params, body]
    end

    def parse_comma
      lhs = parse_alt
      lhs = [:comma, lhs, parse_alt] while accept(:',')
      lhs
    end

    def parse_alt
      lhs = parse_assign
      if accept(:'//')
        [:alt, lhs, parse_alt]
      else
        lhs
      end
    end

    def parse_assign
      lhs = parse_or
      if ASSIGN_OPS.include?(peek.type)
        op = advance.type
        rhs = parse_alt
        [:assign, op, lhs, rhs]
      else
        lhs
      end
    end

    def parse_or
      lhs = parse_and
      lhs = [:or, lhs, parse_and] while accept(:or)
      lhs
    end

    def parse_and
      lhs = parse_compare
      lhs = [:and, lhs, parse_compare] while accept(:and)
      lhs
    end

    def parse_compare
      lhs = parse_additive
      if COMPARE_OPS.include?(peek.type)
        op = advance.type
        rhs = parse_additive
        lhs = [:binop, op, lhs, rhs]
        if COMPARE_OPS.include?(peek.type)
          raise CompileError, "syntax error, unexpected #{peek} at line #{peek.line}"
        end
      end
      lhs
    end

    def parse_additive
      lhs = parse_multiplicative
      while %i[+ -].include?(peek.type)
        op = advance.type
        lhs = [:binop, op, lhs, parse_multiplicative]
      end
      lhs
    end

    def parse_multiplicative
      lhs = parse_unary
      while %i[* / %].include?(peek.type)
        op = advance.type
        lhs = [:binop, op, lhs, parse_unary]
      end
      lhs
    end

    def parse_unary
      if accept(:-)
        [:neg, parse_multiplicative_operand]
      else
        parse_postfix
      end
    end

    def parse_multiplicative_operand
      lhs = parse_unary
      while %i[* / %].include?(peek.type)
        op = advance.type
        lhs = [:binop, op, lhs, parse_unary]
      end
      lhs
    end

    # Postfix expressions: Term followed by .foo, [..], ?, and optional "as" binding.
    def parse_postfix
      term = parse_primary
      loop do
        t = peek
        case t.type
        when :field
          advance
          term = [:index, term, [:literal, t.value]]
        when :'.'
          if peek(1).type == :str
            advance
            str = parse_string(advance, nil)
            term = [:index, term, str]
          elsif peek(1).type == :'['
            advance
            term = parse_bracket_suffix(term)
          else
            break
          end
        when :'['
          term = parse_bracket_suffix(term)
        when :'?'
          advance
          term = [:try, term, nil]
        when :as
          advance
          patterns = parse_patterns
          expect(:|)
          body = parse_pipe
          return [:as, term, patterns, body]
        else
          break
        end
      end
      term
    end

    def parse_bracket_suffix(term)
      expect(:'[')
      return [:iterate, term] if accept(:']')

      if accept(:':')
        to = parse_pipe
        expect(:']')
        return [:slice, term, nil, to]
      end

      idx = parse_pipe
      if accept(:':')
        if accept(:']')
          return [:slice, term, idx, nil]
        end

        to = parse_pipe
        expect(:']')
        return [:slice, term, idx, to]
      end
      expect(:']')
      [:index, term, idx]
    end

    def parse_primary
      t = peek
      case t.type
      when :num
        advance
        [:literal, t.value]
      when :str
        advance
        parse_string(t, nil)
      when :format
        advance
        if peek.type == :str
          parse_string(advance, t.value)
        else
          [:format, t.value]
        end
      when :'.'
        advance
        if peek.type == :str
          [:index, [:identity], parse_string(advance, nil)]
        else
          [:identity]
        end
      when :'..'
        advance
        [:call, 'recurse', []]
      when :field
        advance
        [:index, [:identity], [:literal, t.value]]
      when :var
        advance
        [:var, t.value]
      when :loc
        advance
        [:loc, t.value]
      when :'('
        advance
        e = parse_pipe
        expect(:')')
        e
      when :'['
        advance
        if accept(:']')
          [:array, nil]
        else
          e = parse_pipe
          expect(:']')
          [:array, e]
        end
      when :'{'
        parse_object
      when :'-'
        advance
        [:neg, parse_postfix]
      when :if
        parse_if
      when :try
        advance
        body = parse_postfix_for_try
        handler = accept(:catch) ? parse_postfix_for_try : nil
        [:try, body, handler]
      when :reduce
        advance
        src = parse_postfix_noas
        expect(:as)
        patterns = parse_patterns
        expect(:'(')
        init = parse_pipe
        expect(:';')
        update = parse_pipe
        expect(:')')
        [:reduce, src, patterns, init, update]
      when :foreach
        advance
        src = parse_postfix_noas
        expect(:as)
        patterns = parse_patterns
        expect(:'(')
        init = parse_pipe
        expect(:';')
        update = parse_pipe
        extract = nil
        extract = parse_pipe if accept(:';')
        expect(:')')
        [:foreach, src, patterns, init, update, extract]
      when :label
        advance
        name = expect(:var).value
        expect(:|)
        body = parse_pipe
        [:label, name, body]
      when :def
        fd = parse_funcdef
        body = parse_pipe
        [:func_def, fd[1], fd[2], fd[3], body]
      when :ident
        advance
        if t.value == 'break'
          name = expect(:var).value
          return [:break, name]
        end
        if peek.type != :'('
          case t.value
          when 'true' then return [:literal, true]
          when 'false' then return [:literal, false]
          when 'null' then return [:literal, nil]
          end
        end
        args = []
        if accept(:'(')
          loop do
            args << parse_pipe
            break unless accept(:';')
          end
          expect(:')')
        end
        [:call, t.value, args]
      else
        unexpected!
      end
    end

    # try body / catch body: a postfix term (binds tighter than binary operators)
    def parse_postfix_for_try
      parse_postfix_noas
    end

    # postfix term without trailing "as" binding (used for reduce/foreach sources)
    def parse_postfix_noas
      term = parse_primary
      loop do
        t = peek
        case t.type
        when :field
          advance
          term = [:index, term, [:literal, t.value]]
        when :'.'
          if peek(1).type == :str
            advance
            term = [:index, term, parse_string(advance, nil)]
          elsif peek(1).type == :'['
            advance
            term = parse_bracket_suffix(term)
          else
            break
          end
        when :'['
          term = parse_bracket_suffix(term)
        when :'?'
          advance
          term = [:try, term, nil]
        else
          break
        end
      end
      term
    end

    def parse_if
      expect(:if)
      cond = parse_pipe
      expect(:then)
      then_branch = parse_pipe
      if accept(:elif)
        @pos -= 1
        @tokens[@pos] = Token.new(:if, 'if', @tokens[@pos].line)
        else_branch = parse_if_chain
        return [:if, cond, then_branch, else_branch]
      end
      else_branch = nil
      else_branch = parse_pipe if accept(:else)
      expect(:end)
      [:if, cond, then_branch, else_branch]
    end

    # parses "if ... end" where the leading token was an elif (shares the final "end")
    def parse_if_chain
      expect(:if)
      cond = parse_pipe
      expect(:then)
      then_branch = parse_pipe
      if accept(:elif)
        @pos -= 1
        @tokens[@pos] = Token.new(:if, 'if', @tokens[@pos].line)
        return [:if, cond, then_branch, parse_if_chain]
      end
      else_branch = nil
      else_branch = parse_pipe if accept(:else)
      expect(:end)
      [:if, cond, then_branch, else_branch]
    end

    def parse_string(tok, format)
      parts = tok.value.map do |part|
        if part.is_a?(String)
          part
        else
          sub = Parser.new(part)
          e = sub.send(:parse_pipe)
          sub.send(:expect, :eof)
          e
        end
      end
      parts = parts.reject { |p| p.is_a?(String) && p.empty? }
      if parts.all?(String) && format.nil?
        [:literal, parts.join]
      elsif parts.empty?
        [:literal, '']
      else
        [:string, parts, format]
      end
    end

    def parse_object
      expect(:'{')
      entries = []
      until accept(:'}')
        t = peek
        key = nil
        value = nil
        case t.type
        when :var
          advance
          if accept(:':')
            key = [:var, t.value]
            value = parse_objval
          else
            key = [:literal, t.value]
            value = [:var, t.value]
          end
        when :loc
          advance
          key = [:literal, '__loc__']
          value = [:loc, t.value]
        when :num
          advance
          key = [:literal, t.value]
          expect(:':')
          value = parse_objval
        when :ident
          advance
          key = [:literal, t.value]
          value = accept(:':') ? parse_objval : [:index, [:identity], key]
        when :str
          advance
          key = parse_string(t, nil)
          value = accept(:':') ? parse_objval : [:index, [:identity], key]
        when :format
          advance
          raise CompileError, "syntax error, unexpected ':' at line #{t.line}" unless peek.type == :str

          key = parse_string(advance, t.value)
          value = accept(:':') ? parse_objval : [:index, [:identity], key]
        when :'('
          advance
          key = parse_pipe
          expect(:')')
          expect(:':')
          value = parse_objval
        else
          if Lexer::KEYWORDS.include?(t.value.to_s) && t.type != :str
            advance
            key = [:literal, t.value]
            value = accept(:':') ? parse_objval : [:index, [:identity], key]
          else
            unexpected!
          end
        end
        entries << [key, value]
        break if accept(:'}')

        expect(:',')
      end
      [:object, entries]
    end

    # Object values: no comma allowed, pipes allowed.
    def parse_objval
      lhs = parse_alt
      lhs = [:pipe, lhs, parse_alt] while accept(:|)
      lhs
    end

    def parse_patterns
      pats = [parse_pattern]
      pats << parse_pattern while accept(:'?//')
      pats
    end

    def parse_pattern
      t = peek
      case t.type
      when :var
        advance
        [:pvar, t.value]
      when :'['
        advance
        elems = []
        unless accept(:']')
          loop do
            elems << parse_pattern
            break unless accept(:',')
          end
          expect(:']')
        end
        [:parray, elems]
      when :'{'
        advance
        entries = []
        loop do
          k = peek
          case k.type
          when :var
            advance
            sub = accept(:':') ? parse_pattern : nil
            entries << [[:literal, k.value], k.value, sub]
          when :ident
            advance
            expect(:':')
            entries << [[:literal, k.value], nil, parse_pattern]
          when :str
            advance
            expect(:':')
            entries << [parse_string(k, nil), nil, parse_pattern]
          when :'('
            advance
            e = parse_pipe
            expect(:')')
            expect(:':')
            entries << [e, nil, parse_pattern]
          else
            if Lexer::KEYWORDS.include?(k.value.to_s)
              advance
              expect(:':')
              entries << [[:literal, k.value], nil, parse_pattern]
            else
              unexpected!
            end
          end
          break unless accept(:',')
        end
        expect(:'}')
        [:pobject, entries]
      else
        unexpected!
      end
    end
  end
end
