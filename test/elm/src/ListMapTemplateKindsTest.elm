module ListMapTemplateKindsTest exposing (main)

{-| Element/result KIND coverage for the `List.map` forward template
(plans/list-map-mlir-template.md; CGEN_078(d)).

`eco.list.map` carries two independent 2-bit slot kinds — `in_kind` for the
input element and `out_kind` for the callback result — and the head projection
type, the scratch push variant and the finisher's kind are all derived from
them. A kind collapse (the `ListOps::take` defect class) shows up here as a
wrong value or a crash, not as a type error.

Covered: every kind-CHANGING direction (Int→Float, Float→Int, Char→String,
Int→Char, boxed→Int), `List Bool` in both positions (Bool is BOXED in heap and
closure storage per FORBID_CLOSURE_001 — kind 0, never a fourth primitive
kind), and the empty/singleton edges where the scratch stack pushes zero or one
entry and `eco_scratch_finish_fwd` takes its `n == 0` early return.

**NaN is deliberate.** Object identity is observable in Elm through NaN
(`CSE_001`): a lowering that shared one Float allocation across two mapped
results would answer `True` to a pointer-equality fast path where structural
equality must answer `False`. Mapping over NaN and comparing structurally is
the canary for that.

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

        -- Bool as the ELEMENT type: boxed slot, kind 0.
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

        -- Bool as the RESULT type: also boxed, also kind 0.
        _ =
            Debug.log "boolOut" (agrees (\x -> x > 2) [ 1, 2, 3, 4 ])

        _ =
            Debug.log "empty" (agrees (\x -> x + 1) [])

        _ =
            Debug.log "singleton" (agrees (\x -> x + 1) [ 41 ])

        -- NaN identity (CSE_001). A NaN never equals itself, so a mapped list
        -- of NaNs never equals ANY list — including a structurally identical
        -- one. Both must be False; a shared-allocation pointer-eq shortcut
        -- would wrongly answer True on the second.
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
