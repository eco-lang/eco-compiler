module TupleSlotBoxingT3Slot0Test exposing (main)

{-| Checks that an `Int` bound by a tuple pattern in a local function, and used
inside a lambda nested within it, keeps its value when stored as the 3-tuple
`( capturedIdx, j, j + 1 )`.

`buggy` folds over `[ False, True ]` paired with their indices. For each element
it maps a lambda over two triples whose middle component is that element, and
each triple whose middle component is `True` yields the value above, with
`capturedIdx` the outer index and `j` the inner one. Only index 1 is `True`, so
both values come from it, and the flattened `Int`s print as `[1,0,1,1,1,2]`.

## eco

Exercises the structural-container slot-kind bug catalogued in
plans/tuple-slot-boxing-variants-report.md (reproducer:
plans/reproduce-tuple-slot-boxing-bug.md; upstream analysis:
plans/wrong-unboxed-bitmap-upstream.md). The shape copies the
`buildSiblingData` fold of `List.indexedMap Tuple.pair members` once in
compiler/src/Compiler/GenerateMlir/Expr.elm: `capturedIdx` reaches specialization
as a type variable, so the `Tuple3` layout (`computeTupleLayout` in compiler/src/Compiler/GenerateMlir/Types.elm), slot 0, laid it out as a boxed slot (kind 0)
while the consumer read it as an unboxed `Int`, and the output showed
HPointer bit patterns (around 1610612935) where `capturedIdx` belongs.

Tuples and anonymous records take their layout from the use-site types,
which is why they fire and nominal custom types (laid out from the
declaration, e.g. test/eco-elm/src/TupleSlotBoxingCustomSingleTest.elm) do
not. The slot kinds must match the operand types: CGEN_026 and XPHASE_001
in design_docs/invariants.csv.

-}

-- CHECK: TupleSlotBoxingT3Slot0: "[1,0,1,1,1,2]"

import Html


{-| Collects the values built from the index of each `True` element of
`members`, later elements first.
-}
buggy members =
    let
        helper ( capturedIdx, member ) acc =
            let
                inner =
                    List.indexedMap
                        (\j ( _, mark, _ ) ->
                            if mark then
                                Just ( capturedIdx, j, j + 1 )

                            else
                                Nothing
                        )
                        [ ( "p", member, "s" ), ( "q", member, "t" ) ]
                        |> List.filterMap identity
            in
            inner ++ acc
    in
    List.foldl helper [] (List.indexedMap Tuple.pair members)


flatten triples =
    List.concatMap (\( c, p, s ) -> [ c, p, s ]) triples


main =
    let
        result =
            buggy [ False, True ] |> flatten

        _ =
            Debug.log "TupleSlotBoxingT3Slot0" (stringOfIntList result)
    in
    Html.text "done"


stringOfIntList xs =
    "[" ++ (xs |> List.map String.fromInt |> String.join ",") ++ "]"
