module ListMapTemplateKindsTest exposing (main)

{-| Checks that `List.map` agrees with a reference map for callbacks that change
the element type, for `Bool` elements and results, for empty and one-element
lists, and that a list of NaNs from `List.map` is unequal to one built the same
way.

`refMap` maps with `List.foldl` and `List.reverse` instead of `List.map`, and
`agrees f xs` reports whether `List.map f xs` equals `refMap f xs`. The cases
checked this way:

  - `Int` to `Float`, `Float` to `Int`, `Char` to `String`, `Int` to `Char`,
    and `String` to `Int`;
  - `List Bool` as the input and as the result;
  - an empty list and a one-element list.

NaN is not equal to itself (`nanSelfEq` is `False`), so a list of NaNs produced
by `List.map` is not equal to another list built the same way (`nanListEq` is
`False`), even though the two have the same structure. `nanCount` checks that
the mapped list still has three elements.

## eco

Covers element and result kinds of the `List.map` forward template
(plans/list-map-mlir-template.md; CGEN_078 in design_docs/invariants.csv).
`eco.list.map` carries two independent 2-bit slot kinds, `in_kind` for the
input element and `out_kind` for the callback result, and the head projection
type, the scratch push variant and the finisher's kind are derived from them.
A kind mix-up (the class of defect once found in
runtime/src/allocator/ListOps.cpp `take`) shows up here as a wrong value or a
crash, not as a type error.

`List Bool` is used in both positions because Bool is boxed in heap and closure
storage (FORBID_CLOSURE_001 in design_docs/invariants.csv): kind 0, never a
fourth primitive kind. The empty and singleton cases make the scratch stack push
zero or one entry, and `eco_scratch_finish_fwd`
(runtime/src/allocator/RuntimeExports.cpp) take its `n == 0` early return.

The NaN cases guard object identity (CSE_001 in design_docs/invariants.csv): a
lowering that shared one Float allocation across mapped results would answer
True on a pointer-equality fast path where structural equality must answer
False.

-}

-- CHECK: intToFloat: True
-- CHECK: floatToInt: True
-- CHECK: charToString: True
-- CHECK: intToChar: True
-- CHECK: boxedToInt: True
-- CHECK: boolIn: True
-- CHECK: boolOut: True
-- CHECK: empty: True
-- CHECK: singleton: True
-- CHECK: nanSelfEq: False
-- CHECK: nanListEq: False
-- CHECK: nanCount: 3

import Html exposing (text)


refMap : (a -> b) -> List a -> List b
refMap f xs =
    List.foldl (\x acc -> f x :: acc) [] xs
        |> List.reverse


agrees : (a -> b) -> List a -> Bool
agrees f xs =
    List.map f xs == refMap f xs


nan : Float
nan =
    0 / 0


main : Html.Html msg
main =
    let
        _ =
            Debug.log "intToFloat" (agrees (\x -> toFloat x / 4) [ 1, 2, 3, 7, 11 ])

        _ =
            Debug.log "floatToInt" (agrees (\x -> round (x * 2)) [ 1.25, 2.5, -3.75 ])

        _ =
            Debug.log "charToString" (agrees String.fromChar [ 'a', 'z', 'Q' ])

        _ =
            Debug.log "intToChar"
                (agrees (\x -> Char.fromCode (65 + modBy 26 x)) [ 0, 1, 25, 26 ])

        _ =
            Debug.log "boxedToInt" (agrees String.length [ "", "ab", "abcdef" ])

        _ =
            Debug.log "boolIn"
                (agrees
                    (\b ->
                        if b then
                            1

                        else
                            0
                    )
                    [ True, False, True ]
                )

        _ =
            Debug.log "boolOut" (agrees (\x -> x > 2) [ 1, 2, 3, 4 ])

        _ =
            Debug.log "empty" (agrees (\x -> x + 1) [])

        _ =
            Debug.log "singleton" (agrees (\x -> x + 1) [ 41 ])

        -- A NaN never equals itself, so a list of NaNs never equals another
        -- list, even one built the same way.
        nans =
            List.map (\x -> nan * toFloat x) [ 1, 2, 3 ]

        _ =
            Debug.log "nanSelfEq" (nan == nan)

        _ =
            Debug.log "nanListEq" (nans == refMap (\x -> nan * toFloat x) [ 1, 2, 3 ])

        _ =
            Debug.log "nanCount" (List.length nans)
    in
    text "done"
