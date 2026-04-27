module CharThroughFunctionRegressionBTest exposing (main)

{-| Category B — Char value flowing through function returns, record
fields, and tuples.

In one probe configuration we observed `Char.toCode c` returning
`1049952290 = 0x3E990022` instead of `34`, where the lower 16 bits
were correct but upper bits had garbage. This is fragile — the test
sweeps several common shapes to try to pin it down.
-}

-- CHECK: b5_2argFn: 34
-- CHECK: b6_recordField: 34
-- CHECK: b7_tupleReturn: 34
-- CHECK: bExtra_letBound: 34
-- CHECK: bExtra_chained: 34

import Html exposing (text)


type Box
    = Box { c : Char }


-- B5: 2-arg function returning Char (the original buggy shape)
get2 : Int -> String -> Char
get2 i s =
    case String.uncons (String.dropLeft i s) of
        Just ( c, _ ) ->
            c

        Nothing ->
            '?'


-- B6: Char carried through a record field
mkBox : String -> Box
mkBox s =
    case String.uncons s of
        Just ( c, _ ) ->
            Box { c = c }

        Nothing ->
            Box { c = '?' }


unBox : Box -> Char
unBox (Box b) =
    b.c


-- B7: Char carried through a tuple return
firstChar : String -> ( Char, String )
firstChar s =
    case String.uncons s of
        Just t ->
            t

        Nothing ->
            ( '?', "" )


main =
    let
        rt =
            "\"" ++ "x" ++ "\""

        -- B5
        _ =
            Debug.log "b5_2argFn" (Char.toCode (get2 0 rt))

        -- B6
        _ =
            Debug.log "b6_recordField" (Char.toCode (unBox (mkBox rt)))

        -- B7
        ( c7, _ ) =
            firstChar rt

        _ =
            Debug.log "b7_tupleReturn" (Char.toCode c7)

        -- Extra: simple let-bound from String.uncons
        cLet =
            case String.uncons rt of
                Just ( c, _ ) ->
                    c

                Nothing ->
                    '?'

        _ =
            Debug.log "bExtra_letBound" (Char.toCode cLet)

        -- Extra: chained get1 calls
        get1 s =
            case String.uncons s of
                Just ( c, _ ) ->
                    c

                Nothing ->
                    '?'

        _ =
            Debug.log "bExtra_chained" (Char.toCode (get1 (String.dropLeft 0 rt)))
    in
    text "done"
