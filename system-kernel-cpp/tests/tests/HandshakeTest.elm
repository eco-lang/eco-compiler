module HandshakeTest exposing (suite)

{-| Tests for WebSocket.Internal.Handshake (plans/eco-system-websockets.md §3.6, Appendix D.2,
D.3; phase WS4): URLs, the `Host` header and the TLS server name, the token grammar, the client's
request headers, the checks of a response (client) and of a request (server), the response
headers, and the extension header grammar (RFC 6455 §9.1); the permessage-deflate negotiation in
both roles (RFC 7692 §7.1, Appendix D.7; phase WS7).
-}

import Expect
import Socket.Address as Address
import Test exposing (Test, describe, test)
import WebSocket.Internal.Handshake as H


suite : Test
suite =
    describe "WebSocket.Internal.Handshake"
        [ urlTests
        , hostTests
        , tokenTests
        , requestHeaderTests
        , responseCheckTests
        , requestCheckTests
        , responseHeaderTests
        , extensionTests
        , negotiationTests
        ]



-- URLS


urlString : Result String H.Url -> String
urlString result =
    case result of
        Ok u ->
            (if u.secure then
                "wss "

             else
                "ws "
            )
                ++ hostString u.host
                ++ " "
                ++ String.fromInt u.port_
                ++ " "
                ++ u.target

        Err e ->
            "Err " ++ e


hostString : H.Host -> String
hostString host =
    case host of
        H.Name n ->
            "name " ++ n

        H.Literal a ->
            "literal " ++ Address.toString a


urlCase : String -> String -> Test
urlCase input expected =
    test input <| \_ -> urlString (H.parseUrl input) |> Expect.equal expected


urlTests : Test
urlTests =
    describe "parseUrl"
        [ urlCase "ws://example.com" "ws name example.com 80 /"
        , urlCase "wss://example.com" "wss name example.com 443 /"
        , urlCase "WSS://Example.COM:8443/Chat?Room=1" "wss name example.com 8443 /Chat?Room=1"
        , urlCase "ws://example.com?x=1" "ws name example.com 80 /?x=1"
        , urlCase "ws://127.0.0.1:0/" "ws literal 127.0.0.1 0 /"
        , urlCase "ws://127.0.0.1:65535/" "ws literal 127.0.0.1 65535 /"
        , urlCase "ws://h:/" "ws name h 80 /"
        , urlCase "ws://[::1]:9000/a/b" "ws literal ::1 9000 /a/b"
        , urlCase "ws://[fe80::1%25eth0]/" "ws literal fe80::1%eth0 80 /"
        , urlCase "ws://[::ffff:127.0.0.1]/" "ws literal ::ffff:127.0.0.1 80 /"
        , test "fragment" <| \_ -> H.parseUrl "ws://h/#x" |> Expect.err
        , test "userinfo" <| \_ -> H.parseUrl "ws://u:p@h/" |> Expect.err
        , test "port too big" <| \_ -> H.parseUrl "ws://h:65536/" |> Expect.err
        , test "port not a number" <| \_ -> H.parseUrl "ws://h:8a/" |> Expect.err
        , test "other scheme" <| \_ -> H.parseUrl "http://h/" |> Expect.err
        , test "no scheme" <| \_ -> H.parseUrl "h/x" |> Expect.err
        , test "empty host" <| \_ -> H.parseUrl "ws:///x" |> Expect.err
        , test "bad IPv6" <| \_ -> H.parseUrl "ws://[::g]/" |> Expect.err
        , test "bracketed IPv4" <| \_ -> H.parseUrl "ws://[127.0.0.1]/" |> Expect.err
        , test "unbracketed IPv6" <| \_ -> H.parseUrl "ws://::1/" |> Expect.err
        , test "space" <| \_ -> H.parseUrl "ws://h/a b" |> Expect.err
        , test "non-ASCII" <| \_ -> H.parseUrl "ws://hé/" |> Expect.err
        , test "bad host character" <| \_ -> H.parseUrl "ws://a<b/" |> Expect.err
        ]


hostCase : String -> String -> String -> Test
hostCase input host name =
    test ("host " ++ input) <|
        \_ ->
            H.parseUrl input
                |> Result.map (\u -> ( H.hostHeader u, H.serverName u ))
                |> Expect.equal (Ok ( host, name ))


