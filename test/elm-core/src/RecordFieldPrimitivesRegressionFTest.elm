module RecordFieldPrimitivesRegressionFTest exposing (main)

{-| Category F — direct primitive calls reading a String through a
record field, mirroring how `Compiler.Parse.Primitives.State.src` is
accessed.
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

        -- F21: String.length on a field
        _ =
            Debug.log "f21_lenLitField" (String.length (srcOf litS))

        _ =
            Debug.log "f21_lenRtField" (String.length (srcOf rtS))

        -- F22: String.append on a field, then length
        _ =
            Debug.log "f22_appendLitField" (String.length (String.append (srcOf litS) "y"))

        _ =
            Debug.log "f22_appendRtField" (String.length (String.append (srcOf rtS) "y"))

        -- Extra: index char from field
        _ =
            Debug.log "fIdx_litField" (Char.toCode (unsafeIndex (srcOf litS) 1))

        _ =
            Debug.log "fIdx_rtField" (Char.toCode (unsafeIndex (srcOf rtS) 1))
    in
    text "done"
