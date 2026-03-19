module DeepNestStressTest exposing (main)

{-| Test deeply nested data structures: lists, tuples, records, and lets. -}

-- CHECK: nested_list: 1
-- CHECK: nested_tuple: 1
-- CHECK: nested_record: 1
-- CHECK: nested_let: 10

import Html exposing (text)


main =
    let
        nl = [ [ [ [ 1 ] ] ] ]
        nlVal =
            case nl of
                [ [ [ [ x ] ] ] ] ->
                    x

                _ ->
                    0
        _ = Debug.log "nested_list" nlVal
        nt = ( ( ( ( 1, 2 ), 3 ), 4 ), 5 )
        ( ( ( ( first, _ ), _ ), _ ), _ ) = nt
        _ = Debug.log "nested_tuple" first
        nr = { n = { n = { n = { v = 1 } } } }
        _ = Debug.log "nested_record" nr.n.n.n.v
        a =
            let
                b =
                    let
                        c =
                            let
                                d = 10
                            in
                            d
                    in
                    c
            in
            b
        _ = Debug.log "nested_let" a
    in
    text "done"
