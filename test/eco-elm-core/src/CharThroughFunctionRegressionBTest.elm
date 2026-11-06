module CharThroughFunctionRegressionBTest exposing (main)

{-| A Char taken from a string with `String.uncons` keeps its value when it is returned from a
function, stored in a record field or returned in a tuple.

Each case takes the first character of a string starting with a double quote and logs its
`Char.toCode`, which should be 34: from a two-argument function, from a record wrapped in a
custom type, from a tuple, from a let-bound `case`, and from a local function.

## eco

One of a set of regression probes (A to G, see test/eco-elm-core/src/HeapStringFieldRegressionATest.elm) for a failure of the self-compiled compiler in the bootstrap. In one configuration `Char.toCode c` returned 1049952290 (0x3E990022) instead of 34: the low 16 bits were right and the upper bits were garbage, as if an unboxed Char were read from a wider slot. The bug was fragile, so the test sweeps the common shapes a Char flows through; the two-argument function returning a Char was the original failing shape.

-}

-- CHECK: b5_2argFn: 34
-- CHECK: b6_recordField: 34
-- CHECK: b7_tupleReturn: 34
-- CHECK: bExtra_letBound: 34
-- CHECK: bExtra_chained: 34

import Html exposing (text)


type Box
    = Box { c : Char }


{-| Returns the character at index `i` of `s`, or `'?'` past the end.
-}
get2 : Int -> String -> Char
get2 i s =
    case String.uncons (String.dropLeft i s) of
        Just ( c, _ ) ->
            c

        Nothing ->
            '?'


{-| Wraps the first character of `s` in a `Box`, or `'?'` for an empty string.
-}
mkBox : String -> Box
mkBox s =
    case String.uncons s of
        Just ( c, _ ) ->
            Box { c = c }

        Nothing ->
            Box { c = '?' }


{-| Returns the character held in a `Box`.
-}
unBox : Box -> Char
unBox (Box b) =
    b.c


{-| Returns the first character of `s` and the rest, or `( '?', "" )` for an empty string.
-}
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

        -- A local function, applied to the result of String.dropLeft 0
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