hostTests : Test
hostTests =
    describe "hostHeader / serverName"
        [ hostCase "ws://example.com/" "example.com" "example.com"
        , hostCase "ws://example.com:80/" "example.com" "example.com"
        , hostCase "ws://example.com:443/" "example.com:443" "example.com"
        , hostCase "wss://example.com:443/" "example.com" "example.com"
        , hostCase "wss://example.com:80/" "example.com:80" "example.com"
        , hostCase "ws://127.0.0.1:8080/" "127.0.0.1:8080" "127.0.0.1"
        , hostCase "ws://[::1]/" "[::1]" "::1"
        , hostCase "wss://[fe80::1%25eth0]:9443/" "[fe80::1]:9443" "fe80::1"
        ]



-- TOKENS


tokenTests : Test
tokenTests =
    describe "tokens"
        [ test "tokenList" <| \_ -> H.tokenList " keep-alive, Upgrade ,, " |> Expect.equal [ "keep-alive", "upgrade" ]
        , test "headerTokens over occurrences, case-insensitive names" <|
            \_ -> H.headerTokens "connection" [ ( "Connection", "keep-alive" ), ( "connection", "UPGRADE" ) ] |> Expect.equal [ "keep-alive", "upgrade" ]
        , test "headerValues in order" <|
            \_ -> H.headerValues "x" [ ( "x", "1" ), ( "y", "2" ), ( "X", "3" ) ] |> Expect.equal [ "1", "3" ]
        , test "isToken" <| \_ -> List.map H.isToken [ "chat", "a.b-c_d~e!", "", "a b", "a,b", "a/b", "é" ] |> Expect.equal [ True, True, False, False, False, False, False ]
        ]



-- CLIENT REQUEST (D.2)


baseRequest : { host : String, key : String, protocols : List String, extensions : Maybe String, headers : List ( String, String ) }
baseRequest =
    { host = "h:1", key = "k", protocols = [], extensions = Nothing, headers = [] }


requestHeaderTests : Test
requestHeaderTests =
    describe "requestHeaders"
        [ test "the D.2 headers in order" <|
            \_ ->
                H.requestHeaders { baseRequest | protocols = [ "a", "b" ], headers = [ ( "Origin", "o" ) ] }
                    |> Expect.equal
                        (Ok
                            [ ( "Host", "h:1" )
                            , ( "Upgrade", "websocket" )
                            , ( "Connection", "Upgrade" )
                            , ( "Sec-WebSocket-Key", "k" )
                            , ( "Sec-WebSocket-Version", "13" )
                            , ( "Sec-WebSocket-Protocol", "a, b" )
                            , ( "Origin", "o" )
                            ]
                        )
        , test "an invalid protocol" <| \_ -> H.requestHeaders { baseRequest | protocols = [ "a b" ] } |> Expect.err
        , test "a repeated protocol" <| \_ -> H.requestHeaders { baseRequest | protocols = [ "a", "a" ] } |> Expect.err
        , test "a reserved header" <| \_ -> H.requestHeaders { baseRequest | headers = [ ( "sec-websocket-key", "x" ) ] } |> Expect.err
        , test "Host is reserved" <| \_ -> H.requestHeaders { baseRequest | headers = [ ( "HOST", "x" ) ] } |> Expect.err
        , test "CR LF in a value" <| \_ -> H.requestHeaders { baseRequest | headers = [ ( "X", "a\u{000D}\nb" ) ] } |> Expect.err
        , test "an invalid name" <| \_ -> H.requestHeaders { baseRequest | headers = [ ( "X Y", "a" ) ] } |> Expect.err
        ]



-- RESPONSE CHECKS (client, D.2)


accept : String
accept =
    "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="


okHeaders : List ( String, String )
okHeaders =
    [ ( "upgrade", "WebSocket" ), ( "connection", "keep-alive, Upgrade" ), ( "sec-websocket-accept", accept ) ]


check : List String -> Int -> List ( String, String ) -> Result ( Maybe Int, String ) (Maybe String)
check protocols status headers =
    H.checkResponse { expectedAccept = accept, protocols = protocols, isH2 = False } status headers
        |> Result.map .protocol


