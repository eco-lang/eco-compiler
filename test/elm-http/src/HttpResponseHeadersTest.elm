module HttpResponseHeadersTest exposing (main)

{-| Reads a response header out of `Metadata.headers` (a Dict String String)
via expectStringResponse, exercising the kernel's Dict construction.
-}

-- CHECK: respHeader: "eco"

import Dict
import Http
import Platform
import TestServerConfig


type Msg
    = Got (Result String String)


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), get )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


get : Cmd Msg
get =
    Http.request
        { method = "GET"
        , headers = []
        , url = TestServerConfig.baseUrl ++ "/echo-headers"
        , body = Http.emptyBody
        , expect = Http.expectStringResponse Got toResult
        , timeout = Nothing
        , tracker = Nothing
        }


toResult : Http.Response String -> Result String String
toResult response =
    case response of
        Http.GoodStatus_ metadata _ ->
            case Dict.get "x-test-server" metadata.headers of
                Just v ->
                    Ok v

                Nothing ->
                    Err "missing"

        _ ->
            Err "bad"


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        Got (Ok v) ->
            let
                _ =
                    Debug.log "respHeader" v
            in
            ( model, Cmd.none )

        Got (Err e) ->
            let
                _ =
                    Debug.log "respHeader" e
            in
            ( model, Cmd.none )
