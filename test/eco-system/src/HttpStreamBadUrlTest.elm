module HttpStreamBadUrlTest exposing (main)

{-| Failures before the headers (plans/eco-system-library.md Phase 8, B.7 kinds
0 and 2, E.6): a malformed URL and a non-HTTP scheme give `BadUrl` with the
URL (protocols are restricted to http and https), and a refused connection
gives `NetworkError`.
-}

-- CHECK: malformed: BadUrl http://exa mple.com/
-- CHECK: scheme: BadUrl file:///etc/passwd
-- CHECK: refused: NetworkError
-- EXIT: 0

import Http
import Http.Stream
import HttpStreamTestHelp as H
import Task exposing (Task)


attempt : String -> Task x String
attempt url =
    Http.Stream.task
        { method = "GET"
        , headers = []
        , url = url
        , body = Http.Stream.emptyBody
        , resolver =
            Http.Stream.streamResolver
                (\r ->
                    case r of
                        Http.BadUrl_ u ->
                            Err ("BadUrl " ++ u)

                        Http.Timeout_ ->
                            Err "Timeout"

                        Http.NetworkError_ ->
                            Err "NetworkError"

                        Http.BadStatus_ m _ ->
                            Err ("BadStatus " ++ String.fromInt m.statusCode)

                        Http.GoodStatus_ m _ ->
                            Ok ("GoodStatus " ++ String.fromInt m.statusCode)
                )
        , timeout = Nothing
        }
        |> Task.onError Task.succeed


main =
    H.program
        (\_ _ ->
            Task.map3 (\a b c -> [ "malformed: " ++ a, "scheme: " ++ b, "refused: " ++ c ])
                (attempt "http://exa mple.com/")
                (attempt "file:///etc/passwd")
                (attempt "http://127.0.0.1:1/")
        )
