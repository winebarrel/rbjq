# frozen_string_literal: true

# Expr is a BasicObject (no is_a?/nil?), so values that may be Exprs are
# tested with Class#===.
# rubocop:disable Style/CaseEquality

require 'digest'
require_relative '../rbjq'
require_relative 'unparser'

module Rbjq
  # Builds jq ASTs from Ruby code (see Expr).
  #
  # Inside a block, the block parameter stands for jq's `.` at that point.
  # Such a parameter is stored as a [:ctx, id, label] node. When the block
  # returns, the node becomes `.` where `.` is still the block's input, and
  # `$__label1` (bound by `. as $__label1 | ...` at the top of the block body)
  # where `.` has changed, e.g. inside a nested block. Rbjq.root is the
  # outermost context and is resolved when the program is compiled.
  module ExprBuilder
    ROOT_ID = 0

    ASSIGN_OPS = {
      :+ => :'+=', :- => :'-=', :* => :'*=', :/ => :'/=', :% => :'%=', :default => :'//='
    }.freeze

    # Ruby protocol methods that must not become jq calls (implicit
    # conversions, Hash keys, pp, Marshal, ...).
    NOT_JQ = /\A(?:to_(?!entries\z)|pretty_print|marshal_|_dump\z|encode_with\z|init_with\z)|[?!=]\z/

    MARK_OPEN = "\u{10FFFC}"
    MARK_CLOSE = "\u{10FFFD}"
    MARK_RE = %r{\u{10FFFC}([A-Za-z0-9+/]*=*)\.(\h{64})\u{10FFFD}}

    @mutex = Mutex.new
    @last_id = ROOT_ID
    @key = Random.urandom(32)

    class << self
      def root
        Expr.new([:ctx, ROOT_ID, 'root'])
      end

      def next_id
        @mutex.synchronize { @last_id += 1 }
      end

      # Ruby value -> AST
      def lift(v)
        case v
        when Expr then v.__ast__
        when Proc then filter(v)
        when nil, true, false then [:literal, v]
        when Integer, Float then [:literal, Value.normalize_number(v)]
        when String then string(v)
        when Symbol then [:literal, v.to_s]
        when Array then array(v)
        when Hash then [:object, v.map { |k, x| [key(k), lift(x)] }]
        when Struct then lift(v.to_h)
        else lift(Program.normalize_value(v))
        end
      end

      def array(elems)
        return [:array, nil] if elems.empty?

        [:array, elems.map { |e| lift(e) }.reduce { |a, b| [:comma, a, b] }]
      end

      def key(k)
        Symbol === k ? [:literal, k.to_s] : lift(k) # k may be an Expr (no is_a?)
      end

      # A block or lambda used as a filter: its parameter is `.`.
      def filter(pr)
        id = next_id
        label = label_for(pr.parameters.first)
        body = lift(invoke(pr, [Expr.new([:ctx, id, label])]))
        close(body, id, label)
      end

      def invoke(pr, args)
        if pr.lambda? && pr.arity >= 0
          pr.call(*args.first(pr.arity))
        else
          pr.call(*args)
        end
      end

      def label_for(param)
        name = param && param[1]&.to_s
        name&.match?(/\A[a-z][a-zA-Z0-9_]*\z/) ? name : 'it'
      end

      def var_name(param, i)
        name = param && param[1]&.to_s
        name&.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/) ? name : "__v#{i}"
      end

      # Pattern and variables for the parameters of an `as`/`reduce`/`foreach` block.
      def bind_pattern(params, keys = [])
        if keys.empty?
          n = [params.size, 1].max
          names = Array.new(n) { |i| var_name(params[i], i) }
          pat = n == 1 ? [:pvar, names[0]] : [:parray, names.map { |nm| [:pvar, nm] }]
        else
          names = Array.new(keys.size) { |i| var_name(params[i], i) }
          pat = [:pobject, keys.zip(names).map { |k, nm| [[:literal, k.to_s], nil, [:pvar, nm]] }]
        end
        [pat, names.map { |nm| Expr.new([:var, nm]) }]
      end

      # (a | b) | c is a | (b | c), which reads better as jq source
      def pipe(l, r)
        l[0] == :pipe ? [:pipe, l[1], pipe(l[2], r)] : [:pipe, l, r]
      end

      # (a | b).k is a | b.k when the operands (k) do not depend on `.`
      def postfix(target, *operands, &build)
        if target[0] == :pipe && operands.all? { |o| o.nil? || o[0] == :literal }
          [:pipe, target[1], postfix(target[2], *operands, &build)]
        else
          build.call(target)
        end
      end

      def if_node(list)
        c, t, *rest = list
        e = case rest.size
            when 0 then nil
            when 1 then rest[0]
            else if_node(rest)
            end
        [:if, c, t, e]
      end

      # Replaces context `id` in ast; binds it to a variable if needed.
      def close(ast, id, label)
        bound = false
        out = resolve(ast, id, true) { bound = true }
        bound ? [:as, [:identity], [[:pctx, id, label]], out] : out
      end

      # same: whether `.` at this node is still the context's `.`
      def resolve(node, id, same, &on_bind)
        return node unless node.is_a?(Array)

        r = ->(n, s = same) { resolve(n, id, s, &on_bind) }
        case node[0]
        when :ctx
          return node unless node[1] == id
          return [:identity] if same

          on_bind.call
          [:ctxvar, id, node[2]]
        when :identity, :literal, :var, :loc, :format, :break, :ctxvar then node
        when :index then [:index, r.call(node[1]), r.call(node[2])]
        when :iterate then [:iterate, r.call(node[1])]
        when :slice then [:slice, r.call(node[1]), r.call(node[2]), r.call(node[3])]
        when :pipe
          l = r.call(node[1])
          l == [:identity] ? r.call(node[2]) : [:pipe, l, r.call(node[2], false)]
        when :comma, :and, :or, :alt then [node[0], r.call(node[1]), r.call(node[2])]
        when :binop then [:binop, node[1], r.call(node[2]), r.call(node[3])]
        when :neg then [:neg, r.call(node[1])]
        when :call then [:call, node[1], node[2].map { |a| r.call(a, false) }]
        when :if then [:if, r.call(node[1]), r.call(node[2]), r.call(node[3])]
        when :try then [:try, r.call(node[1]), r.call(node[2], false)]
        when :as then [:as, r.call(node[1]), node[2], r.call(node[3])]
        when :array then [:array, r.call(node[1])]
        when :object then [:object, node[1].map { |k, v| [r.call(k), r.call(v)] }]
        when :string then [:string, node[1].map { |p| p.is_a?(String) ? p : r.call(p) }, node[2]]
        when :reduce then [:reduce, r.call(node[1]), node[2], r.call(node[3]), r.call(node[4], false)]
        when :foreach then [:foreach, r.call(node[1]), node[2], r.call(node[3]), r.call(node[4], false),
                            r.call(node[5], false)]
        when :func_def then [:func_def, node[1], node[2], r.call(node[3], false), r.call(node[4])]
        when :assign then [:assign, node[1], r.call(node[2]), r.call(node[3], node[1] != :'|=' && same)]
        when :label then [:label, node[1], r.call(node[2])]
        else raise ArgumentError, "unknown node #{node[0].inspect}"
        end
      end

      # The AST of a whole program built from Rbjq.root.
      def finalize(ast)
        name_vars(close(ast, ROOT_ID, 'root'), strict: true)
      end

      def inspect_source(ast)
        Unparser.unparse(name_vars(close(ast, ROOT_ID, 'root'), strict: false))
      rescue StandardError => e
        "<#{e.class}: #{e.message}>"
      end

      # Gives the context variables names in order of appearance.
      def name_vars(ast, strict:)
        names = {}
        counts = Hash.new(0)
        name = lambda do |(_, id, label)|
          names[id] ||= id == ROOT_ID ? '__root' : "__#{label}#{counts[label] += 1}"
        end
        walk = lambda do |n|
          next n unless n.is_a?(Array)

          case n[0]
          when :ctx
            raise CompileError, 'a block parameter is used outside its block' if strict

            [:identity] # Expr#inspect inside a block: the block's `.`
          when :ctxvar then [:var, name.call(n)]
          when :pctx then [:pvar, name.call(n)]
          else n.map { |c| walk.call(c) }
          end
        end
        walk.call(ast)
      end

      # ------------------------------------------------ string interpolation
      #
      # Expr#to_s returns a marker holding the AST, signed with a per-process
      # key, so that "#{expr}" in a String can be turned back into jq string
      # interpolation. Markers that fail the check are kept as plain text.

      def marker(ast)
        payload = [Marshal.dump(ast)].pack('m0')
        "#{MARK_OPEN}#{payload}.#{hmac(payload)}#{MARK_CLOSE}"
      end

      def string(s)
        return [:literal, s] unless s.encoding == Encoding::UTF_8 && s.valid_encoding? && s.include?(MARK_OPEN)

        parts = []
        pos = 0
        s.scan(MARK_RE) do
          m = Regexp.last_match
          ast = unmark(m[1], m[2])
          next unless ast

          parts << s[pos...m.begin(0)]
          parts << ast
          pos = m.end(0)
        end
        parts << s[pos..]
        parts = parts.reject { |p| p.is_a?(String) && p.empty? }
        parts.all?(String) ? [:literal, parts.join] : [:string, parts, nil]
      end

      def unmark(payload, mac)
        return nil unless hmac(payload) == mac

        Marshal.load(payload.unpack1('m0')) # rubocop:disable Security/MarshalLoad
      end

      def hmac(data)
        k = @key.ljust(64, "\0").bytes
        ipad = k.map { |b| b ^ 0x36 }.pack('C*')
        opad = k.map { |b| b ^ 0x5c }.pack('C*')
        Digest::SHA256.hexdigest(opad + Digest::SHA256.digest(ipad + data))
      end
    end
  end

  # A jq filter built from Ruby code. Start from Rbjq.root (the program's
  # input) and chain methods; pass the result to Rbjq.compile / Rbjq.query.
  #
  #   q = Rbjq.root[:users][].select { _1[:age] > 30 }[:name]
  #   Rbjq.query(data, q)
  #
  # Methods other than the ones below call the jq function of that name with
  # the receiver as input (`e.length` is `e | length`). Arguments are Ruby
  # values (literals), Exprs, or a block / lambda (a filter whose parameter
  # is `.`); a block is the last argument.
  class Expr < BasicObject
    def initialize(ast)
      @ast = ast
    end

    def __ast__
      @ast
    end

    # e[:a] is .a, e[0] is .[0], e[] is .[], e[1..2] is .[1:3],
    # e[:a, :b] is .["a", "b"] (outputs .a, then .b)
    def [](*args)
      case args.size
      when 0 then wrap(ExprBuilder.postfix(@ast) { |t| [:iterate, t] })
      when 1
        k = args[0]
        return range_slice(k) if ::Range === k

        key = ExprBuilder.key(k)
        wrap(ExprBuilder.postfix(@ast, key) { |t| [:index, t, key] })
      else
        multi_index(args)
      end
    end

    # .[from:to] (`to` is exclusive; nil leaves a side open)
    def slice(from, to = nil)
      from = ::NilClass === from ? nil : ExprBuilder.lift(from)
      to = ::NilClass === to ? nil : ExprBuilder.lift(to)
      wrap(ExprBuilder.postfix(@ast, from, to) { |t| [:slice, t, from, to] })
    end

    %i[+ - * / % == != < <= > >=].each do |op|
      define_method(op) { |other| wrap([:binop, op, @ast, ExprBuilder.lift(other)]) }
    end

    def -@
      wrap([:neg, @ast])
    end

    # !e is e | not (BasicObject#! would make it false)
    def !
      wrap(ExprBuilder.pipe(@ast, [:call, 'not', []]))
    end

    # 1 + e, 1 < e
    def coerce(other)
      [Expr.new(ExprBuilder.lift(other)), self]
    end

    def and(other)
      wrap([:and, @ast, ExprBuilder.lift(other)])
    end

    def or(other)
      wrap([:or, @ast, ExprBuilder.lift(other)])
    end

    # e, a, b
    def comma(*others)
      wrap(others.reduce(@ast) { |a, o| [:comma, a, ExprBuilder.lift(o)] })
    end

    # e // other
    def default(other)
      wrap([:alt, @ast, ExprBuilder.lift(other)])
    end

    # e | <block>
    def then(&blk)
      ::Kernel.raise ::ArgumentError, 'then requires a block' unless blk

      wrap(ExprBuilder.pipe(@ast, ExprBuilder.filter(blk)))
    end

    # e | if c then a elif c2 then b else d end: if(c, a, c2, b, d)
    def if(*args)
      ::Kernel.raise ::ArgumentError, 'if requires a condition and a value' if args.size < 2

      wrap(ExprBuilder.pipe(@ast, ExprBuilder.if_node(args.map { |a| ExprBuilder.lift(a) })))
    end

    # e? / try e catch <block>
    def try(&blk)
      wrap([:try, @ast, blk && ExprBuilder.filter(blk)])
    end

    # e as $x | <block>; as(:a, :b) { |a, b| } is e as {a: $a, b: $b} | ...
    def as(*keys, &blk)
      ::Kernel.raise ::ArgumentError, 'as requires a block' unless blk

      pat, vars = ExprBuilder.bind_pattern(blk.parameters, keys)
      wrap([:as, @ast, [pat], ExprBuilder.lift(ExprBuilder.invoke(blk, vars))])
    end

    # reduce e as $x (init; <block>): reduce(init) { |acc, x| ... }
    def reduce(init, &blk)
      ::Kernel.raise ::ArgumentError, 'reduce requires a block' unless blk

      pat, _, update = reduce_parts(blk)
      wrap([:reduce, @ast, [pat], ExprBuilder.lift(init), update])
    end

    # foreach e as $x (init; <block>; extract): foreach(init, ->(acc, x) { }) { |acc, x| ... }
    def foreach(init, extract = nil, &blk)
      ::Kernel.raise ::ArgumentError, 'foreach requires a block' unless blk

      pat, vars, update = reduce_parts(blk)
      ex = if ::Proc === extract
             id = ExprBuilder.next_id
             label = ExprBuilder.label_for(extract.parameters.first)
             body = ExprBuilder.invoke(extract, [Expr.new([:ctx, id, label]), *vars])
             ExprBuilder.close(ExprBuilder.lift(body), id, label)
           elsif !(::NilClass === extract)
             ExprBuilder.lift(extract)
           end
      wrap([:foreach, @ast, [pat], ExprBuilder.lift(init), update, ex])
    end

    # e = v
    def set(value)
      wrap([:assign, :'=', @ast, ExprBuilder.lift(value)])
    end

    # e |= <block>; update(:+, v) is e += v; update(:default, v) is e //= v
    def update(*args, &blk)
      if args.empty? && blk
        wrap([:assign, :'|=', @ast, ExprBuilder.filter(blk)])
      elsif args.size == 2 && !blk
        op = ExprBuilder::ASSIGN_OPS.fetch(args[0]) do
          ::Kernel.raise ::ArgumentError, "unknown update operator: #{args[0].inspect}"
        end
        wrap([:assign, op, @ast, ExprBuilder.lift(args[1])])
      else
        ::Kernel.raise ::ArgumentError, 'update takes a block, or an operator and a value'
      end
    end

    # e | <jq source>
    def jq(source)
      wrap(ExprBuilder.pipe(@ast, Parser.parse(source)))
    end

    # Calls a jq function whose name is taken by a method of Expr.
    def call(name, *args, &blk)
      args = args.map { |a| ExprBuilder.lift(a) }
      args << ExprBuilder.filter(blk) if blk
      wrap(ExprBuilder.pipe(@ast, [:call, name.to_s, args]))
    end

    def to_s
      ExprBuilder.marker(@ast)
    end

    def inspect
      "#<Rbjq::Expr #{ExprBuilder.inspect_source(@ast)}>"
    end

    def hash
      __id__.hash
    end

    def eql?(other)
      equal?(other)
    end

    private

    def wrap(ast)
      Expr.new(ast)
    end

    # Numbers are rejected: e[1, 2] reads as start and length in Ruby.
    def multi_index(keys)
      if keys.any? { |k| ::Numeric === k || ::Range === k }
        ::Kernel.raise ::ArgumentError, "keys must be Symbols, Strings or Exprs: #{keys.inspect}"
      end

      key = keys.map { |k| ExprBuilder.key(k) }.reduce { |a, b| [:comma, a, b] }
      wrap([:index, @ast, key])
    end

    def range_slice(range)
      from = range.begin
      to = range.end
      [from, to].each do |v|
        unless v.nil? || v.is_a?(::Integer)
          ::Kernel.raise ::ArgumentError,
                         "slice bounds must be Integers: #{range.inspect}"
        end
      end
      to = if to.nil? then nil
           elsif range.exclude_end? then to
           elsif to == -1 then nil
           else to + 1
           end
      from &&= [:literal, from]
      to &&= [:literal, to]
      wrap(ExprBuilder.postfix(@ast, from, to) { |t| [:slice, t, from, to] })
    end

    def reduce_parts(blk)
      params = blk.parameters
      id = ExprBuilder.next_id
      label = ExprBuilder.label_for(params[0])
      pat, vars = ExprBuilder.bind_pattern(params.drop(1))
      body = ExprBuilder.invoke(blk, [Expr.new([:ctx, id, label]), *vars])
      [pat, vars, ExprBuilder.close(ExprBuilder.lift(body), id, label)]
    end

    def method_missing(name, *, &)
      if ExprBuilder::NOT_JQ.match?(name.to_s)
        ::Kernel.raise ::NoMethodError.new("undefined method '#{name}' for an instance of Rbjq::Expr", name,
                                           receiver: self)
      end

      call(name, *, &)
    end

    def respond_to_missing?(name, _include_private = false)
      !ExprBuilder::NOT_JQ.match?(name.to_s)
    end
  end

  class << self
    # The program's input, the starting point for building a filter in Ruby
    # (see Rbjq::Expr). It always means the outermost input, also inside
    # blocks.
    #
    #   require 'rbjq/expr'
    #   Rbjq.query(data, Rbjq.root[:users][].select { _1[:age] > 30 }[:name])
    def root
      ExprBuilder.root
    end
  end
end
# rubocop:enable Style/CaseEquality
