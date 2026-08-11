module StringOrderIntrinsicTest exposing (main)

{-| kernel-opt-06: `<`, `<=`, `>`, `>=` on two Strings lower to
`eco.string.cmp3` plus one SIGNED test against 0, instead of a boxed
`Elm_Kernel_Utils_{lt,le,gt,ge}` call whose `HPtr` Bool is immediately unboxed.

Behaviour must be IDENTICAL in both flavours, so this fixture pins behaviour.
Two properties it is specifically built to catch:

  - **The sign is UNCLAMPED.** `eco_string_cmp3` returns whatever
    `StringOps::compare` returns, not a normalised -1/0/+1, so the emitted test
    must be against 0. Multi-character differences (`"apple"` vs `"banana"`,
    which differ by 1 at index 0, versus `"a"` vs `"z"`, which differ by 25)
    exercise magnitudes other than 1.
  - **The test must be SIGNED.** An unsigned predicate would read a negative
    sign as a huge positive and invert every "less than" answer, so each
    operator is exercised in both directions plus on equal operands.

Empty strings matter because `""` is an embedded constant: `cmp3` answers
`pa == pb -> 0` for both-empty and `!pa -> -1` / `!pb -> 1` for one-sided,
reproducing `Utils::cmp`'s own null handling.

The non-String orderings at the end must NOT convert — they keep the
polymorphic kernel, which still routes by runtime tag.

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

        -- A 25-unit difference: exercises an unclamped magnitude far from 1.
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

        -- NOT converted: these keep Elm_Kernel_Utils_lt and must still work.
        _ =
            Debug.log "intLt" (1 < 2)

        _ =
            Debug.log "listLt" ([ 1, 2 ] < [ 1, 3 ])

        _ =
            Debug.log "tupleLt" (( 1, "a" ) < ( 1, "b" ))
    in
    text "done"
