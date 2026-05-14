module TupleSlotBoxingT3Slot0Test exposing (main)

-- CHECK: TupleSlotBoxingT3Slot0: "[1,0,1,1,1,2]"

import Html


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