responseCheckTests : Test
responseCheckTests =
    describe "checkResponse"
        [ test "a good 101" <| \_ -> check [] 101 okHeaders |> Expect.equal (Ok Nothing)
        , test "a status other than 101" <| \_ -> check [] 302 okHeaders |> Result.mapError Tuple.first |> Expect.equal (Err (Just 302))
        , test "a 200 over HTTP/1.1" <| \_ -> check [] 200 okHeaders |> Result.mapError Tuple.first |> Expect.equal (Err (Just 200))
        , test "no Upgrade" <| \_ -> check [] 101 (List.drop 1 okHeaders) |> Result.mapError Tuple.first |> Expect.equal (Err Nothing)
        , test "no Connection: upgrade" <|
            \_ -> check [] 101 [ ( "upgrade", "websocket" ), ( "connection", "keep-alive" ), ( "sec-websocket-accept", accept ) ] |> Expect.err
        , test "a wrong accept" <|
            \_ -> check [] 101 [ ( "upgrade", "websocket" ), ( "connection", "upgrade" ), ( "sec-websocket-accept", "x" ) ] |> Expect.err
        , test "two accepts" <| \_ -> check [] 101 (okHeaders ++ [ ( "sec-websocket-accept", accept ) ]) |> Expect.err
        , test "a chosen protocol" <| \_ -> check [ "a", "b" ] 101 (okHeaders ++ [ ( "Sec-WebSocket-Protocol", "b" ) ]) |> Expect.equal (Ok (Just "b"))
        , test "a protocol not offered" <| \_ -> check [ "a" ] 101 (okHeaders ++ [ ( "sec-websocket-protocol", "c" ) ]) |> Expect.err
        , test "a protocol with nothing offered" <| \_ -> check [] 101 (okHeaders ++ [ ( "sec-websocket-protocol", "c" ) ]) |> Expect.err
        , test "two protocols" <| \_ -> check [ "a", "b" ] 101 (okHeaders ++ [ ( "sec-websocket-protocol", "a, b" ) ]) |> Expect.err
        , test "an invalid extension header" <| \_ -> check [] 101 (okHeaders ++ [ ( "sec-websocket-extensions", "a;" ) ]) |> Expect.err
        , test "HTTP/2: any 2xx, no accept" <|
            \_ ->
                H.checkResponse { expectedAccept = "", protocols = [], isH2 = True } 200 []
                    |> Result.map .protocol
                    |> Expect.equal (Ok Nothing)
        ]



-- REQUEST CHECKS (server, D.3)


goodRequest : List ( String, String )
goodRequest =
    [ ( "host", "h" )
    , ( "upgrade", "websocket" )
    , ( "connection", "Upgrade" )
    , ( "sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==" )
    , ( "sec-websocket-version", "13" )
    ]


checkReq : String -> String -> List ( String, String ) -> Result Int (List String)
checkReq method version headers =
    H.checkRequest { method = method, version = version, headers = headers, isH2 = False }
        |> Result.map .protocols
        |> Result.mapError Tuple.first


without : String -> List ( String, String ) -> List ( String, String )
without name =
    List.filter (\( n, _ ) -> n /= name)


