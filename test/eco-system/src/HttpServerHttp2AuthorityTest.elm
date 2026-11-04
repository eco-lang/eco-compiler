module HttpServerHttp2AuthorityTest exposing (main)

{-| HTTPSRV-NEW-3 (follow-up of HTTPSRV-02/04, plans/kernel-lib-bug-fixes.md): an HTTP/2 request's
authority is checked as an HTTP/1 Host is (RFC 9110 §7.2 `uri-host [ ":" port ]`, Http1.cpp
`validHost`, HttpServer.js `_HttpServer_validHost`): `:authority`, or the `host` field when there
is no `:authority`, must be a bracketed IP-literal or a reg-name, with at most five port digits;
anything else is answered 400 without reaching the program. nghttp2 (natively and inside Node)
only checks the characters (it resets a stream whose `:authority` holds `@`, PROTOCOL_ERROR), so
`[zz!$:]`, `[1::2::3]`, a six-digit port and `8x` were delivered before.
The requests are raw frames from the Node peer (`authority` mode), so no client library rewrites
them. The server prints the path of each request it gets.

-}

-- CHECK: server: /a
-- CHECK: client: plain: status 200
-- CHECK: client: with port: status 200
-- CHECK: client: ipv6: status 200
-- CHECK: client: bracket junk: status 400
-- CHECK: client: userinfo: reset PROTOCOL_ERROR
-- CHECK: client: long port: status 400
-- CHECK: client: bad port: status 400
-- CHECK: client: host only: status 200
-- CHECK: client: bad host only: status 400
-- CHECK: client: host differs: status 400
-- EXIT: 0

import Http.Server as Server
import HttpServerH2Help as H
import Task exposing (Task)


handler : Server.Request -> Server.Response -> ( List String, H.Answer )
handler request response =
    ( [ request.url.path ], H.Now (response |> Server.setBody "ok") )


client : H.Tools -> List Server.Server -> Task String (List String)
client tools servers =
    case servers of
        [ server ] ->
            let
                case_ label args =
                    H.node tools server "authority" args
                        |> Task.map (List.map (\l -> label ++ ": " ++ l))
            in
            [ case_ "plain" [ "localhost" ]
            , case_ "with port" [ "localhost:8443" ]
            , case_ "ipv6" [ "[::1]:8443" ]
            , case_ "bracket junk" [ "[zz!$:]" ]
            , case_ "userinfo" [ "user@localhost" ]
            , case_ "long port" [ "localhost:123456" ]
            , case_ "bad port" [ "localhost:8x" ]
            , case_ "host only" [ "-", "localhost" ]
            , case_ "bad host only" [ "-", "[1::2::3]" ]
            , case_ "host differs" [ "localhost", "other" ]
            ]
                |> Task.sequence
                |> Task.map List.concat

        _ ->
            Task.fail "expected one server"


main =
    H.program { servers = [ identity ], handler = handler, client = client }
