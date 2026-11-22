# rbjq

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
prog.run([1, 2, 3])          #=> [[2, 4, 6]]
prog.each([1, 2]) { |v| p v } # streams outputs

# JSON text in (may contain several values), Ruby values out
Rbjq.query_json('{"a":1} {"a":2}', '.a') #=> [1, 2]

# `input` / `inputs`
Rbjq.compile('[inputs]').run(nil, inputs: [1, 2, 3]) #=> [[1, 2, 3]]
```

Values are plain Ruby objects (`nil`, `true`, `false`, `Integer`, `Float`,
`String`, `Array`, `Hash`). Symbol keys are converted to strings.

Errors:

- `Rbjq::CompileError`: syntax errors and undefined functions or variables
- `Rbjq::JQError`: runtime errors (`#value` holds the error value, e.g. from `error({...})`)
- `Rbjq::ParseError` (a `JQError`): invalid JSON

### Command line

```sh
echo '{"foo": [1, 2]}' | rbjq '.foo | add'
rbjq -n --arg name world '"hello \($name)"'
rbjq -r '.[] | @csv' data.json
```

Supported options: `-n`, `-r`, `-j`, `--raw-output0`, `-a`, `-c`, `-s`, `-R`,
`-S`, `-e`, `-C`, `-M`, `--tab`, `--indent n`, `-f file`, `--arg`,
`--argjson`, `--slurpfile`, `--rawfile`, `--args`, `--jsonargs`, `--stream`,
`--seq`, `--unbuffered`. Exit codes follow jq (1/4 with `-e`, 2 for usage and
input errors, 3 for compile errors, 5 for runtime errors).

## Compatibility

rbjq targets jq 1.7 semantics:

- Full language: pipes, generators, `reduce`/`foreach`, `if/elif/else`,
  `try/catch`, `?`, `label`/`break`, `def` with filter and `$value`
  parameters, recursion, destructuring including `?//`, string interpolation,
  `@format` strings, `$__loc__`, optional/alternative operators, and all
  assignment operators (`=`, `|=`, `+=`, `//=`, ...)
- Path expressions: `path/1`, `paths`, `getpath`/`setpath`/`delpaths`, `del`,
  `pick`, `to_entries`, `tostream`/`fromstream`/`truncate_stream`, `--stream`
- Most builtins, including regex functions (`test`, `match`, `capture`, `scan`,
  `split/2`, `sub`, `gsub`), date functions, math functions, `limit`, `first`,
  `until`, `while`, `repeat`, `walk`, `env`, `input`/`inputs`, `getpath`,
  `splits`, `ltrimstr`, `trim`, `abs`, `toarray`, `have_decnum`, ...
- Output: jq's number formatting (shortest round-trip, `1e+100` style),
  pretty printing, colors (`JQ_COLORS`), `--sort-keys`, `--ascii-output`

The test suite includes 650+ cases whose expected outputs were recorded from
jq 1.7.1.

Known differences:

- Number literals are canonicalized (`1.0` prints as `1`). Large integer
  literals are kept exactly until arithmetic is applied to them.
- `import` / `include` (modules) are not supported.
- Regular expressions use Ruby's Onigmo engine (close to jq's Oniguruma).
- `strftime` always uses English (C locale) names.
- `repeat(f)` follows the documented semantics (`., (f | repeat(f))`).

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
bundle exec rake test
```
