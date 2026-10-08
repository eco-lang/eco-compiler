module WebSocket.Internal.Handshake exposing
    ( Url, Host(..), parseUrl, hostHeader, serverName
    , tokenList, headerTokens, headerValues, isToken
    , requestHeaders, checkResponse, checkRequest, responseHeaders
    , Extension, parseExtensions, Negotiated, ClientOffer, ServerPolicy
    , clientOffer, negotiateClient, negotiateServer
    )

{-| Internal; not exposed. The WebSocket opening handshake in pure Elm (elm/core and
`Socket.Address` only, plans/eco-system-websockets.md §3.1, §3.6, Appendix D.2, D.3, D.7).

  - URLs: [`parseUrl`](#parseUrl), [`hostHeader`](#hostHeader), [`serverName`](#serverName).
  - Header grammar: comma-separated token lists, RFC 9110 tokens, the extension header.
  - Handshake: the client request headers, the checks of a response (client) and of a request
    (server), the server's response headers.
  - permessage-deflate negotiation (RFC 7692 §7.1) in both roles.

The URL parser, the `Host` header, the token grammar, the handshake checks of Appendix D.2/D.3 and
the extension header grammar (RFC 6455 §9.1: comma-separated elements, `;` parameters, token or
quoted-string values) are phase WS4's; the permessage-deflate negotiation (RFC 7692 §7.1,
Appendix D.7) is WS7's.

-}

import Socket.Address as Address exposing (Address, Family(..))



-- URLS


{-| A parsed WebSocket URL.

  - `secure`: `wss` (TLS) rather than `ws`.
  - `host`: a host name (lower-cased) or an address literal (an IPv6 literal may carry a zone).
  - `port_`: the port, 80 or 443 when the URL has none.
  - `target`: the request target: the path (`/` when empty) and the query, if any.

-}
type alias Url =
    { secure : Bool
    , host : Host
    , port_ : Int
    , target : String
    }


{-| The host of a URL.
-}
type Host
    = Name String
    | Literal Address


{-| Parse a `ws://` or `wss://` URL. The scheme is case-insensitive; IPv6 literals are bracketed
and may carry a zone written `%25` (RFC 6874: `ws://[fe80::1%25eth0]/`); a port is 0 to 65535;
the query is kept. A fragment, user information, another scheme or characters outside printable
ASCII are errors. The error is a message for an `EINVAL` error.
-}
parseUrl : String -> Result String Url
parseUrl text =
    case String.indexes "://" text of
        [] ->
            Err ("invalid WebSocket URL " ++ text ++ ": missing scheme")

        i :: _ ->
            let
                scheme =
                    String.toLower (String.left i text)

                rest =
                    String.dropLeft (i + 3) text
            in
            if scheme /= "ws" && scheme /= "wss" then
                Err ("invalid WebSocket URL " ++ text ++ ": the scheme must be ws or wss")

            else if String.contains "#" rest then
                Err ("invalid WebSocket URL " ++ text ++ ": fragments are not allowed")

            else if not (String.all isUrlChar rest) then
                Err ("invalid WebSocket URL " ++ text ++ ": invalid character")

            else
                let
                    authorityEnd =
                        firstIndex [ "/", "?" ] rest |> Maybe.withDefault (String.length rest)

                    authority =
                        String.left authorityEnd rest

                    remainder =
                        String.dropLeft authorityEnd rest

                    secure =
                        scheme == "wss"

                    target =
                        if remainder == "" then
                            "/"

                        else if String.startsWith "?" remainder then
                            "/" ++ remainder

                        else
                            remainder
                in
                parseAuthority secure authority
                    |> Result.map (\( host, port_ ) -> { secure = secure, host = host, port_ = port_, target = target })
                    |> Result.mapError (\reason -> "invalid WebSocket URL " ++ text ++ ": " ++ reason)


firstIndex : List String -> String -> Maybe Int
firstIndex needles text =
    needles
        |> List.filterMap (\needle -> List.head (String.indexes needle text))
        |> List.minimum


