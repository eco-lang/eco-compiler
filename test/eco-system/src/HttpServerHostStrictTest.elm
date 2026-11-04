module HttpServerHostStrictTest exposing (main)

{-| Strict `Host` literals and the absolute-form scheme (plans/kernel-lib-bug-fixes.md,
HTTPSRV-02 and HTTPSRV-04; RFC 3986 §3.2.2, RFC 6874, RFC 3986 §3.1).

HTTPSRV-02: a bracketed `Host` must be an IP-literal, that is an IPv6 address (optionally with an
RFC 6874 `%25` zone id) or an IPvFuture `v<hex>.<chars>`. `[zz!$:]`, `[:]` and `[1::2::3]` are
none of these, so each is answered 400 and closed and never reaches the program. Before the fix
`Http1.cpp` `validHost` accepted any reg-name characters between the brackets as long as one
`:` was present, so the junk was answered 200 and delivered.

HTTPSRV-04: the scheme of an absolute-form target is case-insensitive. `GET HTTP://Other.test/abs2`
must be kept as an absolute URL (with the scheme lower-cased, since `Url.fromString` only accepts
lower-case `http://`), not treated as a path. Before the fix `absoluteUrl` compared a lower-case
prefix only and delivered `http://other.test/HTTP://Other.test/abs2`.

`Url.fromString` cannot parse an IPv6 host, so the handler logs the `Host` header and the URL.

The JS twin (`HttpServer.js` `_HttpServer_validHost`, `_HttpServer_absoluteUrl`) had the same two
bugs and was fixed with the native one (decision D5).

-}

-- CHECK: client: bracket junk: 400 close
-- CHECK: client: bracket junk: closed
-- CHECK: client: bracket colon only: 400 close
-- CHECK: client: bracket colon only: closed
-- CHECK: client: bracket two gaps: 400 close
-- CHECK: client: bracket two gaps: closed
-- CHECK-NOT: server: host [zz
-- CHECK-NOT: server: host [:]
-- CHECK-NOT: server: host [1::2::3]
-- CHECK: server: host [::1]:8080
-- CHECK: client: ipv6: 200 keep-alive ok
-- CHECK: server: host [fe80::1%25eth0]
-- CHECK: client: ipv6 zone: 200 keep-alive ok
-- CHECK: server: host [v1.fe:x]
-- CHECK: client: ipvfuture: 200 keep-alive ok
-- CHECK: server: url http://Other.test/abs2 path /abs2
-- CHECK: client: absolute upper: 200 keep-alive ok
-- CHECK: server: url https://Other.test/abs3 path /abs3
-- CHECK: client: absolute mixed https: 200 keep-alive ok
-- CHECK-NOT: /HTTP://
-- CHECK-NOT: /HttpS://
-- EXIT: 0

import Dict
import Http.Server as Server
import HttpServerRawHelp as H
import Task exposing (Task)


crlf : String
crlf =
    "\u{000D}\n"


bad : Server.Server -> String -> String -> Task String (List String)
bad server label headers =
    H.connect server
        |> Task.andThen (H.exchange ("GET /never HTTP/1.1" ++ crlf ++ headers ++ crlf) 1 True)
        |> Task.map (List.map (\l -> label ++ ": " ++ l))


good : Server.Server -> String -> String -> Task String (List String)
good server label text =
    H.connect server
        |> Task.andThen (H.exchange text 1 False)
        |> Task.map (List.map (\l -> label ++ ": " ++ l))


client : Server.Server -> Task String (List String)
client server =
    Task.sequence
        [ bad server "bracket junk" ("Host: [zz!$:]" ++ crlf)
        , bad server "bracket colon only" ("Host: [:]" ++ crlf)
        , bad server "bracket two gaps" ("Host: [1::2::3]" ++ crlf)
        , good server "ipv6" ("GET /v6 HTTP/1.1" ++ crlf ++ "Host: [::1]:8080" ++ crlf ++ crlf)
        , good server "ipv6 zone" ("GET /zone HTTP/1.1" ++ crlf ++ "Host: [fe80::1%25eth0]" ++ crlf ++ crlf)
        , good server "ipvfuture" ("GET /future HTTP/1.1" ++ crlf ++ "Host: [v1.fe:x]" ++ crlf ++ crlf)
        , good server "absolute upper" ("GET HTTP://Other.test/abs2 HTTP/1.1" ++ crlf ++ "Host: other.test" ++ crlf ++ crlf)
        , good server "absolute mixed https" ("GET HttpS://Other.test/abs3 HTTP/1.1" ++ crlf ++ "Host: other.test" ++ crlf ++ crlf)
        ]
        |> Task.map List.concat


main =
    H.program { options = identity, handler = handler, client = client, exitAtEnd = True }


handler : List String -> Server.Request -> Server.Response -> ( List String, H.Answer )
handler _ request response =
    let
        url =
            -- requestInfo is "<METHOD> <url>"
            Server.requestToString request |> String.split " " |> List.drop 1 |> String.join " "

        host =
            Dict.get "Host" request.headers |> Maybe.withDefault "-"
    in
    ( [ "host " ++ host, "url " ++ url ++ " path " ++ request.url.path ]
    , H.Now (response |> Server.setBody "ok")
    )
