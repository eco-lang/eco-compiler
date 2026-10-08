module HttpServerHttp2Test exposing (main)

{-| HTTP/2 in `Http.Server` (plans/eco-system-websockets.md §3.8, §4 WS8), with `curl --http2` as
the peer: GET and POST over h2 (`version = Http2`), lower-case header names, cookie crumbs joined
with "; ", the absolute URL from `:authority`, response header names lower-cased and
`Connection` dropped, HEAD (content-length, no body), 204, a user 103 answered 500, and an
HTTP/1.1 client on the same server (ALPN `http/1.1`, `allowHTTP1`).
-}

-- CHECK: server: GET https://localhost/get Http2 port set
-- CHECK: server: headers accept,cookie,user-agent,x-test
-- CHECK: server: cookie a=1; b=2
-- CHECK: server: POST https://localhost/post Http2 port set
-- CHECK: server: body payload-123
-- CHECK: server: HEAD https://localhost/head Http2 port set
-- CHECK: server: GET https://localhost/nocontent Http2 port set
-- CHECK: server: GET https://localhost/onexx Http2 port set
-- CHECK: server: GET https://localhost/h1 Http1_1 port set
-- CHECK: client: get: HTTP/2 200 | content-length: 8, x-reply: Yes | hello h2
-- CHECK: client: post: HTTP/2 200 | content-length: 11 | payload-123
-- CHECK: client: head: HTTP/2 200 | content-length: 3 |
-- CHECK: client: nocontent: HTTP/2 204 | x-empty: 1 |
-- CHECK: client: onexx: HTTP/2 500 | content-length: 0 |
-- CHECK: client: h1: HTTP/1.1 200 OK | connection: keep-alive, content-length: 2 | h1
-- EXIT: 0

import Dict
import Http.Server as Server exposing (HttpVersion(..))
import Http.Server.Response as Response
import HttpServerH2Help as H
import Task exposing (Task)


version : HttpVersion -> String
version v =
    case v of
        Http1_0 ->
            "Http1_0"

        Http1_1 ->
            "Http1_1"

        Http2 ->
            "Http2"


info : Server.Request -> String
info request =
    stripPort (Server.requestInfo request)
        ++ " "
        ++ version request.version
        ++ (if request.url.port_ /= Nothing then " port set" else " no port")


{-| "GET https://localhost:4433/a" → "GET https://localhost/a" (the port is the system's pick).
-}
stripPort : String -> String
stripPort text =
    case String.indexes "://" text of
        i :: _ ->
            let
                before =
                    String.left (i + 3) text

                rest =
                    String.dropLeft (i + 3) text

                ( authority, path ) =
                    case String.indexes "/" rest of
                        j :: _ ->
                            ( String.left j rest, String.dropLeft j rest )

                        [] ->
                            ( rest, "" )

                host =
                    case String.indexes ":" authority of
                        k :: _ ->
                            String.left k authority

                        [] ->
                            authority
            in
            before ++ host ++ path

        [] ->
            text


handler : Server.Request -> Response.Response -> ( List String, H.Answer )
handler request response =
    case request.url.path of
        "/get" ->
            ( [ info request
              , "headers " ++ String.join "," (Dict.keys request.headers)
              , "cookie " ++ Maybe.withDefault "none" (Dict.get "cookie" request.headers)
              ]
            , H.Now
                (response
                    |> Response.setHeader "X-Reply" "Yes"
                    |> Response.setHeader "Connection" "close"
                    |> Response.setBody "hello h2"
                )
            )

        "/post" ->
            ( [ info request, "body " ++ Maybe.withDefault "<invalid>" (Server.bodyAsString request) ]
            , H.Now (response |> Response.setBody (Maybe.withDefault "" (Server.bodyAsString request)))
            )

        "/head" ->
            ( [ info request ], H.Now (response |> Response.setBody "abc") )

        "/nocontent" ->
            ( [ info request ], H.Now (response |> Response.setStatus 204 |> Response.setHeader "X-Empty" "1") )

        "/onexx" ->
            ( [ info request ], H.Now (response |> Response.setStatus 103) )

        _ ->
            ( [ info request ], H.Now (response |> Response.setBody "h1") )


client : H.Tools -> List Server.Server -> Task String (List String)
client tools servers =
    case servers of
        server :: _ ->
            let
                step label args path =
                    H.curlLines tools server args path |> Task.map (\l -> label ++ ": " ++ l)
            in
            [ step "get" [ "--http2", "-H", "X-Test: 1", "-H", "Cookie: a=1", "-H", "Cookie: b=2" ] "/get"
            , step "post" [ "--http2", "--data-binary", "payload-123", "-H", "Content-Type:" ] "/post"
            , step "head" [ "--http2", "-I" ] "/head"
            , step "nocontent" [ "--http2" ] "/nocontent"
            , step "onexx" [ "--http2" ] "/onexx"
            , step "h1" [ "--http1.1" ] "/h1"
            ]
                |> Task.sequence

        [] ->
            Task.fail "no server"


main =
    H.program { servers = [ identity ], handler = handler, client = client }
