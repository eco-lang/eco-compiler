module TupleSlotBoxingCustomMultiTest exposing (main)

-- CHECK: TupleSlotBoxingCustomMulti: "[0,1,1,1,1,2]"

import Html


type Triple
    = Triple Int Int Int


buggy members =
    let
        helper ( capturedIdx, member ) acc =
            let
                inner =
                    List.indexedMap
                        (\j ( _, mark, _ ) ->
                            if mark then
                                Just (Triple j capturedIdx (j + 1))

                            else
                                Nothing
                        )
                        [ ( "p", member, "s" ), ( "q", member, "t" ) ]
                        |> List.filterMap identity
            in
            inner ++ acc
    in
    List.foldl helper [] (List.indexedMap Tuple.pair members)


flatten ts =
    List.concatMap
        (\t ->
            case t of
                Triple a b c ->
                    [ a, b, c ]
        )
        ts


main =
    let
        result =
            buggy [ False, True ] |> flatten

        _ =
            Debug.log "TupleSlotBoxingCustomMulti" (stringOfIntList result)
    in
    Html.text "done"


stringOfIntList xs =
    "[" ++ (xs |> List.map String.fromInt |> String.join ",") ++ "]"
