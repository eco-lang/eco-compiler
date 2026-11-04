module HttpGetArchiveErrorsTest exposing (main)

{-| HTTP-10 and HTTP-11 (plans/kernel-lib-bug-fixes.md): Eco.Http.getArchive
must fail, not succeed with made-up or wrong content.

  - short (HTTP-10): /package-short.zip is the test package with the first
    entry's central-directory "uncompressed size" raised from 34 to 64 bytes.
    Only 34 bytes can be read, so the entry is corrupt and the download must be
    an `Err`. buildGetArchiveResponse used to ignore the short read and return
    the entry zero-padded to 64 bytes (`Ok 64`). The `Ok` case prints the
    elm.json entry's length so another libzip outcome is visible.
  - notfound (HTTP-11): /status/404 answers 404 with a text body. Expected
    "HTTP 404"; the status used to be ignored and the body failed to open as a
    zip.
  - zip404 (HTTP-11): /status-zip/404 answers 404 with a valid zip body.
    Expected "HTTP 404"; the archive used to be accepted (`Ok`).

The three downloads run in sequence, so the output order is fixed.

-}

-- CHECK: short: "Err"
-- CHECK: notfound: "HTTP 404"
-- CHECK: zip404: "HTTP 404"

import Eco.Http
import Platform
import Task exposing (Task)
import TestServerConfig


type alias Archive =
    { sha : String, archive : List { relativePath : String, data : String } }


type Msg
    = Got { short : String, notfound : String, zip404 : String }


shortLabel : Result String Archive -> String
shortLabel result =
    case result of
        Err _ ->
            "Err"

        Ok { archive } ->
            case List.filter (\e -> String.endsWith "/elm.json" e.relativePath) archive of
                e :: _ ->
                    "Ok " ++ String.fromInt (String.length e.data)

                [] ->
                    "Ok (no elm.json)"


statusLabel : Result String Archive -> String
statusLabel result =
    case result of
        Err e ->
            e

        Ok _ ->
            "Ok"


fetchAll : String -> Task Never { short : String, notfound : String, zip404 : String }
fetchAll baseUrl =
    Eco.Http.getArchive (baseUrl ++ "/package-short.zip")
        |> Task.andThen
            (\short ->
                Eco.Http.getArchive (baseUrl ++ "/status/404")
                    |> Task.andThen
                        (\notfound ->
                            Eco.Http.getArchive (baseUrl ++ "/status-zip/404")
                                |> Task.map
                                    (\zip404 ->
                                        { short = shortLabel short
                                        , notfound = statusLabel notfound
                                        , zip404 = statusLabel zip404
                                        }
                                    )
                        )
            )


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , TestServerConfig.server
        |> Task.andThen (\server -> fetchAll server.baseUrl)
        |> Task.perform Got
    )


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        Got r ->
            let
                _ =
                    Debug.log "short" r.short

                _ =
                    Debug.log "notfound" r.notfound

                _ =
                    Debug.log "zip404" r.zip404
            in
            ( model, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
