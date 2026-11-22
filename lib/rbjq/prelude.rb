# frozen_string_literal: true

module Rbjq
  # Builtins defined in the jq language itself.
  #
  # Most definitions follow jq 1.8.2's src/builtin.jq, which is distributed
  # under the MIT license (Copyright (C) 2012 Stephen Dolan and jq
  # contributors; see LICENSE-jq). The rest are implemented in Ruby
  # (lib/rbjq/builtins.rb).
  PRELUDE = <<~'JQ'
    def values: select(. != null);
    def nulls: select(. == null);
    def booleans: select(type == "boolean");
    def numbers: select(type == "number");
    def strings: select(type == "string");
    def arrays: select(type == "array");
    def objects: select(type == "object");
    def iterables: select(type|. == "array" or . == "object");
    def scalars: select(type|. != "array" and . != "object");
    def isfinite: type == "number" and (isinfinite | not);
    def finites: select(isfinite);
    def normals: select(isnormal);
    def recurse(f; cond): def r: ., (f | select(cond) | r); r;
    def map(f): [.[] | f];
    def map_values(f): .[] |= f;
    def with_entries(f): to_entries | map(f) | from_entries;
    def add(f): reduce f as $x (null; . + $x);
    def del(f): delpaths([path(f)]);
    def abs: if . < 0 then - . else . end;
    def paths: path(..) | select(length > 0);
    def paths(node_filter): path(.. | select(node_filter)) | select(length > 0);
    def any(generator; condition): isempty(first(generator | condition or empty)) | not;
    def all(generator; condition): isempty(first(generator | condition and empty));
    def any(condition): any(.[]; condition);
    def all(condition): all(.[]; condition);
    def any: any(.[]; .);
    def all: all(.[]; .);
    def in(xs): . as $x | xs | has($x);
    def inside(xs): . as $x | xs | contains($x);
    def nth($n): .[$n];
    def first: .[0];
    def last: .[-1];
    def reverse: [.[length - 1 - range(0; length)]];
    def index($i): indices($i) | .[0];
    def rindex($i): indices($i) | .[-1:][0];
    def sort_by(f): _sort_by_impl(map([f]));
    def group_by(f): _group_by_impl(map([f]));
    def unique_by(f): _unique_by_impl(map([f]));
    def min_by(f): _min_by_impl(map([f]));
    def max_by(f): _max_by_impl(map([f]));
    def combinations: if length == 0 then [] else .[0][] as $x | (.[1:] | combinations) as $y | [$x] + $y end;
    def combinations(n): . as $dot | [range(n) | $dot] | combinations;
    def walk(f): def w: if type == "object" then map_values(w) elif type == "array" then map(w) else . end | f; w;
    def env: $ENV;
    def halt_error: halt_error(5);
    def todateiso8601: strftime("%Y-%m-%dT%H:%M:%SZ");
    def fromdateiso8601: strptime("%Y-%m-%dT%H:%M:%SZ") | mktime;
    def todate: todateiso8601;
    def fromdate: fromdateiso8601;
    def match(re; mode): _match_impl(re; mode; false) | .[];
    def match($val): ($val | type) as $vt
      | if $vt == "string" then match($val; null)
        elif $vt == "array" and ($val | length) > 1 then match($val[0]; $val[1])
        elif $vt == "array" and ($val | length) > 0 then match($val[0]; null)
        else error($vt + " not a string or array") end;
    def test(re; mode): _match_impl(re; mode; true);
    def test($val): ($val | type) as $vt
      | if $vt == "string" then test($val; null)
        elif $vt == "array" and ($val | length) > 1 then test($val[0]; $val[1])
        elif $vt == "array" and ($val | length) > 0 then test($val[0]; null)
        else error($vt + " not a string or array") end;
    def capture(re; mods): match(re; mods) | reduce (.captures | .[] | select(.name != null) | {(.name): .string}) as $pair ({}; . + $pair);
    def capture($val): ($val | type) as $vt
      | if $vt == "string" then capture($val; null)
        elif $vt == "array" and ($val | length) > 1 then capture($val[0]; $val[1])
        elif $vt == "array" and ($val | length) > 0 then capture($val[0]; null)
        else error($vt + " not a string or array") end;
    def scan($re; $flags): match($re; "g" + $flags) | if (.captures | length) > 0 then [.captures | .[] | .string] else .string end;
    def scan($re): scan($re; null);
    def splits($re; flags): split($re; flags) | .[];
    def splits($re): splits($re; null);
    def tostream: path(def r: (.[]? | r), .; r) as $p | getpath($p) | reduce path(.[]?) as $q ([$p, .]; [$p + $q]);
    def fromstream(f): {x: null, e: false} as $init
      | foreach f as $i ($init;
          if .e then $init else . end
          | if $i | length == 2
            then setpath(["e"]; $i[0] | length == 0) | setpath(["x"] + $i[0]; $i[1])
            else setpath(["e"]; $i[0] | length == 1) end;
          if .e then .x else empty end);
    def truncate_stream(stream): . as $n | null | stream | . as $input | if (.[0] | length) > $n then setpath([0]; $input[0][$n:]) else empty end;
    def INDEX(stream; idx_expr): reduce stream as $row ({}; .[$row | idx_expr | tostring] = $row);
    def INDEX(idx_expr): INDEX(.[]; idx_expr);
    def JOIN($idx; idx_expr): [.[] | [., $idx[idx_expr]]];
    def JOIN($idx; stream; idx_expr): stream | [., $idx[idx_expr]];
    def JOIN($idx; stream; idx_expr; join_expr): stream | [., $idx[idx_expr]] | join_expr;
    def IN(s): any(s == .; .);
    def IN(src; s): any(src == s; .);
    def transpose: [range(0; map(length) | max // 0) as $i | [.[][$i]]];
    def pick(pathexps): . as $in | reduce path(pathexps) as $a (null; setpath($a; $in | getpath($a)));
    def debug(msgs): (msgs | debug | empty), .;
    def get_search_list: ["~/.jq", "$ORIGIN/../lib/jq", "$ORIGIN/../lib"];
    def modulemeta: if type == "string" then error("module not found: \(.)") else error("modulemeta input module name must be a string") end;
  JQ
end
