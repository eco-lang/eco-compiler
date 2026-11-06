module StringOrderIntrinsicTest exposing (main)

{-| The comparison operators `<`, `<=`, `>` and `>=` order two `String` values correctly,
and still work on `Int`, `List` and tuple operands in the same program.

The string comparisons check:

  - `<` and `>` on `"apple"` and `"banana"` in both directions, and `<`, `<=` and `>=` on
    two equal strings;
  - `"a" < "z"`, whose first characters are far apart in character code;
  - the empty string against a non-empty one in both directions, and against itself;
  - `"ab" < "abc"`, where a string that is a prefix of another orders first.

The last three lines check `1 < 2`, `[ 1, 2 ] < [ 1, 3 ]` and `( 1, "a" ) < ( 1, "b" )`.

## eco

Exercises the string ordering intrinsic
(plans/string-cmp-order-intrinsic-and-postmono-compare-rewrite.md): `<`, `<=`,
`>`, `>=` on two `String`s lower to `eco.string.cmp3` plus one signed test
against 0, instead of a boxed `Elm_Kernel_Utils_lt`-family call whose `Bool`
result is immediately unboxed. Behaviour must match the kernel exactly.

The sign is not clamped: `eco_string_cmp3` returns whatever the comparison in
runtime/src/allocator/StringOps.cpp returns, so the test must be against 0, and
the far-apart pairs exercise magnitudes other than 1. The test must be signed,
or every "less than" answer inverts, hence both directions plus equal operands.
`""` is an embedded constant, so the empty cases check the null handling. The
non-`String` orderings at the end keep the polymorphic kernel.

-}

-- CHECK: ltTrue: True
-- CHECK: ltFalse: False
-- CHECK: ltEqual: False
-- CHECK: leEqual: True
-- CHECK: gtTrue: True
-- CHECK: gtFalse: False
-- CHECK: geEqual: True
-- CHECK: farApart: True
-- CHECK: emptyLtNonEmpty: True
-- CHECK: nonEmptyGtEmpty: True
-- CHECK: emptyLeEmpty: True
-- CHECK: emptyLtEmpty: False
-- CHECK: prefixLt: True
-- CHECK: intLt: True
-- CHECK: listLt: True
-- CHECK: tupleLt: True

import Html exposing (text)


main : Html.Html msg
main =
    let
        _ =
            Debug.log "ltTrue" ("apple" < "banana")

        _ =
            Debug.log "ltFalse" ("banana" < "apple")

        _ =
            Debug.log "ltEqual" ("same" < "same")

        _ =
            Debug.log "leEqual" ("same" <= "same")

        _ =
            Debug.log "gtTrue" ("banana" > "apple")

        _ =
            Debug.log "gtFalse" ("apple" > "banana")

        _ =
            Debug.log "geEqual" ("same" >= "same")

        _ =
            Debug.log "farApart" ("a" < "z")

        _ =
            Debug.log "emptyLtNonEmpty" ("" < "a")

        _ =
            Debug.log "nonEmptyGtEmpty" ("a" > "")

        _ =
            Debug.log "emptyLeEmpty" ("" <= "")

        _ =
            Debug.log "emptyLtEmpty" ("" < "")

        -- Prefix ordering: equal on the shared prefix, decided by length.
        _ =
            Debug.log "prefixLt" ("ab" < "abc")

        -- Comparisons on operands that are not strings.
        _ =
            Debug.log "intLt" (1 < 2)

        _ =
            Debug.log "listLt" ([ 1, 2 ] < [ 1, 3 ])

        _ =
            Debug.log "tupleLt" (( 1, "a" ) < ( 1, "b" ))
    in
    text "done"