requestCheckTests : Test
requestCheckTests =
    describe "checkRequest"
        [ test "a good request" <| \_ -> checkReq "GET" "1.1" goodRequest |> Expect.equal (Ok [])
        , test "HTTP/1.2 is later than 1.1" <| \_ -> checkReq "GET" "1.2" goodRequest |> Expect.equal (Ok [])
        , test "HTTP/2.0 is later than 1.1" <| \_ -> checkReq "GET" "2.0" goodRequest |> Expect.equal (Ok [])
        , test "POST" <| \_ -> checkReq "POST" "1.1" goodRequest |> Expect.equal (Err 400)
        , test "HTTP/1.0" <| \_ -> checkReq "GET" "1.0" goodRequest |> Expect.equal (Err 400)
        , test "no Host" <| \_ -> checkReq "GET" "1.1" (without "host" goodRequest) |> Expect.equal (Err 400)
        , test "no Upgrade" <| \_ -> checkReq "GET" "1.1" (without "upgrade" goodRequest) |> Expect.equal (Err 400)
        , test "no Connection" <| \_ -> checkReq "GET" "1.1" (without "connection" goodRequest) |> Expect.equal (Err 400)
        , test "Connection lists upgrade among others" <|
            \_ -> checkReq "GET" "1.1" (without "connection" goodRequest ++ [ ( "connection", "keep-alive, UPGRADE" ) ]) |> Expect.equal (Ok [])
        , test "version 8 is 426" <|
            \_ -> checkReq "GET" "1.1" (without "sec-websocket-version" goodRequest ++ [ ( "sec-websocket-version", "8" ) ]) |> Expect.equal (Err 426)
        , test "no version is 426" <| \_ -> checkReq "GET" "1.1" (without "sec-websocket-version" goodRequest) |> Expect.equal (Err 426)
        , test "no key" <| \_ -> checkReq "GET" "1.1" (without "sec-websocket-key" goodRequest) |> Expect.equal (Err 400)
        , test "a 20-byte key" <|
            \_ -> checkReq "GET" "1.1" (without "sec-websocket-key" goodRequest ++ [ ( "sec-websocket-key", "AAAAAAAAAAAAAAAAAAAAAAAAAAA=" ) ]) |> Expect.equal (Err 400)
        , test "a key whose padding bits are set" <|
            \_ -> checkReq "GET" "1.1" (without "sec-websocket-key" goodRequest ++ [ ( "sec-websocket-key", "dGhlIHNhbXBsZSBub25jZR==" ) ]) |> Expect.equal (Err 400)
        , test "two keys" <| \_ -> checkReq "GET" "1.1" (goodRequest ++ [ ( "sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==" ) ]) |> Expect.equal (Err 400)
        , test "protocols over several headers" <|
            \_ -> checkReq "GET" "1.1" (goodRequest ++ [ ( "sec-websocket-protocol", "a, b" ), ( "sec-websocket-protocol", "c" ) ]) |> Expect.equal (Ok [ "a", "b", "c" ])
        , test "an invalid protocol" <| \_ -> checkReq "GET" "1.1" (goodRequest ++ [ ( "sec-websocket-protocol", "a b" ) ]) |> Expect.equal (Err 400)
        , test "an invalid extension header" <| \_ -> checkReq "GET" "1.1" (goodRequest ++ [ ( "sec-websocket-extensions", "x; =1" ) ]) |> Expect.equal (Err 400)
        , test "HTTP/2: an extended CONNECT" <|
            \_ ->
                H.checkRequest { method = "CONNECT", version = "2.0", headers = [ ( "sec-websocket-version", "13" ) ], isH2 = True }
                    |> Result.map .protocols
                    |> Expect.equal (Ok [])
        , test "HTTP/2: GET is refused" <|
            \_ ->
                H.checkRequest { method = "GET", version = "2.0", headers = [ ( "sec-websocket-version", "13" ) ], isH2 = True }
                    |> Result.mapError Tuple.first
                    |> Result.map .protocols
                    |> Expect.equal (Err 400)
        ]



-- RESPONSE HEADERS


responseHeaderTests : Test
responseHeaderTests =
    describe "responseHeaders"
        [ test "a 101" <|
            \_ ->
                H.responseHeaders { accept = accept, protocol = Just "chat", extensions = Nothing, headers = [ ( "X-A", "1" ) ], isH2 = False }
                    |> Expect.equal
                        (Ok
                            [ ( "Upgrade", "websocket" )
                            , ( "Connection", "Upgrade" )
                            , ( "Sec-WebSocket-Accept", accept )
                            , ( "Sec-WebSocket-Protocol", "chat" )
                            , ( "X-A", "1" )
                            ]
                        )
        , test "HTTP/2: no Upgrade, Connection or accept" <|
            \_ ->
                H.responseHeaders { accept = "", protocol = Nothing, extensions = Nothing, headers = [], isH2 = True }
                    |> Expect.equal (Ok [])
        , test "a reserved user header" <|
            \_ -> H.responseHeaders { accept = accept, protocol = Nothing, extensions = Nothing, headers = [ ( "Connection", "close" ) ], isH2 = False } |> Expect.err
        ]



-- EXTENSIONS (RFC 6455 §9.1)


