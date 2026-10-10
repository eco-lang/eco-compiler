module HttpStreamHeadersTest exposing (main)

{-| Headers both ways (plans/eco-system-library.md Phase 8 step 8.3, B1a, E.6):
`Http.header` values built by elm/http are sent (this pins the kernel's
read-only view of elm/http's `Header` constructor), response header names are
lower-cased, and a response header sent twice is joined with ", " in arrival
order.
-}

-- CHECK: sent x-custom: eco-value
-- CHECK: sent x-empty-safe: two words
-- CHECK: x-test-server: eco
-- CHECK: x-dup: one, two
-- CHECK: names lower-cased: True
-- EXIT: 0

import Dict
import Http
import Http.Stream
import HttpStreamTestHelp as H
import Json.Decode as D
import Task


main =
    H.program
        (\server _ ->
            Http.Stream.task
                { method = "GET"
                , headers = [ Http.header "X-Custom" "eco-value", Http.header "X-Empty-Safe" "two words" ]
                , url = H.url server "/echo-headers?dup=1"
                , body = Http.Stream.emptyBody
                , resolver =
                    Http.Stream.streamResolver
                        (\r ->
                            case r of
                                Http.GoodStatus_ meta body ->
                                    Ok ( meta, body )

                                _ ->
                                    Err "unexpected response"
                        )
                , timeout = Nothing
                }
                |> Task.andThen
                    (\( meta, body ) ->
                        H.streamErr (H.readAllString body)
                            |> Task.andThen
                                (\json ->
                                    case D.decodeString (D.dict D.string) json of
                                        Ok sent ->
                                            let
                                                get k d =
                                                    Maybe.withDefault "-" (Dict.get k d)
                                            in
                                            Task.succeed
                                                [ "sent x-custom: " ++ get "x-custom" sent
                                                , "sent x-empty-safe: " ++ get "x-empty-safe" sent
                                                , "x-test-server: " ++ get "x-test-server" meta.headers
                                                , "x-dup: " ++ get "x-dup" meta.headers
                                                , "names lower-cased: "
                                                    ++ (if List.all (\k -> k == String.toLower k) (Dict.keys meta.headers) then "True" else "False")
                                                ]

                                        Err e ->
                                            Task.fail (D.errorToString e)
                                )
                    )
        )
