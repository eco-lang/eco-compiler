module HttpServerExpectHttp10Test exposing (main)

{-| `Expect` on an HTTP/1.0 request (plans/kernel-lib-bug-fixes.md, HTTPSRV-03; RFC 9110 §10.1.1,
§15.2): a server must ignore `Expect` in a request that says HTTP/1.0, so it never sends a
`100 Continue` (a 1.0 client cannot parse a 1xx) and never answers 417. Both 1.0 requests here get
only the program's `200`, then the connection closes. A control shows an HTTP/1.1 request with
`Expect: 100-continue` still gets `100` first.

Before the fix `Http1.cpp` `headersComplete` handled `Expect` regardless of the version: "1.0
continue" got `100 Continue` before the `200`, and "1.0 other" was answered 417. Node's server
(the JS twin) handles `Expect` only for HTTP/1.1.

-}

-- CHECK: server: PUT /c body abc
-- CHECK: server: PUT /d body abc
-- CHECK: client: 1.0 continue: 200 close ok
-- CHECK: client: 1.0 continue: closed
-- CHECK-NOT: client: 1.0 continue: 100
-- CHECK: client: 1.0 other: 200 close ok
-- CHECK: client: 1.0 other: closed
-- CHECK-NOT: client: 1.0 other: 417
-- CHECK: client: 1.1 continue: 100 -
-- CHECK: client: 1.1 continue: 200 keep-alive ok
-- EXIT: 0

import Http.Method
import Http.Server as Server
import HttpServerRawHelp as H
import Task exposing (Task)


handler : List String -> Server.Request -> Server.Response -> ( List String, H.Answer )
handler _ request response =
    let
        body =
            Server.bodyAsString request |> Maybe.withDefault "<invalid>"
    in
    ( [ Http.Method.toString request.method ++ " " ++ request.url.path ++ " body " ++ body ]
    , H.Now (response |> Server.setBody "ok")
    )


crlf : String
crlf =
    "\u{000D}\n"


oneShot : Server.Server -> String -> String -> Task String (List String)
oneShot server label text =
    H.connect server
        |> Task.andThen (H.exchange text 1 True)
        |> Task.map (List.map (\l -> label ++ ": " ++ l))


client : Server.Server -> Task String (List String)
client server =
    Task.sequence
        [ oneShot server "1.0 continue" ("PUT /c HTTP/1.0" ++ crlf ++ "Content-Length: 3" ++ crlf ++ "Expect: 100-continue" ++ crlf ++ crlf ++ "abc")
        , oneShot server "1.0 other" ("PUT /d HTTP/1.0" ++ crlf ++ "Content-Length: 3" ++ crlf ++ "Expect: later" ++ crlf ++ crlf ++ "abc")
        , H.connect server
            |> Task.andThen
                (\conn ->
                    H.sendRaw ("PUT /e HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ "Content-Length: 3" ++ crlf ++ "Expect: 100-continue" ++ crlf ++ crlf) conn
                        |> Task.andThen (\_ -> H.readResponses 1 conn)
                        |> Task.andThen
                            (\( interim, _ ) ->
                                H.exchange "abc" 1 False conn
                                    |> Task.map (\final -> List.map H.describe interim ++ final)
                            )
                )
            |> Task.map (List.map (\l -> "1.1 continue: " ++ l))
        ]
        |> Task.map List.concat


main =
    H.program { options = identity, handler = handler, client = client, exitAtEnd = True }