extensionTests : Test
extensionTests =
    describe "parseExtensions"
        [ test "one extension with parameters" <|
            \_ ->
                H.parseExtensions [ "permessage-deflate; client_max_window_bits; server_max_window_bits=10" ]
                    |> Expect.equal
                        (Just
                            [ { name = "permessage-deflate"
                              , params = [ ( "client_max_window_bits", Nothing ), ( "server_max_window_bits", Just "10" ) ]
                              }
                            ]
                        )
        , test "several elements and headers, names lower-cased" <|
            \_ ->
                H.parseExtensions [ "A, b ; X=1", "c" ]
                    |> Maybe.map (List.map (\e -> ( e.name, e.params )))
                    |> Expect.equal (Just [ ( "a", [] ), ( "b", [ ( "x", Just "1" ) ] ), ( "c", [] ) ])
        , test "a quoted value is unescaped" <|
            \_ ->
                H.parseExtensions [ "x; a=\"1\\5\"" ]
                    |> Expect.equal (Just [ { name = "x", params = [ ( "a", Just "15" ) ] } ])
        , test "empty elements are ignored" <|
            \_ -> H.parseExtensions [ " , x ,, " ] |> Maybe.map (List.map .name) |> Expect.equal (Just [ "x" ])
        , test "no header" <| \_ -> H.parseExtensions [] |> Expect.equal (Just [])
        , test "a quoted value that is not a token" <| \_ -> H.parseExtensions [ "x; a=\"1,2\"" ] |> Expect.equal Nothing
        , test "a quoted value with a semicolon" <| \_ -> H.parseExtensions [ "x; a=\"1;b\"" ] |> Expect.equal Nothing
        , test "an unterminated quoted value" <| \_ -> H.parseExtensions [ "x; a=\"1" ] |> Expect.equal Nothing
        , test "a parameter without a name" <| \_ -> H.parseExtensions [ "x; =1" ] |> Expect.equal Nothing
        , test "a parameter without a value" <| \_ -> H.parseExtensions [ "x; a=" ] |> Expect.equal Nothing
        , test "a trailing semicolon" <| \_ -> H.parseExtensions [ "x;" ] |> Expect.equal Nothing
        , test "a leading semicolon" <| \_ -> H.parseExtensions [ "; x" ] |> Expect.equal Nothing
        , test "two words" <| \_ -> H.parseExtensions [ "x y" ] |> Expect.equal Nothing
        , test "an invalid character" <| \_ -> H.parseExtensions [ "x; a=1/2" ] |> Expect.equal Nothing
        , test "two headers do not run together" <|
            \_ -> H.parseExtensions [ "x", "y" ] |> Maybe.map (List.map .name) |> Expect.equal (Just [ "x", "y" ])
        ]



-- NEGOTIATION (RFC 7692 §7.1, Appendix D.7)


pmd : List ( String, Maybe String ) -> H.Extension
pmd params =
    { name = "permessage-deflate", params = params }


{-| Parse an offer header, then answer it with a policy.
-}
serverAnswer : { maxWindowBits : Int, contextTakeover : Bool } -> String -> Maybe ( H.Negotiated, String )
serverAnswer policy header =
    H.parseExtensions [ header ] |> Maybe.andThen (H.negotiateServer (Just policy))


defaultPolicy : { maxWindowBits : Int, contextTakeover : Bool }
defaultPolicy =
    { maxWindowBits = 15, contextTakeover = False }


takeoverPolicy : { maxWindowBits : Int, contextTakeover : Bool }
takeoverPolicy =
    { maxWindowBits = 15, contextTakeover = True }


defaultOffer : { clientMaxWindowBits : Maybe (Maybe Int), serverMaxWindowBits : Maybe Int, contextTakeover : Bool }
defaultOffer =
    { clientMaxWindowBits = Just Nothing, serverMaxWindowBits = Nothing, contextTakeover = False }


{-| Parse a response header and check it against an offer.
-}
clientAnswer : { clientMaxWindowBits : Maybe (Maybe Int), serverMaxWindowBits : Maybe Int, contextTakeover : Bool } -> String -> Result String (Maybe H.Negotiated)
clientAnswer offer header =
    case H.parseExtensions [ header ] of
        Just exts ->
            H.negotiateClient (Just offer) exts

        Nothing ->
            Err "grammar"


