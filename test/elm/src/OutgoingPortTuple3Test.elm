port module OutgoingPortTuple3Test exposing (main)

{-| Regression test for a monomorphization crash:

      Specialize.specializePath: Expected MRecord for field path but got: MTuple

    An outgoing port whose payload is a 3-element tuple made the typed
    port-encoder emit a record `Field "cs"` projection (the erased JS-runtime
    tuple layout) against a value the MLIR backend represents as a positional
    MTuple. Reachable 3-tuple outgoing ports therefore crashed the compiler.

    See Compiler/LocalOpt/Typed/Port.elm (encodeTuple / letCs_).
-}

-- CHECK: OutgoingPortTuple3Test: "sent"

import Platform


port out3 : ( String, String, List String ) -> Cmd msg


init : () -> ( (), Cmd msg )
init _ =
    let
        _ =
            Debug.log "OutgoingPortTuple3Test" "sent"
    in
    ( (), out3 ( "name.elm", "body", [ "x", "y" ] ) )


main : Program () () msg
main =
    Platform.worker
        { init = init
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
