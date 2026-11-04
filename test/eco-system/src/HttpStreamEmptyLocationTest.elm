module HttpStreamEmptyLocationTest exposing (main)

{-| HTTPS-04 (plans/kernel-lib-bug-fixes.md): a 3xx with an empty `Location:`
header is a final response, and its metadata are those the server sent.

`/redirect-empty-location` answers `302 Found` with `Location:` empty and
`Content-Type: text/plain`. libcurl does not follow an empty Location and
finishes the transfer with status 302. Before the fix the native header
callback (S/HttpStream/HttpTransfer.cpp `headerCb`) marked any `location`
header as a followed redirect, so no response head was posted, and
`finishTransfer`'s fallback posted one with an empty status text and no
headers. Now only a non-empty Location counts, and the fallback keeps the
last header block's head. The JS twin treats the empty Location as absent,
as before.

-}

-- CHECK: kind: BadStatus 302
-- CHECK: statusText: [Found]
-- CHECK: content-type: text/plain
-- CHECK: body: []
-- EXIT: 0

import Bytes exposing (Bytes)
import Dict
import Http
import Http.Method
import Http.Stream
import HttpStreamTestHelp as H
import Stream
import Task


main =
    H.program
        (\server _ ->
            Http.Stream.task
                { method = Http.Method.GET
                , headers = []
                , url = H.url server "/redirect-empty-location"
                , body = Http.Stream.emptyBody
                , resolver =
                    Http.Stream.streamResolver
                        (\r ->
                            case r of
                                Http.GoodStatus_ m b ->
                                    Ok ( "GoodStatus", m, b )

                                Http.BadStatus_ m b ->
                                    Ok ( "BadStatus", m, b )

                                Http.NetworkError_ ->
                                    Err "NetworkError"

                                Http.Timeout_ ->
                                    Err "Timeout"

                                Http.BadUrl_ u ->
                                    Err ("BadUrl " ++ u)
                        )
                , timeout = Just 10000
                }
                |> Task.andThen
                    (\( kind, meta, body ) ->
                        H.readAllString body
                            |> Task.onError (\e -> Task.succeed ("read error: " ++ Stream.errorToString e))
                            |> Task.map
                                (\text ->
                                    [ "kind: " ++ kind ++ " " ++ String.fromInt meta.statusCode
                                    , "statusText: [" ++ meta.statusText ++ "]"
                                    , "content-type: " ++ Maybe.withDefault "-" (Dict.get "content-type" meta.headers)
                                    , "body: [" ++ text ++ "]"
                                    ]
                                )
                    )
        )
