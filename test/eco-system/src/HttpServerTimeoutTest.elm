module HttpServerTimeoutTest exposing (main)

{-| Timeouts (plans/eco-system-websockets.md §3.4 "Timeouts", §4 WS2) with `headersTimeout = 300`,
`requestTimeout = 600` and `keepAliveTimeout = 300`: a request whose header block never ends is
answered 408 and closed; one whose body stops short of its `Content-Length` too; an answered
keep-alive connection that stays idle is closed silently. The program's own answer has no time
limit (it answers 800 ms late, longer than every timeout).
-}

-- CHECK: server: GET /slow-answer
-- CHECK: client: headers: 408 close
-- CHECK: client: headers: closed
-- CHECK: client: body: 408 close
-- CHECK: client: body: closed
-- CHECK: client: slow answer: 200 keep-alive late
-- CHECK: client: idle: closed
-- EXIT: 0

import Http.Server as Server
import Http.Server.Response as Response
import HttpServerRawHelp as H
import Task exposing (Task)


handler : List String -> Server.Request -> Response.Response -> ( List String, H.Answer )
handler _ request response =
    ( [ Server.methodToString request.method ++ " " ++ request.url.path ]
    , H.After 800 (response |> Response.setBody "late")
    )


crlf : String
crlf =
    "\u{000D}\n"


client : Server.Server -> Task String (List String)
client server =
    let
        headers =
            H.connect server
                |> Task.andThen (H.exchange ("GET /never HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf) 1 True)
                |> Task.map (List.map ((++) "headers: "))

        body =
            H.connect server
                |> Task.andThen (H.exchange ("POST /short HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ "Content-Length: 10" ++ crlf ++ crlf ++ "abc") 1 True)
                |> Task.map (List.map ((++) "body: "))

        slow =
            H.connect server
                |> Task.andThen
                    (\conn ->
                        H.exchange ("GET /slow-answer HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ crlf) 1 False conn
                            |> Task.andThen
                                (\lines ->
                                    H.closedOrNot "" conn
                                        |> Task.map (\idle -> List.map ((++) "slow answer: ") lines ++ [ "idle: " ++ idle ])
                                )
                    )
    in
    Task.sequence [ headers, body, slow ] |> Task.map List.concat


main =
    H.program
        { options = \o -> { o | headersTimeout = 300, requestTimeout = 600, keepAliveTimeout = 300 }
        , handler = handler
        , client = client
        , exitAtEnd = True
        }
