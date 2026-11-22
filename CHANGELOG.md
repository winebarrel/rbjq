# Changelog

## [1.2.0] - 2026-11-22

* `Rbjq.query_json` and `Rbjq.parse_json` take `parser:` to parse the JSON text with another parser, such as `parser: JSON.method(:parse)`. It is much faster than the built-in parser on large input. The parser's exceptions propagate unchanged.

## [1.1.0] - 2026-11-22

* Add `rbjq/expr`, a builder that writes a jq filter as Ruby method chains. `compile`, `query` and `query_json` accept the built filter.

* Index an `Expr` with several keys: `e[:a, :b]` is `.["a", "b"]`.

## [1.0.0] - 2026-11-22

* First release: a pure Ruby implementation of jq 1.8, as a library and as the jq-compatible `rbjq` command.

[1.2.0]: https://github.com/winebarrel/rbjq/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/winebarrel/rbjq/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/winebarrel/rbjq/releases/tag/v1.0.0
