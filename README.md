# rbjq

[![Gem Version](https://badge.fury.io/rb/rbjq.svg)](https://badge.fury.io/rb/rbjq)
[![test](https://github.com/winebarrel/rbjq/actions/workflows/test.yml/badge.svg)](https://github.com/winebarrel/rbjq/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/winebarrel/rbjq/graph/badge.svg)](https://codecov.io/gh/winebarrel/rbjq)
[![AI Generated](https://img.shields.io/badge/AI%20Generated-Claude-orange?logo=anthropic)](https://claude.com/product/claude-code)

A pure Ruby implementation of [jq](https://jqlang.github.io/jq/). It has no
native extensions and no runtime dependencies, and works both as a library
and as a jq-compatible command.

## Installation

```sh
gem install rbjq
```

## Usage

### Library

```ruby
require 'rbjq'

Rbjq.query({ 'users' => [{ 'name' => 'a', 'age' => 20 }, { 'name' => 'b', 'age' => 40 }] },
           '.users[] | select(.age > $min) | .name', vars: { min: 30 })
#=> ["b"]

# Compile once, run many times
prog = Rbjq.compile('map(. * 2)')
prog.run([1, 2, 3])           #=> [[2, 4, 6]]
prog.each([1, 2]) { |v| p v } # streams outputs

# JSON text in (may contain several values), Ruby values out
Rbjq.query_json('{"a":1} {"a":2}', '.a') #=> [1, 2]

# `input` / `inputs`
Rbjq.compile('[inputs]').run(nil, inputs: [1, 2, 3]) #=> [[1, 2, 3]]
```

#### Using another JSON parser

The built-in JSON parser is written in Ruby, so it is slow on large input.
`query_json` and `parse_json` take `parser:`, any object that responds to
`call(String)`, to parse the JSON text with something faster instead:

```ruby
require 'json'

Rbjq.query_json(json, '.users[] | .name', parser: JSON.method(:parse))
```

On a 570KB document, `JSON.parse` takes about 2.5ms where the built-in
parser takes about 78ms.

- The parser returns one value, so the JSON text holds one value. With
  `JSON.parse`, text with several values such as `1 2` is an error.
- Numbers are converted the way jq reads them (`1.0` is `1`), but other jq
  extensions are up to the parser: `JSON.parse` rejects `NaN`, and reads
  `-0` as `0`.
- `JSON.parse` in json 3.0 and later rejects duplicate keys such as
  `{"a":1,"a":2}`, and by default it allows 100 levels of nesting where jq
  allows 10,000. To accept both as jq does (json 2.13 and later):

  ```ruby
  parser: ->(s) { JSON.parse(s, allow_duplicate_key: true, max_nesting: false) }
  ```
- Exceptions from the parser propagate unchanged, such as
  `JSON::ParserError`, instead of `Rbjq::ParseError`.

#### jq functions in Ruby

You can implement jq functions in Ruby, either for one program or for every
program compiled afterwards:

```ruby
# for one program
Rbjq.query([1, 2], '.[] | double', functions: { 'double' => ->(x) { x * 2 } }) #=> [2, 4]

# for every program compiled afterwards
Rbjq.define_function('add_n') { |x, n| x + n }
Rbjq.query(3, 'add_n(1, 10)') #=> [4, 13]
Rbjq.undefine_function('add_n')
```

- The first parameter is the input; the others are the arguments, given as
  evaluated values like jq's `$x` parameters. When an argument produces
  several values, the function is called for each combination, with the
  first argument varying slowest (`f(1,2; 10,20)` is called with `1, 10`,
  `1, 20`, `2, 10`, `2, 20`).
- The input and the arguments are deep-frozen copies: a function cannot
  change jq's values in place (modifying them raises `FrozenError`).
- The number of jq arguments comes from the callable's arity. For optional or
  rest parameters, give it in the name: `'count/2' => ->(x, *args) { ... }`.
- A function returns one value. Raise `Rbjq::JQError` to make a jq error that
  `try` can catch; other exceptions propagate to the caller.
- Lookup order: jq definitions (`def`) in the program, then `functions:`,
  then `Rbjq.define_function`, then the builtins. Functions defined with
  `Rbjq.define_function` are captured when a program is compiled.

Values are plain Ruby objects (`nil`, `true`, `false`, `Integer`, `Float`,
`String`, `Array`, `Hash`). Symbol keys are converted to strings.

Errors:

- `Rbjq::CompileError`: syntax errors and undefined functions or variables
- `Rbjq::JQError`: runtime errors (`#value` holds the error value, e.g. from `error({...})`)
- `Rbjq::ParseError` (a `JQError`): invalid JSON

#### Building filters in Ruby

`require 'rbjq/expr'` lets you write a filter as Ruby method chains instead
of a jq string. It is not loaded by `require 'rbjq'`.

```ruby
require 'rbjq/expr'

r = Rbjq.root
q = r[:users][].select { _1[:age] > 30 }[:name]

Rbjq.query(data, q)        # compile / query / query_json accept it
Rbjq.compile(q).source     #=> ".users[] | select(.age > 30).name"
```

`Rbjq.root` is the program's input. A block or lambda passed to a method is
a filter, and its parameter is jq's `.` at that point (`_1`, a named
parameter, or `it` on Ruby 3.4 and later).

| jq | Ruby |
|---|---|
| `.a`, `.[0]`, `.[]` | `r[:a]`, `r[0]`, `r[]` |
| `.["a", "b"]` (outputs `.a`, then `.b`) | `r[:a, :b]` (`r.then { [_1[:a, :b]] }` for `[.a, .b]`) |
| `.[1:3]` | `r[1..2]`, `r[1...3]`, `r.slice(1, 3)` |
| `.a \| f` | `r[:a].f` |
| `.a \| [.b, .c]` | `r[:a].then { [_1[:b], _1[:c]] }`, `r[:a].then { [_1[:b, :c]] }` |
| `.a + 1`, `.a > 1`, `-.a` | `r[:a] + 1`, `r[:a] > 1`, `-r[:a]` |
| `a and b`, `a or b`, `a \| not` | `a.and(b)`, `a.or(b)`, `a.not` or `!a` |
| `a, b, c` | `a.comma(b, c)` |
| `.a // 0` | `r[:a].default(0)` |
| `[.a, 1]`, `{name: .n, (.k): 1}` | `r.then { [_1[:a], 1] }`, `r.then { { name: _1[:n], _1[:k] => 1 } }` |
| `"hi \(.name)"` | `"hi #{r[:name]}"` |
| `select(.age > 30)` | `select { _1[:age] > 30 }` |
| `limit(3; .[])` | `limit(3) { _1[] }` |
| `until(. > 100; . * 2)` | `until(->(x) { x > 100 }) { _1 * 2 }` |
| `if c then a elif c2 then b else d end` | `.if(c, a, c2, b, d)` |
| `f?`, `try f catch g` | `f.try`, `f.try { \|err\| g }` |
| `f as $x \| g` | `f.as { \|x\| g }` |
| `f as [$a, $b] \| g`, `f as {k: $v} \| g` | `f.as { \|a, b\| g }`, `f.as(:k) { \|v\| g }` |
| `reduce .[] as $x (0; . + $x)` | `r[].reduce(0) { \|acc, x\| acc + x }` |
| `foreach .[] as $x (0; . + $x; [$x, .])` | `r[].foreach(0, ->(acc, x) { [x, acc] }) { \|acc, x\| acc + x }` |
| `.a = 1`, `.a \|= . + 1` | `r[:a].set(1)`, `r[:a].update { _1 + 1 }` |
| `.a += 1`, `.a //= 0` | `r[:a].update(:+, 1)`, `r[:a].update(:default, 0)` |
| anything else | `r[:a].jq('to_entries \| from_entries')` |

Objects are Ruby Hashes returned from a block, with Exprs as values (or as
keys, for computed keys). There is no shorthand like jq's `{a, b}`; write
each key and value:

```ruby
r.then { { name: _1[:name], age: _1[:age] } }
# {name: .name, age: .age}  (jq's {name, age})

r[:users][].then { |u| { name: u[:name], tags: u[:tags].length } }
# .users[] | {name: .name, tags: (.tags | length)}

r[:users].map { |u| { name: u[:name], adult: u[:age] >= 20 } }
# .users | map({name: .name, adult: .age >= 20})

r[:users][].then { |u| { u[:name] => u[:age] } }
# .users[] | {(.name): .age}

r[:users][].then { |u| { name: u[:name], total: r[:total] } }
# . as $__root | .users[] | {name: .name, total: $__root.total}
```

- Other methods call the jq function of that name (builtins, `functions:`,
  `Rbjq.define_function`). Arguments are Ruby values (literals), Exprs, or
  filters (blocks or lambdas); a block is the last argument. Use
  `e.call(:name, ...)` for a function whose name is taken by a method above.
- An Expr always refers to the `.` it was made from. `Rbjq.root` is the
  outermost input also inside blocks, and a block parameter can be used in
  nested blocks; the generated program binds them to variables:
  `r[:users][].select { _1[:age] > r[:min] }` is
  `. as $__root | .users[] | select(.age > $__root.min)`.
- A method applies to the whole chain before it: `r[][:a].tonumber.try` is
  `(.[].a | tonumber)?`, which stops at the first error. For
  `.[] | (.a | tonumber)?`, write `r[].then { _1[:a].tonumber.try }`.
- Use `and`/`or`, not `&&`/`||`: Ruby treats every Expr as true. Put the
  Expr on the left of `==` (`1 == e` is a Ruby comparison).
- A Ruby Array or String cannot start a chain (`[r[:a]].length` calls
  Ruby's method); build it inside `then`: `r.then { [_1[:a]] }.length`.
- An Expr in a String (`"#{e}"`) becomes a signed marker that only the
  builder turns back into an interpolation, so do not print or store it.
- Not supported: `def`, `label`/`break`, `?//`, `$__loc__`, `@format`
  strings, and nested destructuring (use `jq('...')`).

### Command line

```sh
echo '{"foo": [1, 2]}' | rbjq '.foo | add'
rbjq -n --arg name world '"hello \($name)"'
rbjq -r '.[] | @csv' data.json
```

Supported options: `-n`, `-r`, `-j`, `--raw-output0`, `-a`, `-c`, `-s`, `-R`,
`-S`, `-e`, `-C`, `-M`, `--tab`, `--indent n`, `-f file`, `--arg`,
`--argjson`, `--slurpfile`, `--rawfile`, `--args`, `--jsonargs`, `--stream`,
`--seq`, `--unbuffered`. Exit codes follow jq: 1 or 4 with `-e`, 2 for usage
errors and unreadable files, 3 for compile errors, and 5 for runtime errors
and invalid JSON input (decided by the last input, like jq).

## Compatibility

rbjq targets jq 1.8.2:

- Full language: pipes, generators, `reduce`/`foreach`, `if/elif/else`,
  `try/catch`, `?`, `label`/`break`, `def` with filter and `$value`
  parameters, recursion, destructuring including `?//`, string interpolation,
  `@format` strings, `$__loc__`, optional/alternative operators, and all
  assignment operators (`=`, `|=`, `+=`, `//=`, ...)
- Path expressions: `path/1`, `paths`, `getpath`/`setpath`/`delpaths`, `del`,
  `pick`, `to_entries`, `tostream`/`fromstream`/`truncate_stream`, `--stream`
- The builtins of jq 1.8.2, including regex functions (`test`, `match`,
  `capture`, `scan`, `splits`, `sub`, `gsub`), date functions, math functions
  (including `j0`/`y0` and friends), `limit`, `skip`, `first`, `nth`,
  `until`, `repeat`, `walk`, `pick`, `toboolean`, `trimstr`, `@urid`,
  `input`/`inputs`, `input_line_number`, `getpath`, `bsearch`, `JOIN`, ...
- jq's error messages, including JSON parse errors
- Depth limits like jq: values nested more than 10,000 levels deep are
  reported as too deep (parsing, printing, comparison, paths, ...)
- Output: jq's number formatting, pretty printing (`--indent`, `--tab`),
  colors (`JQ_COLORS`), `--sort-keys`, `--ascii-output`, `--seq`

Tests:

- `test/upstream_test.rb`: jq's own test suite from jq 1.8.2 (879 cases;
  15 are skipped). `rake test` downloads it into `test/jq/` first
  (`rake jq:download`; the files are pinned by tag and SHA-256).
- `test/spec/`: specification tests by area, in jq's test format, whose
  expected outputs were recorded from jq 1.8.2
- `test/fixtures/jq_compat.tsv`: 650+ more cases recorded from jq 1.8.2

Known differences:

- Numbers are IEEE 754 doubles, like jq built without decNumber
  (`have_decnum` is `false`): number literals are not preserved, so `1.0`
  prints as `1` and `100000000000000000001` as `100000000000000000000`.
- `import` / `include` (modules) are not supported.
- Regular expressions use Ruby's Onigmo engine (close to jq's Oniguruma).
- `strftime` always uses the C locale, and `gamma` is `lgamma`.
- Bessel functions may differ from libm in the last digits.

### Performance and recursion

Evaluation is a tree-walking interpreter on Ruby blocks. Expect roughly 10x
the run time of the C jq on large inputs.

The evaluator uses the Ruby stack, so the maximum recursion depth of a jq
program depends on the stack size and the platform. The `rbjq` command runs
with a 1GB thread stack, which is enough for tens of thousands of levels.
If the stack is exhausted, it reports `stack overflow` and exits with
status 5. You can change the size with the `RUBY_THREAD_VM_STACK_SIZE` and
`RUBY_THREAD_MACHINE_STACK_SIZE` environment variables. When you use the
library with deep recursion, run it in a thread and start Ruby with these
variables set to larger values. With the default Ruby stack, the limit is
around 1,000 levels.

## Development

```sh
bundle install
bundle exec rake test   # downloads jq's test suite on the first run
```
