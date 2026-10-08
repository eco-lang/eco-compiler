module HttpServerSmugglingTest exposing (main)

{-| Request smuggling and malformed requests (plans/eco-system-websockets.md §3.4 "Request
smuggling", §4 WS2): the parser is strict, so `Content-Length` with `Transfer-Encoding`, two
`Content-Length` headers, a `Transfer-Encoding` whose last coding is not `chunked`, an obs-fold
continuation line, bare LF line endings and a space before a header's colon are each answered 400
and the connection closed. None of them reaches the program; a valid request on a fresh
connection afterwards still works.
-}

-- CHECK-NOT: server: POST /smuggled
-- CHECK: server: GET /fine
-- CHECK: client: cl+te: 400 close
-- CHECK: client: cl+te: closed
-- CHECK: client: duplicate cl: 400 close
-- CHECK: client: duplicate cl: closed
-- CHECK: client: te chunked, identity: 400 close
-- CHECK: client: te chunked, identity: closed
-- CHECK: client: obs-fold: 400 close
-- CHECK: client: obs-fold: closed
-- CHECK: client: bare lf: 400 close
-- CHECK: client: bare lf: closed
-- CHECK: client: space before colon: 400 close
-- CHECK: client: space before colon: closed
-- CHECK: client: fine: 200 keep-alive ok
-- EXIT: 0

import Http.Server as Server
import Http.Server.Response as Response
import HttpServerRawHelp as H
import Task exposing (Task)


handler : List String -> Server.Request -> Response.Response -> ( List String, H.Answer )
handler _ request response =
    ( [ Server.methodToString request.method ++ " " ++ request.url.path ]
    , H.Now (response |> Response.setBody "ok")
    )


crlf : String
crlf =
    "\u{000D}\n"


attack : Server.Server -> String -> String -> Task String (List String)
attack server label text =
    H.connect server
        |> Task.andThen (H.exchange text 1 True)
        |> Task.map (List.map (\l -> label ++ ": " ++ l))


post : List String -> String -> String
post headerLines body =
    "POST /smuggled HTTP/1.1" ++ crlf ++ String.concat (List.map (\l -> l ++ crlf) ("Host: h" :: headerLines)) ++ crlf ++ body


client : Server.Server -> Task String (List String)
client server =
    Task.sequence
        [ attack server "cl+te" (post [ "Content-Length: 5", "Transfer-Encoding: chunked" ] ("0" ++ crlf ++ crlf))
        , attack server "duplicate cl" (post [ "Content-Length: 3", "Content-Length: 4" ] "abcd")
        , attack server "te chunked, identity" (post [ "Transfer-Encoding: chunked, identity" ] ("0" ++ crlf ++ crlf))
        , attack server "obs-fold" (post [ "X-Folded: a", " b", "Content-Length: 0" ] "")
        , attack server "bare lf" "POST /smuggled HTTP/1.1\nHost: h\nContent-Length: 0\n\n"
        , attack server "space before colon" (post [ "Content-Length : 0" ] "")
        , H.connect server
            |> Task.andThen (H.exchange ("GET /fine HTTP/1.1" ++ crlf ++ "Host: h" ++ crlf ++ crlf) 1 False)
            |> Task.map (List.map ((++) "fine: "))
        ]
        |> Task.map List.concat


main =
    H.program { options = identity, handler = handler, client = client, exitAtEnd = True }
