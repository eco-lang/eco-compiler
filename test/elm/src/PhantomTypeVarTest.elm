module PhantomTypeVarTest exposing (main)

{-| Regression test for infinite monomorphization loop caused by phantom
type variables in constructors.

    type RStep e a = ROk a | RErr (List e)

`RErr` has phantom `a`. When `mapStep` and `applyR` reconstruct `RErr`
at a new result type, the phantom type var gets a fresh MVarId each time,
causing unbounded specialization growth.

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
