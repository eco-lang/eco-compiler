module TupleSlotBoxingCustomMultiCtorTest exposing (main)

{-| Checks that an `Int` bound by a tuple pattern in a local function, and used
inside a lambda nested within it, keeps its value when stored as `WithIdx` of
the outer index, a constructor of a two-constructor custom type (unmarked
entries would give `Empty`).

`buggy` folds over `[ False, True ]` paired with their indices. For each element
it maps a lambda over two triples whose middle component is that element, and
each triple whose middle component is `True` yields the value above and every
other triple yields `Empty`; `flatten` drops the `Empty`s. Only index 1 is
`True`, so both values come from it, and the flattened `Int`s print as `[1,1]`.

## eco

This is one variant of the tuple-slot boxing matrix catalogued in plans/tuple-slot-boxing-variants-report.md (reproducer: plans/tuple-slot-boxing-reproducer.md; upstream analysis: plans/wrong-unboxed-bitmap-upstream.md). The skeleton binds `capturedIdx` from a tuple pattern fed by a polymorphic `List.indexedMap Tuple.pair`, so its use-site type could stay an unresolved `CEcoValue` variable while the value itself is a raw `i64`.

Constructor layout comes from the type declaration, not the use site, so this variant passed even while the bug was live; it is a baseline that must stay green.

-}

-- CHECK: TupleSlotBoxingCustomMultiCtor: "[1,1]"

import Html


type T
    = WithIdx Int
    | Empty


{-| Builds a `WithIdx` of the element's index for each triple whose middle
component is `True`, and `Empty` for the rest, later elements first.
-}
buggy members =
    let
        helper ( capturedIdx, member ) acc =
            let
                inner =
                    List.indexedMap
                        (\j ( _, mark, _ ) ->
                            if mark then
                                WithIdx capturedIdx

                            else
                                Empty
                        )
                        [ ( "p", member, "s" ), ( "q", member, "t" ) ]
            in
            inner ++ acc
    in
    List.foldl helper [] (List.indexedMap Tuple.pair members)


flatten ts =
    List.filterMap
        (\t ->
            case t of
                WithIdx n ->
                    Just n

                Empty ->
                    Nothing
        )
        ts


main =
    let
        result =
            buggy [ False, True ] |> flatten

        _ =
            Debug.log "TupleSlotBoxingCustomMultiCtor" (stringOfIntList result)
    in
    Html.text "done"


stringOfIntList xs =
    "[" ++ (xs |> List.map String.fromInt |> String.join ",") ++ "]"