{-| Printable ASCII without space (RFC 3986 characters; anything else must be percent-encoded).
-}
isUrlChar : Char -> Bool
isUrlChar c =
    let
        code =
            Char.toCode c
    in
    code > 0x20 && code < 0x7F


parseAuthority : Bool -> String -> Result String ( Host, Int )
parseAuthority secure authority =
    if String.contains "@" authority then
        Err "user information is not allowed"

    else if String.startsWith "[" authority then
        case String.indexes "]" authority of
            close :: _ ->
                let
                    inside =
                        String.slice 1 close authority

                    after =
                        String.dropLeft (close + 1) authority
                in
                case ( Address.fromString (String.replace "%25" "%" inside), after ) of
                    ( Just address, "" ) ->
                        if Address.family address == IPv6 then
                            Ok ( Literal address, defaultPort secure )

                        else
                            Err "only IPv6 addresses are bracketed"

                    ( Just address, _ ) ->
                        if Address.family address /= IPv6 then
                            Err "only IPv6 addresses are bracketed"

                        else if String.startsWith ":" after then
                            parsePort secure (String.dropLeft 1 after)
                                |> Result.map (\p -> ( Literal address, p ))

                        else
                            Err "invalid host"

                    ( Nothing, _ ) ->
                        Err "invalid IPv6 address"

            [] ->
                Err "invalid IPv6 address"

    else
        let
            ( hostText, portResult ) =
                case String.indexes ":" authority of
                    [] ->
                        ( authority, Ok (defaultPort secure) )

                    [ colon ] ->
                        ( String.left colon authority, parsePort secure (String.dropLeft (colon + 1) authority) )

                    _ ->
                        ( authority, Err "IPv6 addresses must be bracketed" )
        in
        if hostText == "" then
            Err "missing host"

        else
            portResult
                |> Result.andThen
                    (\p ->
                        case Address.fromString hostText of
                            Just address ->
                                Ok ( Literal address, p )

                            Nothing ->
                                if String.all isRegNameChar hostText then
                                    Ok ( Name (String.toLower hostText), p )

                                else
                                    Err "invalid host"
                    )


{-| RFC 3986 reg-name characters (unreserved, sub-delims, and `%` of a percent-encoding).
-}
isRegNameChar : Char -> Bool
isRegNameChar c =
    Char.isAlphaNum c || String.contains (String.fromChar c) "-._~!$&'()*+,;=%"


parsePort : Bool -> String -> Result String Int
parsePort secure text =
    if text == "" then
        Ok (defaultPort secure)

    else if String.length text <= 5 && String.all Char.isDigit text then
        case String.toInt text of
            Just p ->
                if p <= 65535 then
                    Ok p

                else
                    Err "invalid port"

            Nothing ->
                Err "invalid port"

    else
        Err "invalid port"


defaultPort : Bool -> Int
defaultPort secure =
    if secure then
        443

    else
        80


{-| The `Host` header of a URL: the host, and `:port` unless it is the scheme's default port.
IPv6 literals are bracketed, without their zone.
-}
hostHeader : Url -> String
hostHeader url =
    let
        host =
            case url.host of
                Name name ->
                    name

                Literal address ->
                    case Address.family address of
                        IPv4 ->
                            Address.toString address

                        IPv6 ->
                            "[" ++ withoutZone address ++ "]"
    in
    if url.port_ == defaultPort url.secure then
        host

    else
        host ++ ":" ++ String.fromInt url.port_


{-| The TLS server name of a `wss` URL: the host name, or the address literal without a zone.
-}
serverName : Url -> String
serverName url =
    case url.host of
        Name name ->
            name

        Literal address ->
            withoutZone address


withoutZone : Address -> String
withoutZone address =
    Address.toString address
        |> String.split "%"
        |> List.head
        |> Maybe.withDefault ""



-- HEADER GRAMMAR


{-| The elements of a comma-separated header value, trimmed and lower-cased, empty ones dropped
(`"keep-alive, Upgrade"` → `[ "keep-alive", "upgrade" ]`).
-}
tokenList : String -> List String
tokenList value =
    value
        |> String.split ","
        |> List.map (String.trim >> String.toLower)
        |> List.filter ((/=) "")


