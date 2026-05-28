module HttpGetArchiveTest exposing (main)

{-| Exercises Eco.Http.getArchive end-to-end: download a canned ZIP from the
in-process test server, extract it, and verify the entries. Checks that the
kernel returns tuples in the correct shape — outer ( sha, archive ) and each
entry ( relativePath, data ) — by reading the decoded record fields.
-}

-- CHECK: HttpGetArchiveTest: True

import Eco.Http
import Platform
import Task
import TestServerConfig


type Msg
    = Got (Result String { sha : String, archive : List { relativePath : String, data : String } })


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , Task.perform Got (Eco.Http.getArchive (TestServerConfig.baseUrl ++ "/package.zip"))
    )


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        Got (Ok { sha, archive }) ->
            let
                hasElmJson =
                    List.any
                        (\e -> e.relativePath == "elm.json" && String.contains "dummy" e.data)
                        archive

                hasMain =
                    List.any (\e -> e.relativePath == "src/Main.elm") archive

                ok =
                    hasElmJson && hasMain && String.length sha > 0

                _ =
                    Debug.log "HttpGetArchiveTest" ok
            in
            ( model, Cmd.none )

        Got (Err _) ->
            let
                _ =
                    Debug.log "HttpGetArchiveTest" False
            in
            ( model, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
