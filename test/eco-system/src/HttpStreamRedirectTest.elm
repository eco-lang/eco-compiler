module HttpStreamRedirectTest exposing (main)

{-| Redirects (plans/eco-system-library.md Phase 8 step 8.3, E.6): `/redirect`
answers 302 to `/anything`; `Metadata.url` is the final URL and the headers are
only the final hop's (no `location`, the final content type).
-}

-- CHECK: status: 200
-- CHECK: final url: True
-- CHECK: location header: False
-- CHECK: content-type: application/json
-- EXIT: 0

import Dict
import Http
import Http.Stream
import HttpStreamTestHelp as H
import Stream
import Task


main =
    H.program
        (\server _ ->
            Http.Stream.task
                { method = "GET"
                , headers = []
                , url = H.url server "/redirect"
                , body = Http.Stream.emptyBody
                , resolver =
                    Http.Stream.streamResolver
                        (\r ->
                            case r of
                                Http.GoodStatus_ meta b ->
                                    Ok ( meta, b )

                                _ ->
                                    Err "unexpected response"
                        )
                , timeout = Nothing
                }
                |> Task.andThen
                    (\( meta, b ) ->
                        H.streamErr (Stream.cancelReadable "not needed" b)
                            |> Task.map
                                (\_ ->
                                    [ "status: " ++ String.fromInt meta.statusCode
                                    , "final url: " ++ (if meta.url == H.url server "/anything" then "True" else "False (" ++ meta.url ++ ")")
                                    , "location header: " ++ (if Dict.member "location" meta.headers then "True" else "False")
                                    , "content-type: " ++ Maybe.withDefault "-" (Dict.get "content-type" meta.headers)
                                    ]
                                )
                    )
        )
