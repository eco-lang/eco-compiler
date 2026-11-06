module MaybeMapToUnitTest exposing (main)

{-| `Maybe.map` with a function returning unit produces a `Maybe ()`: mapping `\_ -> ()` over `Just 42` gives `Just ()`.
-}

-- CHECK: result: Just ()

import Html exposing (text)


main =
    let
        result =
            Maybe.map (\_ -> ()) (Just 42)

        _ = Debug.log "result" result
    in
    text "done"