{-| The lower-cased elements of every occurrence of a header (`name` lower-case).
-}
headerTokens : String -> List ( String, String ) -> List String
headerTokens name headers =
    headerValues name headers
        |> List.concatMap tokenList


{-| The values of every occurrence of a header, in order (`name` lower-case; header names are
compared case-insensitively).
-}
headerValues : String -> List ( String, String ) -> List String
headerValues name headers =
    headers
        |> List.filter (\( n, _ ) -> String.toLower n == name)
        |> List.map Tuple.second


{-| An RFC 9110 token: one or more of the letters, digits and ``!#$%&'*+-.^_`|~``.
-}
isToken : String -> Bool
isToken text =
    text /= "" && String.all isTokenChar text


isTokenChar : Char -> Bool
isTokenChar c =
    Char.toCode c < 0x80 && (Char.isAlphaNum c || String.contains (String.fromChar c) "!#$%&'*+-.^_`|~")


{-| A header name and value a user may send: the name a token, the value without CR, LF or NUL.
-}
isValidHeader : ( String, String ) -> Bool
isValidHeader ( name, value ) =
    isToken name && not (String.any (\c -> c == '\u{000D}' || c == '\n' || c == '\u{0000}') value)


{-| Header names the handshake sets itself; a user header with one of these names is an error.
-}
reservedNames : List String
reservedNames =
    [ "host"
    , "upgrade"
    , "connection"
    , "sec-websocket-key"
    , "sec-websocket-version"
    , "sec-websocket-accept"
    , "sec-websocket-protocol"
    , "sec-websocket-extensions"
    , "content-length"
    , "transfer-encoding"
    ]


checkUserHeaders : List ( String, String ) -> Result String ()
checkUserHeaders headers =
    case List.filter (\(( name, _ ) as h) -> not (isValidHeader h) || List.member (String.toLower name) reservedNames) headers of
        [] ->
            Ok ()

        ( name, _ ) :: _ ->
            Err ("invalid or reserved header " ++ name)



-- HANDSHAKE (Appendix D.2, D.3)


{-| The headers of a client's opening request (D.2), in order, after the request line
`GET <target> HTTP/1.1`. Fails (an `EINVAL` message) for a protocol that is not a token, a
repeated protocol, or an invalid or reserved user header.
-}
requestHeaders :
    { host : String, key : String, protocols : List String, extensions : Maybe String, headers : List ( String, String ) }
    -> Result String (List ( String, String ))
requestHeaders r =
    if not (List.all isToken r.protocols) then
        Err "invalid WebSocket protocol name"

    else if hasDuplicates r.protocols then
        Err "duplicate WebSocket protocol name"

    else
        checkUserHeaders r.headers
            |> Result.map
                (\_ ->
                    [ ( "Host", r.host )
                    , ( "Upgrade", "websocket" )
                    , ( "Connection", "Upgrade" )
                    , ( "Sec-WebSocket-Key", r.key )
                    , ( "Sec-WebSocket-Version", "13" )
                    ]
                        ++ (if List.isEmpty r.protocols then
                                []

                            else
                                [ ( "Sec-WebSocket-Protocol", String.join ", " r.protocols ) ]
                           )
                        ++ (case r.extensions of
                                Just offer ->
                                    [ ( "Sec-WebSocket-Extensions", offer ) ]

                                Nothing ->
                                    []
                           )
                        ++ r.headers
                )


hasDuplicates : List String -> Bool
hasDuplicates list =
    case list of
        [] ->
            False

        x :: rest ->
            List.member x rest || hasDuplicates rest


{-| Check a server's response to our opening request (D.2). On failure, the HTTP status when it
was not 101, and a message for an `ERR_WS_HANDSHAKE` error. On success, the protocol the server
chose and the extensions it returned.
-}
checkResponse :
    { expectedAccept : String, protocols : List String, isH2 : Bool }
    -> Int
    -> List ( String, String )
    -> Result ( Maybe Int, String ) { protocol : Maybe String, extensions : List Extension }
