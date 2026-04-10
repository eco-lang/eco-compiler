module MaybeMapToUnitTest exposing (main)

{-| Test Maybe.map with a -> () mapping function.
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
