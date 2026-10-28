module StringCasePatternCommaTest exposing (main)

{-| Two string `case` expressions whose pattern lists are ["a,s:b", "z"] and
["a", "b", "z"] share one attribute-table entry in the MLIR bytecode:
`Mlir.Bytecode.AttrType.attrToKey` joins an untyped ArrayAttr's element keys
("s:" ++ text) with "," unquoted, so both `string_patterns` arrays get the key
"aa:s:a,s:b,s:z" and one case gets the other's patterns (today eco-boot-native
rejects the bytecode: "string_patterns has 2 elements but expected 3"; the
--text-mlir output of the same compile runs correctly).
Also covered by the unit test compiler/tests/Mlir/Bytecode/AttrTypeTest.elm
("untyped array keys do not collide when a string holds ','").

EXPECTED TO FAIL until fixed.
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