checkResponse expected status headers =
    let
        statusOk =
            if expected.isH2 then
                status >= 200 && status < 300

            else
                status == 101

        protocols =
            headerValues "sec-websocket-protocol" headers
    in
    if not statusOk then
        Err ( Just status, "unexpected response status " ++ String.fromInt status )

    else if not expected.isH2 && not (List.member "websocket" (headerTokens "upgrade" headers)) then
        Err ( Nothing, "the response has no Upgrade: websocket" )

    else if not expected.isH2 && not (List.member "upgrade" (headerTokens "connection" headers)) then
        Err ( Nothing, "the response has no Connection: upgrade" )

    else if not expected.isH2 && List.map String.trim (headerValues "sec-websocket-accept" headers) /= [ expected.expectedAccept ] then
        Err ( Nothing, "wrong Sec-WebSocket-Accept" )

    else
        case protocols of
            [] ->
                parseExtensions (headerValues "sec-websocket-extensions" headers)
                    |> Result.fromMaybe ( Nothing, "invalid Sec-WebSocket-Extensions" )
                    |> Result.map (\exts -> { protocol = Nothing, extensions = exts })

            [ chosen ] ->
                if List.member (String.trim chosen) expected.protocols then
                    parseExtensions (headerValues "sec-websocket-extensions" headers)
                        |> Result.fromMaybe ( Nothing, "invalid Sec-WebSocket-Extensions" )
                        |> Result.map (\exts -> { protocol = Just (String.trim chosen), extensions = exts })

                else
                    Err ( Nothing, "the server chose a protocol that was not offered: " ++ chosen )

            _ ->
                Err ( Nothing, "more than one Sec-WebSocket-Protocol in the response" )


{-| Check a client's opening request (D.3): `headers` with lower-case names. On failure, the status
to answer (400, or 426 for a version other than 13) and a message. On success, the client's key
(empty over HTTP/2), its protocols in order, and its extension offers.
-}
checkRequest :
    { method : String, version : String, headers : List ( String, String ), isH2 : Bool }
    -> Result ( Int, String ) { key : String, protocols : List String, extensions : List Extension }
checkRequest r =
    let
        keys =
            headerValues "sec-websocket-key" r.headers |> List.map String.trim

        versions =
            headerValues "sec-websocket-version" r.headers |> List.map String.trim

        protocols =
            headerValues "sec-websocket-protocol" r.headers
                |> List.concatMap (String.split ",")
                |> List.map String.trim
                |> List.filter ((/=) "")

        extensions =
            parseExtensions (headerValues "sec-websocket-extensions" r.headers)
    in
    if r.isH2 && r.method /= "CONNECT" then
        Err ( 400, "a WebSocket over HTTP/2 needs an extended CONNECT" )

    else if not r.isH2 && r.method /= "GET" then
        Err ( 400, "the opening request must be a GET" )

    else if not r.isH2 && not (atLeastHttp11 r.version) then
        Err ( 400, "the opening request needs HTTP/1.1 or later" )

    else if not r.isH2 && List.isEmpty (headerValues "host" r.headers) then
        Err ( 400, "missing Host" )

    else if not r.isH2 && not (List.member "websocket" (headerTokens "upgrade" r.headers)) then
        Err ( 400, "missing Upgrade: websocket" )

    else if not r.isH2 && not (List.member "upgrade" (headerTokens "connection" r.headers)) then
        Err ( 400, "missing Connection: upgrade" )

    else if versions /= [ "13" ] then
        Err ( 426, "unsupported Sec-WebSocket-Version" )

    else if not r.isH2 && not (List.length keys == 1 && List.all isKey keys) then
        Err ( 400, "invalid Sec-WebSocket-Key" )

    else if not (List.all isToken protocols) then
        Err ( 400, "invalid Sec-WebSocket-Protocol" )

    else
        case extensions of
            Just exts ->
                Ok { key = List.head keys |> Maybe.withDefault "", protocols = protocols, extensions = exts }

            Nothing ->
                Err ( 400, "invalid Sec-WebSocket-Extensions" )


