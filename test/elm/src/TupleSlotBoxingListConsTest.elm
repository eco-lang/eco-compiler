module TupleSlotBoxingListConsTest exposing (main)

-- CHECK: TupleSlotBoxingListCons: "[1,1]"

import Html


buggy members =
    let
        helper ( capturedIdx, member ) acc =
            let
                inner =
                    List.indexedMap
                        (\j ( _, mark, _ ) ->
                            if mark then
                                Just [ capturedIdx ]

                            else
                                Nothing
                        )
                        [ ( "p", member, "s" ), ( "q", member, "t" ) ]
                        |> List.filterMap identity
            in
            inner ++ acc
    in
    List.foldl helper [] (List.indexedMap Tuple.pair members)


flatten lists =
    List.concatMap identity lists


main =
    let
        result =
            buggy [ False, True ] |> flatten

        _ =
            Debug.log "TupleSlotBoxingListCons" (stringOfIntList result)
    in
    Html.text "done"


stringOfIntList xs =
    "[" ++ (xs |> List.map String.fromInt |> String.join ",") ++ "]"
