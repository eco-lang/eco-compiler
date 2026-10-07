module HttpStreamTaskTest exposing (main)

{-| `Http.Stream.task` with `streamResolver` (plans/eco-system-library.md Phase 8
step 8.3), chained with other tasks: a `stringBody` POST, then a `jsonBody`
POST, then a `bytesBody` PATCH, each echoed by `/anything`. The resolver sees
the `Http.Response` with its metadata and the body stream.
-}

-- CHECK: string: POST text/plain abc
-- CHECK: json: POST application/json {"n":1}
-- CHECK: bytes: PATCH application/octet-stream raw
-- CHECK: status text: OK
-- EXIT: 0

import Http
import Http.Stream
import HttpStreamTestHelp as H
import Json.Decode as D
import Json.Encode as E
import Stream
import Task exposing (Task)


echo : String -> String -> Http.Stream.Body -> Task String ( String, String )
echo label method body =
    Http.Stream.task
        { method = method
        , headers = []
        , url = H.url "/anything"
        , body = body
        , resolver =
            Http.Stream.streamResolver
                (\r ->
                    case r of
                        Http.GoodStatus_ meta stream ->
                            Ok ( meta.statusText, stream )

                        _ ->
                            Err "unexpected response"
                )
        , timeout = Nothing
        }
        |> Task.andThen
            (\( statusText, stream ) ->
                H.streamErr (H.readAllString stream)
                    |> Task.andThen
                        (\json ->
                            case D.decodeString (D.map3 (\m c b -> m ++ " " ++ c ++ " " ++ b) (D.field "method" D.string) (D.field "contentType" D.string) (D.field "body" D.string)) json of
                                Ok line ->
                                    Task.succeed ( label ++ ": " ++ line, statusText )

                                Err e ->
                                    Task.fail (D.errorToString e)
                        )
            )


main =
    H.program
        (\_ ->
            echo "string" "POST" (Http.Stream.stringBody "text/plain" "abc")
                |> Task.andThen
                    (\( a, _ ) ->
                        echo "json" "POST" (Http.Stream.jsonBody (E.object [ ( "n", E.int 1 ) ]))
                            |> Task.andThen
                                (\( b, _ ) ->
                                    echo "bytes" "PATCH" (Http.Stream.bytesBody "application/octet-stream" (H.bytesOf "raw"))
                                        |> Task.map (\( c, statusText ) -> [ a, b, c, "status text: " ++ statusText ])
                                )
                    )
        )