{-| An HTTP version (`"1.1"`, from `HTTP/1.1`) of 1.1 or later.
-}
atLeastHttp11 : String -> Bool
atLeastHttp11 version =
    case String.split "." version |> List.map String.toInt of
        [ Just major, Just minor ] ->
            major > 1 || (major == 1 && minor >= 1)

        _ ->
            False


{-| The base64 encoding of 16 bytes: 22 base64 characters (the last one with its low four bits
zero) and `==`.
-}
isKey : String -> Bool
isKey key =
    String.length key
        == 24
        && String.endsWith "==" key
        && String.all isBase64Char (String.left 22 key)
        && String.contains (String.slice 21 22 key) "AQgw"


isBase64Char : Char -> Bool
isBase64Char c =
    Char.toCode c < 0x80 && (Char.isAlphaNum c || c == '+' || c == '/')


{-| The headers of a server's answer to an accepted opening request (101, or 200 over HTTP/2),
after its status line. Fails (an `EINVAL` message) for an invalid or reserved user header.
-}
responseHeaders :
    { accept : String, protocol : Maybe String, extensions : Maybe String, headers : List ( String, String ), isH2 : Bool }
    -> Result String (List ( String, String ))
responseHeaders r =
    checkUserHeaders r.headers
        |> Result.map
            (\_ ->
                (if r.isH2 then
                    []

                 else
                    [ ( "Upgrade", "websocket" )
                    , ( "Connection", "Upgrade" )
                    , ( "Sec-WebSocket-Accept", r.accept )
                    ]
                )
                    ++ (case r.protocol of
                            Just p ->
                                [ ( "Sec-WebSocket-Protocol", p ) ]

                            Nothing ->
                                []
                       )
                    ++ (case r.extensions of
                            Just e ->
                                [ ( "Sec-WebSocket-Extensions", e ) ]

                            Nothing ->
                                []
                       )
                    ++ r.headers
            )



-- EXTENSIONS (RFC 6455 §9.1, RFC 7692 §7.1, Appendix D.7)


{-| One element of a `Sec-WebSocket-Extensions` header: the extension name (lower-cased) and its
parameters in order (names lower-cased; values unquoted).
-}
type alias Extension =
    { name : String
    , params : List ( String, Maybe String )
    }


{-| Parse every occurrence of a `Sec-WebSocket-Extensions` header, in order; `Nothing` when the
grammar is violated (RFC 6455 §9.1):

    extension-list = 1#extension
    extension      = token *( OWS ";" OWS token [ "=" ( token / quoted-string ) ] )

Empty list elements are ignored (RFC 9110 §5.6.1). A quoted value is unescaped and must then be a
token. Extension and parameter names are lower-cased; values are kept as written.

-}
parseExtensions : List String -> Maybe (List Extension)
parseExtensions values =
    values
        |> List.map (String.toList >> lexExtensions [])
        |> combine
        |> Maybe.map (List.intersperse [ XComma ] >> List.concat)
        |> Maybe.andThen (splitOn XComma >> List.filter (not << List.isEmpty) >> List.map parseExtension >> combine)


type XToken
    = XWord String
    | XQuoted String
    | XComma
    | XSemi
    | XEquals


lexExtensions : List XToken -> List Char -> Maybe (List XToken)
lexExtensions acc chars =
    case chars of
        [] ->
            Just (List.reverse acc)

        c :: rest ->
            if c == ' ' || c == '\t' then
                lexExtensions acc rest

            else if c == ',' then
                lexExtensions (XComma :: acc) rest

            else if c == ';' then
                lexExtensions (XSemi :: acc) rest

            else if c == '=' then
                lexExtensions (XEquals :: acc) rest

            else if c == '"' then
                lexQuoted [] rest
                    |> Maybe.andThen (\( value, after ) -> lexExtensions (XQuoted value :: acc) after)

            else if isTokenChar c then
                let
                    word =
                        takeWhile isTokenChar chars
                in
                lexExtensions (XWord (String.fromList word) :: acc) (List.drop (List.length word) chars)

            else
                Nothing


