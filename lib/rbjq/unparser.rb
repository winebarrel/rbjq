# frozen_string_literal: true

module Rbjq
  # Turns an AST back into jq source. Parsing the output gives an equivalent
  # program (numbers may parse as negation, e.g. `-1` as `-(1)`).
  module Unparser
    # Precedence levels, lowest to highest (see Parser).
    PIPE = 0
    COMMA = 1
    ALT = 2
    ASSIGN = 3
    OR = 4
    AND = 5
    COMPARE = 6
    ADD = 7
    MUL = 8
    UNARY = 9
    POSTFIX = 10

    IDENT = /\A[a-zA-Z_][a-zA-Z_0-9]*\z/

    module_function

    def unparse(node)
      str(node, PIPE)
    end

    def str(node, min)
      s, prec = gen(node)
      prec < min ? "(#{s})" : s
    end

    # Returns [source, precedence].
    def gen(node)
      case node[0]
      when :identity then ['.', POSTFIX]
      when :ctx then ['.', POSTFIX] # an unresolved block parameter (only in Expr#inspect)
      when :literal then literal(node[1])
      when :index then index(node)
      when :iterate then ["#{target(node[1])}[]", POSTFIX]
      when :slice then slice(node)
      when :pipe then ["#{str(node[1], COMMA)} | #{str(node[2], PIPE)}", PIPE]
      when :comma then ["#{str(node[1], COMMA)}, #{str(node[2], ALT)}", COMMA]
      when :alt then ["#{str(node[1], ASSIGN)} // #{str(node[2], ALT)}", ALT]
      when :assign then ["#{str(node[2], OR)} #{node[1]} #{str(node[3], ALT)}", ASSIGN]
      when :or then ["#{str(node[1], OR)} or #{str(node[2], AND)}", OR]
      when :and then ["#{str(node[1], AND)} and #{str(node[2], COMPARE)}", AND]
      when :binop then binop(node)
      when :neg then ["-#{str(node[1], POSTFIX)}", UNARY]
      when :call then call(node)
      when :var then ["$#{node[1]}", POSTFIX]
      when :loc then ['$__loc__', POSTFIX]
      when :format then ["@#{node[1]}", POSTFIX]
      when :string then [string(node[1], node[2]), POSTFIX]
      when :array then ["[#{str(node[1], PIPE) if node[1]}]", POSTFIX]
      when :object then [object(node[1]), POSTFIX]
      when :if then [if_chain(node), POSTFIX]
      when :try then try(node)
      when :as then ["#{str(node[1], ALT)} as #{patterns(node[2])} | #{str(node[3], PIPE)}", PIPE]
      when :reduce then reduce(node)
      when :foreach then foreach(node)
      when :func_def then func_def(node)
      when :label then ["label $#{node[1]} | #{str(node[2], PIPE)}", PIPE]
      when :break then ["break $#{node[1]}", POSTFIX]
      else raise ArgumentError, "unknown node #{node[0].inspect}"
      end
    end

    def literal(v)
      case v
      when String then [Encoder.dump(v), POSTFIX]
      when Float
        if v.nan? then ['nan', POSTFIX]
        elsif v.infinite? then [v.positive? ? 'infinite' : '-infinite', UNARY]
        else number(Encoder.format_number(v))
        end
      when Integer then number(Encoder.format_number(v))
      else [Encoder.dump(v), POSTFIX]
      end
    end

    def number(s)
      [s, s.start_with?('-') ? UNARY : POSTFIX]
    end

    # The term before a postfix (`.a`, `[0]`, `[]`, ...); `.` itself is omitted.
    def target(node)
      node == [:identity] ? '.' : str(node, POSTFIX)
    end

    def index(node)
      _, t, key = node
      if key[0] == :literal && key[1].is_a?(String)
        name = key[1]
        suffix = field?(name) ? name : Encoder.dump(name)
        return [t == [:identity] ? ".#{suffix}" : "#{str(t, POSTFIX)}.#{suffix}", POSTFIX]
      end

      ["#{target(t)}[#{str(key, PIPE)}]", POSTFIX]
    end

    def field?(name)
      IDENT.match?(name) && !Lexer::KEYWORDS.include?(name)
    end

    def slice(node)
      _, t, from, to = node
      ["#{target(t)}[#{str(from, PIPE) if from}:#{str(to, PIPE) if to}]", POSTFIX]
    end

    def binop(node)
      _, op, l, r = node
      case op
      when :+, :- then ["#{str(l, ADD)} #{op} #{str(r, MUL)}", ADD]
      when :*, :/, :%
        # `-a * b` parses as `-(a * b)`, so a negation on the left needs parens
        ls = l[0] == :neg || negative_literal?(l) ? "(#{str(l, PIPE)})" : str(l, MUL)
        ["#{ls} #{op} #{str(r, UNARY)}", MUL]
      else ["#{str(l, ADD)} #{op} #{str(r, ADD)}", COMPARE]
      end
    end

    def negative_literal?(node)
      v = node[1]
      node[0] == :literal && v.is_a?(Numeric) && (v.negative? || (v.zero? && (1.0 / v).negative?))
    end

    def call(node)
      _, name, args = node
      return [name, POSTFIX] if args.empty?

      ["#{name}(#{args.map { |a| str(a, PIPE) }.join('; ')})", POSTFIX]
    end

    def string(parts, format)
      body = parts.map do |p|
        p.is_a?(String) ? Encoder.dump(p)[1...-1] : "\\(#{str(p, PIPE)})"
      end.join
      format ? "@#{format} \"#{body}\"" : "\"#{body}\""
    end

    def object(entries)
      return '{}' if entries.empty?

      body = entries.map do |k, v|
        "#{object_key(k)}: #{str(v, ALT)}"
      end
      "{#{body.join(', ')}}"
    end

    def object_key(k)
      if k[0] == :literal && k[1].is_a?(String)
        field?(k[1]) ? k[1] : Encoder.dump(k[1])
      elsif k[0] == :string && k[2].nil?
        string(k[1], nil)
      elsif k[0] == :var
        "$#{k[1]}"
      else
        "(#{str(k, PIPE)})"
      end
    end

    def if_chain(node)
      _, c, t, e = node
      s = "if #{str(c, PIPE)} then #{str(t, PIPE)}"
      while e && e[0] == :if
        s << " elif #{str(e[1], PIPE)} then #{str(e[2], PIPE)}"
        e = e[3]
      end
      s << " else #{str(e, PIPE)}" if e
      s << ' end'
    end

    def try(node)
      _, body, handler = node
      return ["#{str(body, POSTFIX)}?", POSTFIX] if handler.nil?

      ["try #{str(body, POSTFIX)} catch #{str(handler, POSTFIX)}", UNARY]
    end

    def reduce(node)
      _, src, pats, init, update = node
      ["reduce #{str(src, ALT)} as #{patterns(pats)} (#{str(init, PIPE)}; #{str(update, PIPE)})", POSTFIX]
    end

    def foreach(node)
      _, src, pats, init, update, extract = node
      s = "foreach #{str(src, ALT)} as #{patterns(pats)} (#{str(init, PIPE)}; #{str(update, PIPE)}"
      s += "; #{str(extract, PIPE)}" if extract
      ["#{s})", POSTFIX]
    end

    def func_def(node)
      _, name, params, body, rest = node
      ps = params.empty? ? '' : "(#{params.join('; ')})"
      ["def #{name}#{ps}: #{str(body, PIPE)}; #{str(rest, PIPE)}", PIPE]
    end

    def patterns(pats)
      pats.map { |p| pattern(p) }.join(' ?// ')
    end

    def pattern(p)
      case p[0]
      when :pvar then "$#{p[1]}"
      when :parray then "[#{p[1].map { |e| pattern(e) }.join(', ')}]"
      when :pobject
        entries = p[1].map do |key, var, sub|
          if var
            sub ? "$#{var}: #{pattern(sub)}" : "$#{var}"
          else
            "#{object_key(key)}: #{pattern(sub)}"
          end
        end
        "{#{entries.join(', ')}}"
      end
    end
  end
end
