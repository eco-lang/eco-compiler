module TupleSlotBoxingT2Slot0Test exposing (main)

-- CHECK: TupleSlotBoxingT2Slot0: "[1,0,1,1]"

import Html


buggy members =
    let
        helper ( capturedIdx, member ) acc =
            let
                inner =
                    List.indexedMap
                        (\j ( _, mark, _ ) ->
                            if mark then
                                Just ( capturedIdx, j )

                            else
                                Nothing
                        )
                        [ ( "p", member, "s" ), ( "q", member, "t" ) ]
                        |> List.filterMap identity
            in
            inner ++ acc
    in
    List.foldl helper [] (List.indexedMap Tuple.pair members)


flatten pairs =
    List.concatMap (\( c, p ) -> [ c, p ]) pairs


main =
    let
        result =
            buggy [ False, True ] |> flatten

        _ =
            Debug.log "TupleSlotBoxingT2Slot0" (stringOfIntList result)
    in
    Html.text "done"


stringOfIntList xs =
    "[" ++ (xs |> List.map String.fromInt |> String.join ",") ++ "]"
