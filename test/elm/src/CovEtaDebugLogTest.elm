module CovEtaDebugLogTest exposing (main)

{-| Checks a function defined with fewer parameters than its annotated type:
`mk : Int -> Fn`, where `Fn` is an alias of `Int -> Int`, takes one parameter
and returns a `let`-bound function whose body calls `Debug.log`.

`mk 3 4` applies the returned function to 4, which logs 7 under the label
`eta body`.

-}

-- CHECK: eta body: 7

import Html exposing (text)


type alias Fn =
    Int -> Int


mk : Int -> Fn
mk n =
    let
        h z =
            Debug.log "eta body" (n + z)
    in
    h


main =
    let
        _ =
            mk 3 4
    in
    text "done"
