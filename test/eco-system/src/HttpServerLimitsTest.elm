module HttpServerLimitsTest exposing (main)

{-| Request limits (plans/eco-system-websockets.md §3.4 "Limits", "Expect: 100-continue", §4 WS2)
with `maxBodySize = 100` and `maxHeaderSize = 1024`: a header block over the limit is answered 431,
a `Content-Length` over it 413 (without `100 Continue` even when the client expects one), a chunked
body whose running total exceeds it 413; each closes the connection and none reaches the program.
A small body with `Expect: 100-continue` gets `100 Continue` first, then the program's answer.
-}

-- CHECK: server: PUT /small body 0123456789
-- CHECK-NOT: server: GET /big-header
-- CHECK-NOT: server: PUT /too-long
-- CHECK: client: big header: 431 close
-- CHECK: client: big header: closed
-- CHECK: client: content-length: 413 close
-- CHECK: client: content-length: closed
-- CHECK: client: expect too long: 413 close
-- CHECK: client: expect too long: closed
-- CHECK: client: chunked: 413 close
-- CHECK: client: chunked: closed
-- CHECK: client: expect small: 100 -
-- CHECK: client: expect small: 200 keep-alive got 10
-- EXIT: 0

import Http.Server as Server
import Http.Server.Response as Response
import HttpServerRawHelp as H
import Task exposing (Task)


handler : List String -> Server.Request -> Response.Response -> ( List String, H.Answer )
handler _ request response =
    let
        body =
            Server.bodyAsString request |> Maybe.withDefault "<invalid>"
    in
    ( [ Server.methodToString request.method ++ " " ++ request.url.path ++ " body " ++ body ]
    , H.Now (response |> Response.setBody ("got " ++ String.fromInt (String.length body)))
    )


crlf : String
crlf =
    "\u{000D}\n"


oneShot : Server.Server -> String -> String -> Task String (List String)
oneShot server label text =
    H.connect server
        |> Task.andThen (H.exchange text 1 True)
        |> Task.map (List.map (\l -> label ++ ": " ++ l))


chunk : String -> String
chunk data =
    "32" ++ crlf ++ data ++ crlf


client : Server.Server -> Task String (List String)
client server =
    let
        cases =
            [ oneShot server "big header" ("GET /big-header HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ "X-Big: " ++ String.repeat 1100 "x" ++ crlf ++ crlf)
            , oneShot server "content-length" ("PUT /too-long HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ "Content-Length: 101" ++ crlf ++ crlf ++ String.repeat 101 "b")
            , oneShot server "expect too long" ("PUT /too-long HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ "Content-Length: 500" ++ crlf ++ "Expect: 100-continue" ++ crlf ++ crlf)
            , oneShot server
                "chunked"
                ("PUT /too-long HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ "Transfer-Encoding: chunked" ++ crlf ++ crlf
                    ++ chunk (String.repeat 50 "a")
                    ++ chunk (String.repeat 50 "b")
                    ++ chunk (String.repeat 50 "c")
                    ++ "0"
                    ++ crlf
                    ++ crlf
                )
            , H.connect server
                |> Task.andThen
                    (\conn ->
                        H.sendRaw ("PUT /small HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ "Content-Length: 10" ++ crlf ++ "Expect: 100-continue" ++ crlf ++ crlf) conn
                            |> Task.andThen (\_ -> H.readResponses 1 conn)
                            |> Task.andThen
                                (\( interim, _ ) ->
                                    H.exchange "0123456789" 1 False conn
                                        |> Task.map (\final -> List.map H.describe interim ++ final)
                                )
                    )
                |> Task.map (List.map (\l -> "expect small: " ++ l))
            ]
    in
    Task.sequence cases |> Task.map List.concat


main =
    H.program
        { options = \o -> { o | maxBodySize = 100, maxHeaderSize = 1024 }
        , handler = handler
        , client = client
        , exitAtEnd = True
        }
