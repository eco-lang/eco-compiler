module TupleSlotBoxingMismatchTest exposing (main)

-- CHECK: TupleSlotBoxing: "[0,1,1,1,1,2]"

import Html


buggy members =
    let
        helper ( capturedIdx, member ) acc =
            let
                inner =
                    List.indexedMap
                        (\j ( _, mark, _ ) ->
                            if mark then
                                Just ( j, capturedIdx, j + 1 )

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
    List.concatMap (\( p, c, s ) -> [ p, c, s ]) triples


main =
    let
        result =
            buggy [ True ] |> flatten

        _ =
            Debug.log "TupleSlotBoxing"
                (stringOfIntList result)
    in
    Html.text "done"


stringOfIntList xs =
    "["
        ++ (xs |> List.map String.fromInt |> String.join ",")
        ++ "]"
