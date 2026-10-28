module StringCasePatternCommaTest exposing (main)

{-| Two string `case` expressions whose pattern lists are ["a,s:b", "z"] and
["a", "b", "z"] used to share one attribute-table entry in the MLIR bytecode:
`Mlir.Bytecode.AttrType.attrToKey` joined an untyped ArrayAttr's element keys
("s:" ++ text) with "," unquoted, so both `string_patterns` arrays got the key
"aa:s:a,s:b,s:z" and one case got the other's patterns (eco-boot-native
rejected the bytecode: "string_patterns has 2 elements but expected 3"). The
element keys are now length-prefixed.
Also covered by the unit test compiler/tests/Mlir/Bytecode/AttrTypeTest.elm
("untyped array keys do not collide when a string holds ','").
-}

-- CHECK: one_comma: "comma"
-- CHECK: one_a: "other"
-- CHECK: two_a: "a"
-- CHECK: two_b: "b"
-- CHECK: two_comma: "other"

import Html exposing (text)


one : String -> String
one s =
    case s of
        "a,s:b" ->
            "comma"

        "z" ->
            "z"

        _ ->
            "other"


two : String -> String
two s =
    case s of
        "a" ->
            "a"

        "b" ->
            "b"

        "z" ->
            "z"

        _ ->
            "other"


main =
    let
        _ =
            Debug.log "one_comma" (one "a,s:b")

        _ =
            Debug.log "one_a" (one "a")

        _ =
            Debug.log "two_a" (two "a")

        _ =
            Debug.log "two_b" (two "b")

        _ =
            Debug.log "two_comma" (two "a,s:b")
    in
    text "done"