negotiationTests : Test
negotiationTests =
    describe "permessage-deflate negotiation"
        [ describe "client offers"
            [ test "the default offer" <|
                \_ ->
                    H.clientOffer defaultOffer
                        |> Expect.equal "permessage-deflate; client_no_context_takeover; server_no_context_takeover; client_max_window_bits"
            , test "context takeover, window sizes" <|
                \_ ->
                    H.clientOffer { clientMaxWindowBits = Just (Just 10), serverMaxWindowBits = Just 12, contextTakeover = True }
                        |> Expect.equal "permessage-deflate; client_max_window_bits=10; server_max_window_bits=12"
            , test "nothing about windows" <|
                \_ ->
                    H.clientOffer { clientMaxWindowBits = Nothing, serverMaxWindowBits = Nothing, contextTakeover = True }
                        |> Expect.equal "permessage-deflate"
            , test "window sizes are clamped" <|
                \_ ->
                    H.clientOffer { clientMaxWindowBits = Just (Just 20), serverMaxWindowBits = Just 3, contextTakeover = True }
                        |> Expect.equal "permessage-deflate; client_max_window_bits=15; server_max_window_bits=8"
            , test "the default offer is accepted by the default policy" <|
                \_ ->
                    serverAnswer defaultPolicy (H.clientOffer defaultOffer)
                        |> Maybe.map Tuple.second
                        |> Expect.equal (Just "permessage-deflate; server_no_context_takeover; client_no_context_takeover")
            ]
        , describe "server answers"
            [ test "a bare offer, default policy: no context takeover both ways" <|
                \_ ->
                    serverAnswer defaultPolicy "permessage-deflate"
                        |> Expect.equal
                            (Just
                                ( { serverNoContextTakeover = True, clientNoContextTakeover = True, serverMaxWindowBits = 15, clientMaxWindowBits = 15 }
                                , "permessage-deflate; server_no_context_takeover; client_no_context_takeover"
                                )
                            )
            , test "a bare offer, takeover policy: nothing restricted" <|
                \_ ->
                    serverAnswer takeoverPolicy "permessage-deflate"
                        |> Expect.equal
                            (Just
                                ( { serverNoContextTakeover = False, clientNoContextTakeover = False, serverMaxWindowBits = 15, clientMaxWindowBits = 15 }
                                , "permessage-deflate"
                                )
                            )
            , test "takeover policy: the client's restrictions are echoed" <|
                \_ ->
                    serverAnswer takeoverPolicy "permessage-deflate; server_no_context_takeover; client_no_context_takeover"
                        |> Maybe.map Tuple.second
                        |> Expect.equal (Just "permessage-deflate; server_no_context_takeover; client_no_context_takeover")
            , test "takeover policy: only server_no_context_takeover asked" <|
                \_ ->
                    serverAnswer takeoverPolicy "permessage-deflate; server_no_context_takeover"
                        |> Maybe.map (\( n, h ) -> ( n.serverNoContextTakeover, n.clientNoContextTakeover, h ))
                        |> Expect.equal (Just ( True, False, "permessage-deflate; server_no_context_takeover" ))
            , test "server_max_window_bits: the smaller of offer and policy" <|
                \_ ->
                    serverAnswer { maxWindowBits = 12, contextTakeover = True } "permessage-deflate; server_max_window_bits=10"
                        |> Maybe.map (\( n, h ) -> ( n.serverMaxWindowBits, h ))
                        |> Expect.equal (Just ( 10, "permessage-deflate; server_max_window_bits=10" ))
            , test "a policy below 15 bits is announced unasked" <|
                \_ ->
                    serverAnswer { maxWindowBits = 9, contextTakeover = True } "permessage-deflate; server_max_window_bits=12"
                        |> Maybe.map Tuple.second
                        |> Expect.equal (Just "permessage-deflate; server_max_window_bits=9")
            , test "window bits 8 offered: answered 8 (deflated with 9)" <|
                \_ ->
                    serverAnswer takeoverPolicy "permessage-deflate; server_max_window_bits=8"
                        |> Maybe.map (\( n, h ) -> ( n.serverMaxWindowBits, h ))
                        |> Expect.equal (Just ( 8, "permessage-deflate; server_max_window_bits=8" ))
            , test "client_max_window_bits without a value: never answered" <|
                \_ ->
                    serverAnswer takeoverPolicy "permessage-deflate; client_max_window_bits"
                        |> Expect.equal
                            (Just
                                ( { serverNoContextTakeover = False, clientNoContextTakeover = False, serverMaxWindowBits = 15, clientMaxWindowBits = 15 }
                                , "permessage-deflate"
                                )
                            )
            , test "client_max_window_bits with a value: recorded, not answered" <|
                \_ ->
                    serverAnswer takeoverPolicy "permessage-deflate; client_max_window_bits=9"
                        |> Maybe.map (\( n, h ) -> ( n.clientMaxWindowBits, h ))
                        |> Expect.equal (Just ( 9, "permessage-deflate" ))
            , test "quoted values" <|
                \_ ->
                    serverAnswer takeoverPolicy "permessage-deflate; server_max_window_bits=\"10\"; client_max_window_bits=\"11\""
                        |> Maybe.map (\( n, h ) -> ( n.serverMaxWindowBits, n.clientMaxWindowBits, h ))
                        |> Expect.equal (Just ( 10, 11, "permessage-deflate; server_max_window_bits=10" ))
            , test "a leading zero declines the offer" <|
                \_ -> serverAnswer defaultPolicy "permessage-deflate; server_max_window_bits=010" |> Expect.equal Nothing
            , test "a quoted leading zero declines the offer" <|
                \_ -> serverAnswer defaultPolicy "permessage-deflate; client_max_window_bits=\"09\"" |> Expect.equal Nothing
            , test "a window size out of range declines the offer" <|
                \_ -> serverAnswer defaultPolicy "permessage-deflate; server_max_window_bits=16" |> Expect.equal Nothing
            , test "window size 7 declines the offer" <|
                \_ -> serverAnswer defaultPolicy "permessage-deflate; client_max_window_bits=7" |> Expect.equal Nothing
            , test "server_max_window_bits without a value declines the offer" <|
                \_ -> serverAnswer defaultPolicy "permessage-deflate; server_max_window_bits" |> Expect.equal Nothing
            , test "a value on a context takeover parameter declines the offer" <|
                \_ -> serverAnswer defaultPolicy "permessage-deflate; server_no_context_takeover=1" |> Expect.equal Nothing
            , test "a repeated parameter declines the offer" <|
                \_ -> serverAnswer defaultPolicy "permessage-deflate; client_no_context_takeover; client_no_context_takeover" |> Expect.equal Nothing
            , test "an unknown parameter declines the offer" <|
                \_ -> serverAnswer defaultPolicy "permessage-deflate; x_foo" |> Expect.equal Nothing
            , test "a declined offer falls back to the next one" <|
                \_ ->
                    serverAnswer takeoverPolicy "permessage-deflate; server_max_window_bits=99, permessage-deflate; client_max_window_bits"
                        |> Maybe.map Tuple.second
                        |> Expect.equal (Just "permessage-deflate")
            , test "the first acceptable offer wins" <|
                \_ ->
                    serverAnswer takeoverPolicy "permessage-deflate; server_max_window_bits=10, permessage-deflate"
                        |> Maybe.map Tuple.second
                        |> Expect.equal (Just "permessage-deflate; server_max_window_bits=10")
            , test "other extensions are skipped" <|
                \_ ->
                    serverAnswer defaultPolicy "x-webkit-deflate-frame, permessage-deflate"
                        |> Maybe.map (Tuple.first >> .serverNoContextTakeover)
                        |> Expect.equal (Just True)
            , test "no permessage-deflate offer" <|
                \_ -> serverAnswer defaultPolicy "x-webkit-deflate-frame" |> Expect.equal Nothing
            , test "no compression policy declines everything" <|
                \_ -> H.negotiateServer Nothing [ pmd [] ] |> Expect.equal Nothing
            ]
        , describe "client checks"
            [ test "nothing offered, nothing returned" <|
                \_ -> H.negotiateClient Nothing [] |> Expect.equal (Ok Nothing)
            , test "nothing offered, an extension returned" <|
                \_ -> H.negotiateClient Nothing [ pmd [] ] |> Expect.err
            , test "offered, declined" <|
                \_ -> H.negotiateClient (Just defaultOffer) [] |> Expect.equal (Ok Nothing)
            , test "the default answer to the default offer" <|
                \_ ->
                    clientAnswer defaultOffer "permessage-deflate; server_no_context_takeover; client_no_context_takeover"
                        |> Expect.equal (Ok (Just { serverNoContextTakeover = True, clientNoContextTakeover = True, serverMaxWindowBits = 15, clientMaxWindowBits = 15 }))
            , test "the server takes over context although asked not to: accepted" <|
                \_ ->
                    clientAnswer defaultOffer "permessage-deflate"
                        |> Expect.equal (Ok (Just { serverNoContextTakeover = False, clientNoContextTakeover = True, serverMaxWindowBits = 15, clientMaxWindowBits = 15 }))
            , test "takeover offered, the server restricts the client" <|
                \_ ->
                    clientAnswer { defaultOffer | contextTakeover = True } "permessage-deflate; client_no_context_takeover"
                        |> Result.map (Maybe.map .clientNoContextTakeover)
                        |> Expect.equal (Ok (Just True))
            , test "takeover offered and agreed" <|
                \_ ->
                    clientAnswer { defaultOffer | contextTakeover = True } "permessage-deflate"
                        |> Result.map (Maybe.map (\n -> ( n.serverNoContextTakeover, n.clientNoContextTakeover )))
                        |> Expect.equal (Ok (Just ( False, False )))
            , test "client_max_window_bits answered (offered without a value)" <|
                \_ ->
                    clientAnswer defaultOffer "permessage-deflate; client_max_window_bits=10"
                        |> Result.map (Maybe.map .clientMaxWindowBits)
                        |> Expect.equal (Ok (Just 10))
            , test "client_max_window_bits: our own smaller hint is kept" <|
                \_ ->
                    clientAnswer { defaultOffer | clientMaxWindowBits = Just (Just 9) } "permessage-deflate; client_max_window_bits=12"
                        |> Result.map (Maybe.map .clientMaxWindowBits)
                        |> Expect.equal (Ok (Just 9))
            , test "client_max_window_bits not offered" <|
                \_ -> clientAnswer { defaultOffer | clientMaxWindowBits = Nothing } "permessage-deflate; client_max_window_bits=10" |> Expect.err
            , test "client_max_window_bits without a value in a response" <|
                \_ -> clientAnswer defaultOffer "permessage-deflate; client_max_window_bits" |> Expect.err
            , test "server_max_window_bits within our limit" <|
                \_ ->
                    clientAnswer { defaultOffer | serverMaxWindowBits = Just 10 } "permessage-deflate; server_max_window_bits=9"
                        |> Result.map (Maybe.map .serverMaxWindowBits)
                        |> Expect.equal (Ok (Just 9))
            , test "server_max_window_bits above our limit" <|
                \_ -> clientAnswer { defaultOffer | serverMaxWindowBits = Just 10 } "permessage-deflate; server_max_window_bits=11" |> Expect.err
            , test "server_max_window_bits unasked" <|
                \_ ->
                    clientAnswer defaultOffer "permessage-deflate; server_max_window_bits=12"
                        |> Result.map (Maybe.map .serverMaxWindowBits)
                        |> Expect.equal (Ok (Just 12))
            , test "a quoted value" <|
                \_ ->
                    clientAnswer defaultOffer "permessage-deflate; server_max_window_bits=\"12\""
                        |> Result.map (Maybe.map .serverMaxWindowBits)
                        |> Expect.equal (Ok (Just 12))
            , test "a leading zero" <|
                \_ -> clientAnswer defaultOffer "permessage-deflate; server_max_window_bits=012" |> Expect.err
            , test "a duplicate parameter" <|
                \_ -> clientAnswer defaultOffer "permessage-deflate; server_no_context_takeover; server_no_context_takeover" |> Expect.err
            , test "an unknown parameter" <|
                \_ -> clientAnswer defaultOffer "permessage-deflate; foo=1" |> Expect.err
            , test "another extension" <|
                \_ -> clientAnswer defaultOffer "x-other" |> Expect.err
            , test "two answers" <|
                \_ -> clientAnswer defaultOffer "permessage-deflate, permessage-deflate" |> Expect.err
            ]
        ]
