# schema-check.jq — validate a JSON document against the subset of JSON Schema draft-07 that
# sdlc.config.schema.json uses: type, enum, const, required, properties, additionalProperties,
# items, minimum, maximum, minLength, pattern, and local "$ref": "#/definitions/<name>".
#
#   jq -n -r --slurpfile schema <schema.json> --slurpfile doc <config.json> -f schema-check.jq
#
# Prints one error per line; prints nothing when the document is valid.

def jtype: if type == "number" then (if . == floor then "integer" else "number" end) else type end;

def type_ok($t):
  ($t | if type == "array" then . else [.] end) as $ts
  | jtype as $a
  | any($ts[]; . == $a or (. == "number" and $a == "integer"));

def resolve($root; $s):
  if ($s | type) == "object" and ($s["$ref"] // "") != "" then
    ($s["$ref"] | ltrimstr("#/") | split("/")) as $p | $root | getpath($p)
  else $s end;

def validate($root; $path; $schema; $v):
  resolve($root; $schema) as $s
  | [
      (if $s.type != null and (($v | type_ok($s.type)) | not) then "\($path): expected \($s.type | tostring), got \($v | jtype)" else empty end),
      (if $s.enum != null and (($s.enum | index([$v])) == null) then "\($path): must be one of \($s.enum | tostring), got \($v | tostring)" else empty end),
      (if ($s | has("const")) and $v != $s.const then "\($path): must be \($s.const | tostring)" else empty end),
      (if ($v | type) == "object" then
          ( ($s.required // [])[] as $k | select(($v | has($k)) | not) | "\($path).\($k): required" ),
          ( if $s.additionalProperties == false then
              ($v | keys[]) as $k | select($k != "$schema") | select((($s.properties // {}) | has($k)) | not) | "\($path).\($k): unknown key"
            else empty end ),
          ( ($s.properties // {}) | keys[] as $k | select($v | has($k)) | validate($root; "\($path).\($k)"; $s.properties[$k]; $v[$k])[] )
        else empty end),
      (if ($v | type) == "array" and $s.items != null then
          ( $v | to_entries[] | validate($root; "\($path)[\(.key)]"; $s.items; .value)[] )
        else empty end),
      (if ($v | type) == "number" then
          (if $s.minimum != null and $v < $s.minimum then "\($path): must be >= \($s.minimum)" else empty end),
          (if $s.maximum != null and $v > $s.maximum then "\($path): must be <= \($s.maximum)" else empty end)
        else empty end),
      (if ($v | type) == "string" then
          (if $s.minLength != null and ($v | length) < $s.minLength then "\($path): must be at least \($s.minLength) character(s)" else empty end),
          (if $s.pattern != null and (($v | test($s.pattern)) | not) then "\($path): must match \($s.pattern)" else empty end)
        else empty end)
    ];

validate($schema[0]; "$"; $schema[0]; $doc[0])[]
