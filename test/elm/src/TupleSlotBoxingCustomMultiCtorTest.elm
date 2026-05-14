module TupleSlotBoxingCustomMultiCtorTest exposing (main)

-- CHECK: TupleSlotBoxingCustomMultiCtor: "[1,1]"

import Html


type T
    = WithIdx Int
    | Empty


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
