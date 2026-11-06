module PhantomTypeVarTest exposing (main)

{-| Tests a custom type with a type parameter that one of its constructors
does not use, rebuilt at a new type by generic functions.

In `type RStep e a = ROk a | RErr (List e)`, the `RErr` constructor has no
`a` field, so `mapStep` and `applyR` can rebuild an `RErr` at any result
type. `main` applies an identity function wrapped in `ROk` three times to
`ROk 42` through `applyR`, and logs the value inside.

-}

-- CHECK: result: 42

import Html exposing (text)


type RStep e a
    = ROk a
    | RErr (List e)


mapStep : (a -> b) -> RStep e a -> RStep e b
mapStep f step =
    case step of
        ROk val ->
            ROk (f val)

        RErr errs ->
            RErr errs


applyR : RStep e (a -> b) -> RStep e a -> RStep e b
applyR funcStep argStep =
    case funcStep of
        RErr errs ->
            RErr errs

        ROk func ->
            mapStep func argStep


main =
    let
        base =
            ROk 42

        idFunc =
            ROk (\x -> x)

        step1 =
            applyR idFunc base

        step2 =
            applyR idFunc step1

        step3 =
            applyR idFunc step2

        result =
            case step3 of
                ROk v ->
                    v

                RErr _ ->
                    -1

        _ =
            Debug.log "result" result
    in
    text "done"
