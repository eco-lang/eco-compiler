module HttpServerHttp2LimitsTest exposing (main)

{-| HTTP/2 limits (plans/eco-system-websockets.md §3.8, §4 WS8):

  - a header list over `maxHeaderSize` (name + value + 32 per field) is answered 431 (sent by the
    raw Node peer: curl may refuse to send a list over the advertised MAX_HEADER_LIST_SIZE once it
    has the server's SETTINGS, so with curl the outcome depends on timing);
  - a body over `maxBodySize` is answered 413, by `content-length` (before the body) and, without
    one, by its running total;
  - rapid reset (CVE-2023-44487): with the default (no `maxConcurrentStreams`), a client that
    opens and cancels 1100 streams at once gets GOAWAY from the stream reset rate limit (burst
    1000; nghttp2 and Node both use INTERNAL_ERROR) and the connection ends;
  - `maxConcurrentStreams = Just 10` is advertised (SETTINGS) and enforced: of 11 requests sent at
    once, the 11th is not served while the first 10 wait for their answers (natively it waits
    until one is answered, Node refuses it).

-}

-- CHECK: client: big header: status 431
-- CHECK: client: small header: HTTP/2 200 | content-length: 2 | ok
-- CHECK: client: big body: HTTP/2 413 | content-length: 0 |
-- CHECK: client: chunked big body: HTTP/2 413 | content-length: 0 |
-- CHECK: client: small body: HTTP/2 200 | content-length: 2 | ok
-- CHECK: client: rapid reset: goaway INTERNAL_ERROR
-- CHECK: client: rapid reset: closed
-- CHECK: client: limit: max_concurrent_streams 10
-- CHECK: client: limit: first 10 answered true
-- CHECK: client: limit: last served concurrently false
-- CHECK-NOT: max_concurrent_streams 4294967295
-- EXIT: 0

import Http.Server as Server
import Http.Server.Response as Response
import HttpServerH2Help as H
import Task exposing (Task)


handler : Server.Request -> Response.Response -> ( List String, H.Answer )
handler request response =
    if String.startsWith "/c" request.url.path then
        ( [], H.After 400 (response |> Response.setBody "ok") )

    else
        ( [], H.Now (response |> Response.setBody "ok") )


limited : Server.ServerOptions -> Server.ServerOptions
limited options =
    { options | maxHeaderSize = 2000, maxBodySize = 1000 }


capped : Server.ServerOptions -> Server.ServerOptions
capped options =
    { options | maxConcurrentStreams = Just 10 }


client : H.Tools -> List Server.Server -> Task String (List String)
client tools servers =
    case servers of
        [ server, cappedServer ] ->
            let
                step label args path =
                    H.curlLines tools server ("--http2" :: args) path |> Task.map (\l -> label ++ ": " ++ l)

                prefixed label lines =
                    List.map (\l -> label ++ ": " ++ l) lines
            in
            [ H.node tools server "big-header" [ "2500" ] |> Task.map (prefixed "big header")
            , step "small header" [ "-H", "X-Small: " ++ String.repeat 500 "a" ] "/h"
                |> Task.map List.singleton
            , step "big body" [ "--data-binary", String.repeat 1500 "b" ] "/b"
                |> Task.map List.singleton
            , step "chunked big body" [ "--data-binary", String.repeat 1500 "b", "-H", "Content-Length:" ] "/b"
                |> Task.map List.singleton
            , step "small body" [ "--data-binary", String.repeat 900 "b" ] "/b"
                |> Task.map List.singleton
            , H.node tools server "rapid-reset" [ "1100" ] |> Task.map (prefixed "rapid reset")
            , H.node tools cappedServer "limit" [ "11" ] |> Task.map (prefixed "limit")
            ]
                |> Task.sequence
                |> Task.map List.concat

        _ ->
            Task.fail "expected two servers"


main =
    H.program { servers = [ limited, capped ], handler = handler, client = client }
