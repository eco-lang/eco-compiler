module RecordFieldPrimitivesRegressionFTest exposing (main)

{-| `String` functions give the same results on a string read out of a record
field inside a custom type, whether the string is a literal or built at run
time with `++`.

The field holds the three characters `"x"` (quote, x, quote). For each of the
two versions the test logs its length (3), the length after appending `"y"`
(4), and the code of the character at index 1, which is `x` (120).

-}

-- CHECK: f21_lenLitField: 3
-- CHECK: f21_lenRtField: 3
-- CHECK: f22_appendLitField: 4
-- CHECK: f22_appendRtField: 4
-- CHECK: fIdx_litField: 120
-- CHECK: fIdx_rtField: 120

import Html exposing (text)


type S
    = S { src : String }


unsafeIndex : String -> Int -> Char
unsafeIndex str index =
    case String.uncons (String.dropLeft index str) of
        Just ( c, _ ) ->
            c

        Nothing ->
            '?'


main =
    let
        litS =
            S { src = "\"x\"" }

        rtS =
            S { src = "\"" ++ "x" ++ "\"" }

        srcOf (S s) =
            s.src

        -- String.length on the field
        _ =
            Debug.log "f21_lenLitField" (String.length (srcOf litS))

        _ =
            Debug.log "f21_lenRtField" (String.length (srcOf rtS))

        -- String.append on the field, then its length
        _ =
            Debug.log "f22_appendLitField" (String.length (String.append (srcOf litS) "y"))

        _ =
            Debug.log "f22_appendRtField" (String.length (String.append (srcOf rtS) "y"))

        -- The character at index 1 of the field
        _ =
            Debug.log "fIdx_litField" (Char.toCode (unsafeIndex (srcOf litS) 1))

        _ =
            Debug.log "fIdx_rtField" (Char.toCode (unsafeIndex (srcOf rtS) 1))
    in
    text "done"