{-| The rest of a quoted-string after its opening quote: its unescaped value and what follows the
closing quote.
-}
lexQuoted : List Char -> List Char -> Maybe ( String, List Char )
lexQuoted acc chars =
    case chars of
        '"' :: rest ->
            Just ( String.fromList (List.reverse acc), rest )

        '\\' :: c :: rest ->
            lexQuoted (c :: acc) rest

        c :: rest ->
            let
                code =
                    Char.toCode c
            in
            if (code < 0x20 && c /= '\t') || code == 0x7F then
                Nothing

            else
                lexQuoted (c :: acc) rest

        [] ->
            Nothing


takeWhile : (a -> Bool) -> List a -> List a
takeWhile ok list =
    case list of
        x :: rest ->
            if ok x then
                x :: takeWhile ok rest

            else
                []

        [] ->
            []


splitOn : XToken -> List XToken -> List (List XToken)
splitOn separator tokens =
    List.foldr
        (\t groups ->
            if t == separator then
                [] :: groups

            else
                case groups of
                    g :: rest ->
                        (t :: g) :: rest

                    [] ->
                        [ [ t ] ]
        )
        [ [] ]
        tokens


parseExtension : List XToken -> Maybe Extension
parseExtension tokens =
    case tokens of
        (XWord name) :: params ->
            parseParams [] params
                |> Maybe.map (\ps -> { name = String.toLower name, params = ps })

        _ ->
            Nothing


parseParams : List ( String, Maybe String ) -> List XToken -> Maybe (List ( String, Maybe String ))
parseParams acc tokens =
    case tokens of
        [] ->
            Just (List.reverse acc)

        XSemi :: (XWord name) :: XEquals :: (XWord value) :: rest ->
            parseParams (( String.toLower name, Just value ) :: acc) rest

        XSemi :: (XWord name) :: XEquals :: (XQuoted value) :: rest ->
            if isToken value then
                parseParams (( String.toLower name, Just value ) :: acc) rest

            else
                Nothing

        XSemi :: (XWord name) :: rest ->
            case rest of
                XEquals :: _ ->
                    Nothing

                _ ->
                    parseParams (( String.toLower name, Nothing ) :: acc) rest

        _ ->
            Nothing


combine : List (Maybe a) -> Maybe (List a)
combine list =
    List.foldr (Maybe.map2 (::)) (Just []) list


{-| The parameters of a negotiated permessage-deflate (the same record as
`WebSocket.Negotiated`).
-}
type alias Negotiated =
    { serverNoContextTakeover : Bool
    , clientNoContextTakeover : Bool
    , serverMaxWindowBits : Int
    , clientMaxWindowBits : Int
    }


{-| What a client offers (the fields of `WebSocket.ClientCompression` the offer depends on).
-}
type alias ClientOffer r =
    { r
        | clientMaxWindowBits : Maybe (Maybe Int)
        , serverMaxWindowBits : Maybe Int
        , contextTakeover : Bool
    }


{-| A server's policy (the fields of `WebSocket.ServerCompression` the negotiation depends on).
-}
type alias ServerPolicy r =
    { r | maxWindowBits : Int, contextTakeover : Bool }


{-| The `Sec-WebSocket-Extensions` value of a client's permessage-deflate offer: without context
takeover (the default) `client_no_context_takeover` and `server_no_context_takeover`, then
`client_max_window_bits` (without a value for `Just Nothing`) and `server_max_window_bits` as asked
(window sizes are clamped to 8–15).
-}
clientOffer : ClientOffer r -> String
clientOffer offer =
    String.join "; "
        ([ "permessage-deflate" ]
            ++ (if offer.contextTakeover then
                    []

                else
                    [ "client_no_context_takeover", "server_no_context_takeover" ]
               )
            ++ (case offer.clientMaxWindowBits of
                    Just (Just bits) ->
                        [ "client_max_window_bits=" ++ String.fromInt (clamp 8 15 bits) ]

                    Just Nothing ->
                        [ "client_max_window_bits" ]

                    Nothing ->
                        []
               )
            ++ (case offer.serverMaxWindowBits of
                    Just bits ->
                        [ "server_max_window_bits=" ++ String.fromInt (clamp 8 15 bits) ]

                    Nothing ->
                        []
               )
        )


