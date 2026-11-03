module HttpBytesBodyTest exposing (main)

{-| Request bodies made of `Bytes`: `Http.bytesBody`, and a `Http.bytesPart` in a
`multipartBody` next to a `stringPart`. The test server's /anything echoes the
request's content type and body (raw: a NUL byte arrives as one). A browser sends the bytes as they are, with the
given MIME type; a bytes part is a Blob, so its part carries `filename="blob"`
and its own `Content-Type`.
-}

-- CHECK: bytesBody content type: True
-- CHECK: bytesBody body: True
-- CHECK: multipart string part: True
-- CHECK: multipart bytes part: True
-- CHECK: multipart bytes part type: True

import Bytes.Encode as E
import Http
import Platform
import Task
import TestServerConfig


type Msg
    = GotServer TestServerConfig.Server
    | GotBytesBody (Result Http.Error String)
    | GotMultipart (Result Http.Error String)


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform GotServer TestServerConfig.server )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


log : String -> Bool -> ()
log label ok =
    always () (Debug.log label ok)


update : Msg -> () -> ( (), Cmd Msg )
update msg model =
    case msg of
        GotServer server ->
            ( model
            , Cmd.batch
                [ Http.post
                    { url = server.baseUrl ++ "/anything"
                    , body = Http.bytesBody "application/x-eco-test" (E.encode (E.sequence [ E.string "hello bytes", E.unsignedInt8 0, E.unsignedInt8 66 ]))
                    , expect = Http.expectString GotBytesBody
                    }
                , Http.post
                    { url = server.baseUrl ++ "/anything"
                    , body =
                        Http.multipartBody
                            [ Http.stringPart "title" "Tom"
                            , Http.bytesPart "photo" "image/x-eco" (E.encode (E.string "PIXELS"))
                            ]
                    , expect = Http.expectString GotMultipart
                    }
                ]
            )

        GotBytesBody result ->
            let
                body =
                    Result.withDefault "" result

                _ =
                    log "bytesBody content type" (String.contains "\"contentType\":\"application/x-eco-test\"" body)

                _ =
                    log "bytesBody body" (String.contains "\"body\":\"hello bytes\u{0000}B\"" body)
            in
            ( model, Cmd.none )

        GotMultipart result ->
            let
                body =
                    Result.withDefault "" result

                _ =
                    log "multipart string part" (String.contains "name=\\\"title\\\"" body && String.contains "Tom" body)

                _ =
                    log "multipart bytes part" (String.contains "name=\\\"photo\\\"" body && String.contains "PIXELS" body)

                _ =
                    log "multipart bytes part type" (String.contains "Content-Type: image/x-eco" body)
            in
            ( model, Cmd.none )
