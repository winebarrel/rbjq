# frozen_string_literal: true

module Rbjq
  # Builtins defined in the jq language itself (adapted from jq's builtin.jq).
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
    def finites: select(isinfinite or isnan | not);
    def normals: select(isnormal);
    def recurse(f; cond): def r: ., (f | select(cond) | r); r;
    def map(f): [.[] | f];
    def map_values(f): .[] |= f;
    def with_entries(f): to_entries | map(f) | from_entries;
    def add(f): reduce f as $x (null; . + $x);
    def del(f): delpaths([path(f)]);
    def paths: path(..) | select(length > 0);
    def paths(node_filter): . as $dot | paths | select(. as $p | $dot | getpath($p) | node_filter);
    def leaf_paths: paths(scalars);
    def any: reduce .[] as $x (false; . or $x);
    def all: reduce .[] as $x (true; . and $x);
    def any(f): reduce (.[] | f) as $x (false; . or $x);
    def all(f): reduce (.[] | f) as $x (true; . and $x);
    def any(generator; condition): isempty(first(generator | condition or empty)) | not;
    def all(generator; condition): isempty(first(generator | condition and empty));
    def in(xs): . as $x | xs | has($x);
    def inside(xs): . as $x | xs | contains($x);
    def last(f): reduce f as $x (null; $x);
    def nth($n): .[$n];
    def nth($n; f): if $n < 0 then error("Out of bounds negative array index") else last(limit($n + 1; f)) end;
    def first: .[0];
    def last: .[-1];
    def reverse: if type == "string" then explode | reverse | implode elif . == null then [] else [.[length - 1 - range(0; length)]] end;
    def index($i): indices($i) | .[0];
    def rindex($i): indices($i) | .[-1:][0];
    def sort_by(f): _sort_by_impl(map([f]));
    def group_by(f): _group_by_impl(map([f]));
    def unique_by(f): _unique_by_impl(map([f]));
    def min_by(f): _min_by_impl(map([f]));
    def max_by(f): _max_by_impl(map([f]));
    def combinations: if length == 0 then [] else .[0][] as $x | (.[1:] | combinations) as $w | [$x] + $w end;
    def combinations(n): . as $dot | [range(n)] | map($dot) | combinations;
    def walk(f): def w: if type == "object" then map_values(w) elif type == "array" then map(w) else . end | f; w;
    def env: $ENV;
    def halt_error: halt_error(5);
    def todateiso8601: strftime("%Y-%m-%dT%H:%M:%SZ");
    def fromdateiso8601: strptime("%Y-%m-%dT%H:%M:%SZ") | mktime;
    def todate: todateiso8601;
    def fromdate: fromdateiso8601;
    def date: todate;
    def dateadd(u; n): . + n;
    def datesub(u; n): . - n;
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
    def ascii: [.] | implode;
    def tostream: path(def r: (.[]? | r), .; r) as $p | getpath($p) | reduce path(.[]?) as $q ([$p, .]; [$p + $q]);
    def fromstream(f): {x: null, e: false} as $init
      | foreach f as $i ($init;
          if .e then $init else . end
          | if $i | length == 2
            then setpath(["e"]; $i[0] | length == 0) | setpath(["x"] + $i[0]; $i[1])
            else setpath(["e"]; $i[0] | length == 1) end;
          if .e then .x else empty end);
    def truncate_stream(stream): . as $n | null | stream | . as $input | if (.[0] | length) > $n then setpath([0]; .[0][$n:]) else empty end;
    def INDEX(stream; idx_expr): reduce stream as $row ({}; .[$row | idx_expr | tostring] |= $row);
    def INDEX(idx_expr): INDEX(.[]; idx_expr);
    def IN(s): any(s == .; .);
    def IN(src; s): any(src == s; .);
    def transpose: if . == [] then [] else . as $in | (map(length) | max) as $max | [range(0; $max) as $j | [range(0; $in | length) as $i | $in[$i][$j]]] end;
    def pick(pathexps): . as $top | reduce path(pathexps) as $p (null; setpath($p; $top | getpath($p)));
    def debug(msg): (msg | debug | empty), .;
    def get_search_list: [];
  JQ
end
