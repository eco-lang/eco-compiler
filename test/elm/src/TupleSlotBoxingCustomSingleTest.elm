module TupleSlotBoxingCustomSingleTest exposing (main)

-- CHECK: TupleSlotBoxingCustomSingle: "[1,1]"

import Html


type Wrap
    = Wrap Int


buggy members =
    let
        helper ( capturedIdx, member ) acc =
            let
                inner =
                    List.indexedMap
                        (\j ( _, mark, _ ) ->
                            if mark then
                                Just (Wrap capturedIdx)

                            else
                                Nothing
                        )
                        [ ( "p", member, "s" ), ( "q", member, "t" ) ]
                        |> List.filterMap identity
            in
            inner ++ acc
    in
    List.foldl helper [] (List.indexedMap Tuple.pair members)


flatten ws =
    List.map
        (\w ->
            case w of
                Wrap n ->
                    n
        )
        ws


main =
    let
        result =
            buggy [ False, True ] |> flatten

        _ =
            Debug.log "TupleSlotBoxingCustomSingle" (stringOfIntList result)
    in
    Html.text "done"


stringOfIntList xs =
    "[" ++ (xs |> List.map String.fromInt |> String.join ",") ++ "]"
