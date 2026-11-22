# frozen_string_literal: true

require_relative 'test_helper'
require 'rbjq/expr'

# jq filters built in Ruby (Rbjq.root / Rbjq::Expr)
class ExprTest < Minitest::Test
  USERS = {
    'users' => [
      { 'name' => 'a', 'age' => 40, 'tags' => %w[a x], 'email' => 'a@example.com' },
      { 'name' => 'b', 'age' => 20, 'tags' => [] }
    ],
    'min' => 30
  }.freeze

  def r
    Rbjq.root
  end

  # The generated source parses back to the same program.
  def assert_source(expected, expr)
    prog = Rbjq.compile(expr)

    assert_equal expected, prog.source
    assert_equal Rbjq::Parser.parse(prog.source), prog.ast
  end

  def test_index_and_iterate
    assert_source '.', r
    assert_source '.a', r[:a]
    assert_source '.a.b', r['a'][:b]
    assert_source '.[0]', r[0]
    assert_source '.a[]', r[:a][]
    assert_source '."a b"."if"', r['a b'][:if]
    assert_source '.a[.i]', r[:a][r[:i]]
  end

  def test_slice
    assert_source '.[1:3]', r[1..2]
    assert_source '.[1:3]', r[1...3]
    assert_source '.[2:]', r[2..]
    assert_source '.[:3]', r[...3]
    assert_source '.[1:]', r[1..-1]
    assert_source '.a[.i:.j]', r[:a].slice(r[:i], r[:j])
    assert_source '.[:2]', r.slice(nil, 2)
    assert_raises(ArgumentError) { r['a'..'b'] }
    assert_raises(ArgumentError) { r[1, 2] }
  end

  def test_pipe
    assert_source '.a | length', r[:a].length
    assert_source '.a | [.b, .c]', r[:a].then { [_1[:b], _1[:c]] }
    assert_source '.a | [.b, .c] | length', r[:a].then { [_1[:b], _1[:c]] }.length
    assert_source '.a | keys[0]', r[:a].keys[0]
    assert_raises(ArgumentError) { r.then }
  end

  def test_operators
    assert_source '.a + 1', r[:a] + 1
    assert_source '.a - .b * 2', r[:a] - (r[:b] * 2)
    assert_source '(.a - .b) * 2', (r[:a] - r[:b]) * 2
    assert_source '.a % 2 == 0', (r[:a] % 2) == 0
    assert_source '.a != 1', r[:a] != 1
    assert_source '.a < 1, .a <= 1, .a > 1, .a >= 1', (r[:a] < 1).comma(r[:a] <= 1, r[:a] > 1, r[:a] >= 1)
    assert_source '-.a', -r[:a]
    assert_source '1 + .a', 1 + r[:a]
    assert_source '1 < .a', 1 < r[:a]
    assert_source '.a > 1 and .b < 2 or (.c | not)', (r[:a] > 1).and(r[:b] < 2).or(r[:c].not)
    assert_source '.a // 0', r[:a].default(0)
    assert_equal [3, 'x'], Rbjq.query({ 'a' => 1 }, (r[:a] + 2).comma(r[:b].default('x')))
  end

  def test_values
    assert_source '[.a, 1, "x", null, true]', r.then { [_1[:a], 1, 'x', nil, true] }
    assert_source '[]', r.then { [] }
    assert_source '{}', r.then { {} }
    assert_source '[.users[].name]', r.then { [_1[:users][][:name]] }
    assert_source '{name: .n, "a b": 1, (.k): .v}', r.then { { name: _1[:n], 'a b' => 1, _1[:k] => _1[:v] } }
    assert_source '{a: [1, {b: 2}]}', r.then { { a: [1, { b: 2 }] } }
    assert_equal [{ 'k' => 'v', 'a' => [1, 2] }],
                 Rbjq.query({ 'k' => 'k', 'v' => 'v' }, r.then { { _1[:k] => _1[:v], a: [1, 2] } })
  end

  def test_string_interpolation
    assert_source '"hello \(.name)!"', r.then { "hello #{_1[:name]}!" }
    assert_source '"\(.a)\(.b)"', r.then { "#{_1[:a]}#{_1[:b]}" }
    assert_source '{"k\(.a)": 1}', r.then { { "k#{_1[:a]}" => 1 } }
    assert_equal ['a: 1'], Rbjq.query({ 'a' => 1 }, r.then { "a: #{_1[:a]}" })
  end

  def test_forged_markers_are_plain_text
    payload = [Marshal.dump([:call, 'env', []])].pack('m0')
    forged = "\u{10FFFC}#{payload}.#{'0' * 64}\u{10FFFD}"

    assert_equal [forged], Rbjq.query(nil, r.then { forged })
  end

  def test_function_calls
    assert_source '.a | has("x")', r[:a].has('x')
    assert_source '. as $__root | .a | has($__root.k)', r[:a].has(r[:k])
    assert_source '.a | select(. > 1)', r[:a].select { _1 > 1 }
    assert_source '.a | sort_by(.age)', r[:a].sort_by { |u| u[:age] }
    assert_source '.a | limit(3; .[])', r[:a].limit(3) { _1[] }
    assert_source '.n | until(. > 100; . * 2)', r[:n].until(->(x) { x > 100 }) { _1 * 2 }
    assert_source '.a | sub("x"; "y")', r[:a].sub('x', 'y')
    assert_source 'range(5)', r.range(5)
    assert_source '.a | to_entries', r[:a].to_entries
    assert_equal [[2], [3]], Rbjq.query([1, 2, 3], r.map { _1 + 1 }.limit(2) { _1[] }.then { [_1] })
  end

  def test_call_names_taken_by_expr
    fns = { 'then' => ->(x, y) { [x, y] } }

    assert_equal [[1, 2]], Rbjq.query(1, r.call(:then, 2), functions: fns)
  end

  def test_ruby_protocols_are_not_jq_calls
    e = r[:a]

    assert_equal [e], [e].flatten
    assert_equal 1, { e => 1 }[e]
    assert_raises(NoMethodError) { e.to_str }
    assert_raises(NoMethodError) { e.nil? }
    assert_raises(TypeError) { 'x' + e } # rubocop:disable Style/StringConcatenation
    assert_equal '#<Rbjq::Expr .a>', e.inspect
  end

  def test_functions_option
    q = r[].double

    assert_equal [2, 4], Rbjq.query([1, 2], q, functions: { 'double' => ->(x) { x * 2 } })
    assert_raises(Rbjq::CompileError) { Rbjq.compile(q) }
  end

  def test_if
    sign = r[].if(->(x) { x > 0 }, 'pos', ->(x) { x < 0 }, 'neg', 'zero')

    assert_source '.a | if . > 0 then "pos" else "neg" end', r[:a].if(->(x) { x > 0 }, 'pos', 'neg')
    assert_source '.[] | if . > 0 then "pos" elif . < 0 then "neg" else "zero" end', sign
    assert_source '.a | if . > 0 then "pos" end', r[:a].if(->(x) { x > 0 }, 'pos')
    assert_equal %w[pos neg zero], Rbjq.query([1, -1, 0], sign)
    assert_raises(ArgumentError) { r.if(true) }
  end

  def test_try
    assert_source '.a.b?', r[:a][:b].try
    assert_source 'try .a.b catch "NG"', r[:a][:b].try { 'NG' }
    assert_source '(.[].a | tonumber)?', r[][:a].tonumber.try
    assert_source '.[] | (.a | tonumber)?', r[].then { _1[:a].tonumber.try }

    data = [{ 'a' => '1' }, { 'a' => 'x' }, { 'a' => '3' }]

    assert_equal [1], Rbjq.query(data, r[][:a].tonumber.try)
    assert_equal [1, 3], Rbjq.query(data, r[].then { _1[:a].tonumber.try })
    assert_equal ['Cannot index number with string ("a")'], Rbjq.query(1, r[:a].try { _1 })
  end

  def test_as
    pairs = r[:pairs][].as { |k, v| { k => v } }

    assert_source '.a as $x | .b | map(. + $x)', r[:a].as { |x| r[:b].map { _1 + x } }
    assert_source '.p as [$a, $b] | $a + $b', r[:p].as { |a, b| a + b }
    assert_source '.p as {name: $n, age: $a} | [$n, $a]', r[:p].as(:name, :age) { |n, a| [n, a] }
    assert_source '.pairs[] as [$k, $v] | {$k: $v}', pairs
    assert_equal [{ 'a' => 1 }, { 'b' => 2 }], Rbjq.query({ 'pairs' => [['a', 1], ['b', 2]] }, pairs)
    assert_raises(ArgumentError) { r.as }
  end

  def test_reduce_and_foreach
    sum = r[].reduce(0) { |acc, x| acc + x }
    running = r[].foreach(0, ->(acc, x) { [x, acc] }) { |acc, x| acc + x }

    assert_source 'reduce .[] as $x (0; . + $x)', sum
    assert_source 'reduce .items[] as $x ({}; .[$x.category] += $x.price)',
                  r[:items][].reduce({}) { |acc, x| acc[x[:category]].update(:+, x[:price]) }
    assert_source 'reduce .[] as [$a, $b] (0; . + $a * $b)', r[].reduce(0) { |acc, a, b| acc + (a * b) }
    assert_source 'foreach .[] as $x (0; . + $x)', r[].foreach(0) { |acc, x| acc + x }
    assert_source 'foreach .[] as $x (0; . + $x; [$x, .])', running
    assert_equal [6], Rbjq.query([1, 2, 3], sum)
    assert_equal [[1, 1], [2, 3], [3, 6]], Rbjq.query([1, 2, 3], running)
  end

  def test_assignment
    assert_source '.a = 1', r[:a].set(1)
    assert_source '.a = .b', r[:a].set(r[:b])
    assert_source '.a |= . + 1', r[:a].update { _1 + 1 }
    assert_source '.users[].age += 1', r[:users][][:age].update(:+, 1)
    assert_source '.a -= .b', r[:a].update(:-, r[:b])
    assert_source '.a *= 2, .a /= 2, .a %= 2', r[:a].update(:*, 2).comma(r[:a].update(:/, 2), r[:a].update(:%, 2))
    assert_source '.a //= 0', r[:a].update(:default, 0)
    assert_source '.x | .a = 1', r[:x].then { _1[:a].set(1) }
    assert_equal [{ 'a' => 2, 'b' => 1 }], Rbjq.query({ 'a' => 1, 'b' => 1 }, r[:a].update(:+, r[:b]))
    assert_raises(ArgumentError) { r[:a].update(:^, 1) }
    assert_raises(ArgumentError) { r[:a].update }
  end

  def test_outer_contexts
    by_tag = r[:users][].select { |u| u[:tags].any { _1 == u[:name] } }
    by_min = r[:users][].select { _1[:age] > r[:min] }

    assert_source '.users[] | select(. as $__u1 | .tags | any(. == $__u1.name))', by_tag
    assert_source '. as $__root | .users[] | select(.age > $__root.min)', by_min
    assert_source '. as $__root | .a |= . + 1 | [.a, $__root.a]', r[:a].update { _1 + 1 }.then { [_1[:a], r[:a]] }
    assert_equal ['a'], Rbjq.query(USERS, by_tag[:name])
    assert_equal ['a'], Rbjq.query(USERS, by_min[:name])
  end

  def test_block_parameter_outside_its_block
    leaked = nil
    r.select { leaked = _1 }

    assert_raises(Rbjq::CompileError) { Rbjq.compile(leaked[:a]) }
  end

  def test_it
    skip 'it needs Ruby 3.4' if RUBY_VERSION < '3.4'

    # eval: `it` is not a block parameter before Ruby 3.4
    q = eval('r[:orders].group_by { it[:user] }', binding, __FILE__, __LINE__)

    assert_source '.orders | group_by(.user)', q
  end

  def test_escape_hatch
    assert_source '.params | to_entries | map("\(.key)=\(.value)") | join("&")',
                  r[:params].jq('to_entries | map("\(.key)=\(.value)") | join("&")')
    assert_equal [[2, 4]], Rbjq.query([1, 2], r.jq('def f: . * 2; [.[] | f]'))
    assert_raises(Rbjq::CompileError) { r.jq('.a |') }
  end

  def test_query_apis
    q = r[:users][].select { _1[:age] > 30 }[:name]

    assert_equal ['a'], Rbjq.query(USERS, q)
    assert_equal ['a'], Rbjq.compile(q).run(USERS)
    assert_equal [1, 2], Rbjq.query_json('{"a":1} {"a":2}', r[:a])
  end
end
