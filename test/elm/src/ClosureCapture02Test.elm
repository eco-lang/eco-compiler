module ClosureCapture02Test exposing (main)

{-| Test closure captures Maybe variable used only in case destruct.

Uses explicit lambda return to force nested Function nodes.
The inner lambda captures `m`, which appears only as the root of
destruct paths (MonoRoot) in the case expression.
-}

-- CHECK: just: "hello"
-- CHECK: nothing: "none"

import Html exposing (text)


toLabel : Maybe String -> (Int -> String)
toLabel m =
    \dummy ->
        case m of
            Just s ->
                s

            Nothing ->
                "none"


main =
    let
        _ = Debug.log "just" (toLabel (Just "hello") 0)
        _ = Debug.log "nothing" (toLabel Nothing 0)
    in
    text "done"