{-| The parameters of one permessage-deflate element (RFC 7692 §7.1).
-}
type alias DeflateParams =
    { serverNoContextTakeover : Bool
    , clientNoContextTakeover : Bool
    , serverMaxWindowBits : Maybe Int
    , clientMaxWindowBits : Maybe (Maybe Int)
    }


{-| Read the parameters of a permessage-deflate offer (`forResponse = False`) or response (`True`).
`Nothing` when a parameter is unknown or repeated, or has an invalid value: the context takeover
parameters take no value; window sizes are decimal numbers from 8 to 15 without leading zeros
(possibly quoted: the extension grammar already unquoted them); `client_max_window_bits` may come
without a value in an offer only.
-}
deflateParams : Bool -> List ( String, Maybe String ) -> Maybe DeflateParams
deflateParams forResponse params =
    if hasDuplicates (List.map Tuple.first params) then
        Nothing

    else
        List.foldl
            (\( name, value ) acc -> Maybe.andThen (addDeflateParam forResponse name value) acc)
            (Just { serverNoContextTakeover = False, clientNoContextTakeover = False, serverMaxWindowBits = Nothing, clientMaxWindowBits = Nothing })
            params


addDeflateParam : Bool -> String -> Maybe String -> DeflateParams -> Maybe DeflateParams
addDeflateParam forResponse name value ps =
    case ( name, value ) of
        ( "server_no_context_takeover", Nothing ) ->
            Just { ps | serverNoContextTakeover = True }

        ( "client_no_context_takeover", Nothing ) ->
            Just { ps | clientNoContextTakeover = True }

        ( "server_max_window_bits", Just v ) ->
            windowBits v |> Maybe.map (\b -> { ps | serverMaxWindowBits = Just b })

        ( "client_max_window_bits", Nothing ) ->
            if forResponse then
                Nothing

            else
                Just { ps | clientMaxWindowBits = Just Nothing }

        ( "client_max_window_bits", Just v ) ->
            windowBits v |> Maybe.map (\b -> { ps | clientMaxWindowBits = Just (Just b) })

        _ ->
            Nothing


{-| A window size: 1*DIGIT without leading zeros, from 8 to 15.
-}
windowBits : String -> Maybe Int
windowBits v =
    if v /= "" && String.all Char.isDigit v && not (String.startsWith "0" v) then
        String.toInt v
            |> Maybe.andThen
                (\n ->
                    if n >= 8 && n <= 15 then
                        Just n

                    else
                        Nothing
                )

    else
        Nothing


{-| Client side: the extensions a server returned, checked against our offer (`Nothing` when we
offered nothing). `Ok Nothing`: no compression; an error message fails the connection (RFC 7692
§7: the client fails the connection on an invalid response).

The response may contain one `permessage-deflate` element, with: `server_no_context_takeover` and
`client_no_context_takeover` (always allowed), `server_max_window_bits` (at most the value we asked
for, if we did), `client_max_window_bits` with a value (only if we offered it). Anything else,
another extension, a repeated or unknown parameter, or an invalid value is an error.

The result describes what each side does: our compressor resets after every message when the server
asked (`client_no_context_takeover`) or when we offered not to take over context; it uses the
smaller of our window size and the server's limit.

-}
negotiateClient : Maybe (ClientOffer r) -> List Extension -> Result String (Maybe Negotiated)
negotiateClient offer returned =
    case ( offer, returned ) of
        ( _, [] ) ->
            Ok Nothing

        ( Nothing, ext :: _ ) ->
            Err ("the server returned an extension that was not offered: " ++ ext.name)

        ( Just o, [ ext ] ) ->
            if ext.name /= "permessage-deflate" then
                Err ("the server returned an extension that was not offered: " ++ ext.name)

            else
                case deflateParams True ext.params of
                    Nothing ->
                        Err "the server returned invalid permessage-deflate parameters"

                    Just r ->
                        case ( r.clientMaxWindowBits, o.clientMaxWindowBits ) of
                            ( Just _, Nothing ) ->
                                Err "the server returned client_max_window_bits, which was not offered"

                            _ ->
                                case ( o.serverMaxWindowBits, r.serverMaxWindowBits ) of
                                    ( Just mine, Just theirs ) ->
                                        if theirs > clamp 8 15 mine then
                                            Err "the server returned a larger server_max_window_bits than offered"

                                        else
                                            Ok (Just (clientResult o r))

                                    _ ->
                                        Ok (Just (clientResult o r))

        ( Just _, _ ) ->
            Err "the server returned extensions that were not offered"


