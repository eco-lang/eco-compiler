module HttpStreamUploadTest exposing (main)

{-| `streamBody` uploads a `Stream.fromList` of three chunks to `/anything`
(plans/eco-system-library.md Phase 8 step 8.3, E.6): the echoed body is their
concatenation, it was sent with chunked transfer encoding (no Content-Length),
and the Content-Type is the body's MIME type. The readable is consumed: a
later read sees it closed.
-}

-- CHECK: method: PUT
-- CHECK: body: hello stream world
-- CHECK: content-type: text/plain
-- CHECK: transfer-encoding: chunked
-- CHECK: content-length sent: False
-- CHECK: source after upload: Closed
-- EXIT: 0

import Dict
import Http
import Http.Stream
import HttpStreamTestHelp as H
import Json.Decode as D
import Stream
import Task


type alias Echo =
    { method : String, body : String, contentType : String, headers : Dict.Dict String String }


echoDecoder : D.Decoder Echo
echoDecoder =
    D.map4 Echo
        (D.field "method" D.string)
        (D.field "body" D.string)
        (D.field "contentType" D.string)
        (D.field "headers" (D.dict D.string))


main =
    H.program
        (\_ ->
            H.streamErr (Stream.fromList [ H.bytesOf "hello ", H.bytesOf "stream ", H.bytesOf "world" ])
                |> Task.andThen
                    (\source ->
                        Http.Stream.task
                            { method = "PUT"
                            , headers = []
                            , url = H.url "/anything"
                            , body = Http.Stream.streamBody "text/plain" source
                            , resolver = Http.Stream.streamResolver (\r -> Ok r)
                            , timeout = Just 10000
                            }
                            |> Task.andThen
                                (\response ->
                                    case response of
                                        Http.GoodStatus_ _ body ->
                                            H.streamErr (H.readAllString body)

                                        _ ->
                                            Task.fail "unexpected response"
                                )
                            |> Task.andThen
                                (\json ->
                                    case D.decodeString echoDecoder json of
                                        Ok echo ->
                                            Stream.read source
                                                |> Task.map (\_ -> "value")
                                                |> Task.onError (\e -> Task.succeed (Stream.errorToString e))
                                                |> Task.map
                                                    (\after ->
                                                        [ "method: " ++ echo.method
                                                        , "body: " ++ echo.body
                                                        , "content-type: " ++ echo.contentType
                                                        , "transfer-encoding: " ++ Maybe.withDefault "-" (Dict.get "transfer-encoding" echo.headers)
                                                        , "content-length sent: " ++ (if Dict.member "content-length" echo.headers then "True" else "False")
                                                        , "source after upload: " ++ after
                                                        ]
                                                    )

                                        Err e ->
                                            Task.fail ("bad echo: " ++ D.errorToString e ++ " in " ++ json)
                                )
                    )
        )
