module TupleSlotBoxingRecordMultiTest exposing (main)

-- CHECK: TupleSlotBoxingRecordMulti: "[0,1,1,1,1,2]"

import Html


buggy members =
    let
        helper ( capturedIdx, member ) acc =
            let
                inner =
                    List.indexedMap
                        (\j ( _, mark, _ ) ->
                            if mark then
                                Just { a = j, b = capturedIdx, c = j + 1 }

                            else
                                Nothing
                        )
                        [ ( "p", member, "s" ), ( "q", member, "t" ) ]
                        |> List.filterMap identity
            in
            inner ++ acc
    in
    List.foldl helper [] (List.indexedMap Tuple.pair members)


flatten recs =
    List.concatMap (\r -> [ r.a, r.b, r.c ]) recs


main =
    let
        result =
            buggy [ False, True ] |> flatten

        _ =
            Debug.log "TupleSlotBoxingRecordMulti" (stringOfIntList result)
    in
    Html.text "done"


stringOfIntList xs =
    "[" ++ (xs |> List.map String.fromInt |> String.join ",") ++ "]"