clientResult : ClientOffer r -> DeflateParams -> Negotiated
clientResult o r =
    let
        ours =
            case o.clientMaxWindowBits of
                Just (Just bits) ->
                    clamp 8 15 bits

                _ ->
                    15
    in
    { serverNoContextTakeover = r.serverNoContextTakeover
    , clientNoContextTakeover = r.clientNoContextTakeover || not o.contextTakeover
    , serverMaxWindowBits = Maybe.withDefault 15 r.serverMaxWindowBits
    , clientMaxWindowBits =
        case r.clientMaxWindowBits of
            Just (Just theirs) ->
                min theirs ours

            _ ->
                ours
    }


{-| Server side: answer a client's offers (`Nothing`: no compression). The result is the
negotiated parameters and the `Sec-WebSocket-Extensions` response value.

The offers are considered in order and the first acceptable `permessage-deflate` one is answered;
an offer with an unknown or repeated parameter or an invalid value is declined (RFC 7692 §7). The
answer:

  - `server_no_context_takeover`: when offered (it must be echoed), and always without context
    takeover (the default policy);
  - `client_no_context_takeover`: when offered, and always without context takeover (a server may
    include it unasked);
  - `server_max_window_bits`: the smaller of the offered value and the policy's `maxWindowBits`;
    sent when offered or when the policy uses less than 15 bits;
  - `client_max_window_bits` is never sent (we inflate with a 15-bit window whatever the client
    uses).

-}
negotiateServer : Maybe (ServerPolicy r) -> List Extension -> Maybe ( Negotiated, String )
negotiateServer policy offers =
    case policy of
        Nothing ->
            Nothing

        Just p ->
            firstJust (acceptOffer p) (List.filter (\e -> e.name == "permessage-deflate") offers)


firstJust : (a -> Maybe b) -> List a -> Maybe b
firstJust f list =
    case list of
        [] ->
            Nothing

        x :: rest ->
            case f x of
                Just y ->
                    Just y

                Nothing ->
                    firstJust f rest


acceptOffer : ServerPolicy r -> Extension -> Maybe ( Negotiated, String )
acceptOffer policy ext =
    deflateParams False ext.params
        |> Maybe.map
            (\o ->
                let
                    maxBits =
                        clamp 8 15 policy.maxWindowBits

                    serverBits =
                        case o.serverMaxWindowBits of
                            Just b ->
                                min b maxBits

                            Nothing ->
                                maxBits

                    serverNoContext =
                        o.serverNoContextTakeover || not policy.contextTakeover

                    clientNoContext =
                        o.clientNoContextTakeover || not policy.contextTakeover

                    sendServerBits =
                        o.serverMaxWindowBits /= Nothing || serverBits < 15
                in
                ( { serverNoContextTakeover = serverNoContext
                  , clientNoContextTakeover = clientNoContext
                  , serverMaxWindowBits = serverBits
                  , clientMaxWindowBits =
                        case o.clientMaxWindowBits of
                            Just (Just b) ->
                                b

                            _ ->
                                15
                  }
                , String.join "; "
                    ([ "permessage-deflate" ]
                        ++ (if serverNoContext then
                                [ "server_no_context_takeover" ]

                            else
                                []
                           )
                        ++ (if clientNoContext then
                                [ "client_no_context_takeover" ]

                            else
                                []
                           )
                        ++ (if sendServerBits then
                                [ "server_max_window_bits=" ++ String.fromInt serverBits ]

                            else
                                []
                           )
                    )
                )
            )
