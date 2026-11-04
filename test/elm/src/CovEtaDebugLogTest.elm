module CovEtaDebugLogTest exposing (main)

{-| A definition annotated `Int -> Fn`, with `Fn` an alias of `Int -> Int`,
written with one parameter and a `let`-bound helper whose body calls
`Debug.log`. η-expansion gives `mk` its second parameter and mints the whole
rewritten body, `Debug.log` reference included. `mk 3 4` logs 7.
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
