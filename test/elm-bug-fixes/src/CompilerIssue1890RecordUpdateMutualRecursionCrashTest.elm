module CompilerIssue1890RecordUpdateMutualRecursionCrashTest exposing (..)

{-| Mutually recursive unannotated functions with a record update crash the compiler.

<https://github.com/elm/compiler/issues/1890>

Elm 0.19.1 crashes ("index out of bounds") on this valid program; it should compile.
The test expects the program to run and log the unchanged record `{ x = (), y = () }`.

Fixed in Elm 0.19.3.

-}

-- CHECK: result: { x = (), y = () }

import Html exposing (text)


type alias Model =
    { x : ()
    , y : ()
    }


firstMethod model =
    let
        _ =
            model.y
    in
    addResourceToModel model


addResourceToModel model =
    case Nothing of
        Nothing ->
            model

        Just _ ->
            let
                _ =
                    firstMethod model
            in
            { model | x = () }


main =
    let
        _ =
            Debug.log "result" (firstMethod { x = (), y = () })
    in
    text "done"
