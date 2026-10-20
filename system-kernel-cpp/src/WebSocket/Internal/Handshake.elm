module WebSocket.Internal.Handshake exposing
    ( Url, Host(..), parseUrl, hostHeader, serverName
    , tokenList, headerTokens, headerValues, isToken
    , requestHeaders, checkResponse, checkRequest, responseHeaders
    , Extension, parseExtensions, Negotiated, ClientOffer, ServerPolicy
    , clientOffer, negotiateClient, negotiateServer
    )

{-| The rules of the WebSocket opening handshake can all be checked without a network, and this
module holds them in pure Elm so that they can be tested without one.

A WebSocket connection begins as an HTTP request. Over HTTP/1.1 the client sends a `GET` with
`Upgrade: websocket`, a `Sec-WebSocket-Key` and `Sec-WebSocket-Version: 13`, and a server that
agrees answers with status 101 and a `Sec-WebSocket-Accept` value made from the key. Over HTTP/2
(RFC 8441) the request is a `CONNECT` and the answer a 2xx status; `Upgrade`, `Connection`, the
key and the accept value play no part. In both, the client may list the subprotocols it can
speak and offer extensions, and the server picks at most one subprotocol and answers the
extensions it takes up.

The module has four parts, in this order.

  - URLs: `parseUrl` reads a `ws://` or `wss://` URL, and `hostHeader` and `serverName` give the
    `Host` header and the TLS server name for one.
  - Header grammar: header values that are comma-separated lists, HTTP tokens, and the check
    of the headers a caller supplies.
  - The handshake. `requestHeaders` and `checkResponse` are the client's side: the headers it
    sends, and the check of the answer. `checkRequest` and `responseHeaders` are the server's
    side: the check of a request, and the headers of the answer that accepts it. Both builders
    refuse a malformed or reserved header among those their caller supplies.
  - Extensions: the `Sec-WebSocket-Extensions` grammar, which `parseExtensions` reads, and the
    negotiation of permessage-deflate (RFC 7692), the one extension this module knows.

permessage-deflate compresses each message with DEFLATE, and each end compresses what it sends
with its own compressor. Four terms describe how the ends agree on it.

An _offer_ is a `permessage-deflate` element in a client's `Sec-WebSocket-Extensions` header;
`clientOffer` writes one, and a client may send several. A _policy_ is what a server is willing
to agree to. `negotiateServer` answers the first offer it can accept under its policy, and
`negotiateClient` checks that answer against the offer on the client's side. Both give the
settings agreed as a `Negotiated`.

_Context takeover_ is a compressor keeping what it has seen from one message to the next, so that
a message can refer back into earlier ones. The `server_no_context_takeover` and
`client_no_context_takeover` parameters turn it off for one end, which then compresses every
message on its own.

_Window bits_ is the size of a compressor's window, the distance back it may refer, as a power of
two: from 8 (256 bytes) to 15 (32 KiB). The `server_max_window_bits` and `client_max_window_bits`
parameters limit it for one end.

-}

import Socket.Address as Address exposing (Address, Family(..))



-- URLS


{-| A WebSocket URL, as `parseUrl` reads it.

`secure` is `True` for `wss`, a connection over TLS, and `False` for `ws`. `port_` is the port
the URL gives, or the scheme's default port (80 for `ws`, 443 for `wss`) when it gives none.
`target` is the request target: the path, `/` when the URL has none, followed by the query if
there is one, both as written.

-}
type alias Url =
    { secure : Bool
    , host : Host
    , port_ : Int
    , target : String
    }


{-| The host part of a WebSocket URL: a name, or an IP address written out.

`Name` carries host text that is not an address, lower-cased and otherwise as written. It is
not checked to be a valid DNS name, and percent-encodings in it are not decoded.

`Literal` carries an address: an IPv4 address, or an IPv6 address, which may carry a scope.

-}
type Host
    = Name String
    | Literal Address


{-| Reads a `ws://` or `wss://` URL, or gives an error message that names the URL and what is
wrong with it.

The scheme is matched without regard to case. Every character after it must be printable ASCII
other than space. A fragment (`#`) or user information (an `@` before the path or query) is an
error, and so is any other scheme.

The host is one of three things. An IPv6 address must be in brackets, and may carry a scope
written `%25`, as in `ws://[fe80::1%25eth0]/` (RFC 6874); a bare `%` is accepted too. Brackets
around anything but an IPv6 address are an error, and so is unbracketed text with more than one
`:`. Unbracketed text that `Socket.Address.fromString` reads as an address is an IPv4 `Literal`.
Anything else is a `Name`, and may hold only ASCII letters and digits, `%` and
`-._~!$&'()*+,;=`. A port after a `:` is 1 to 5 digits with a value from 0 to 65535; a `:` with
no digits after it means the default port.

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


{-| Returns the position in `text` of the earliest occurrence of any of `needles`, or `Nothing`
when none occurs.
-}
firstIndex : List String -> String -> Maybe Int
firstIndex needles text =
    needles
        |> List.filterMap (\needle -> List.head (String.indexes needle text))
        |> List.minimum


{-| Tells whether `parseUrl` accepts a character in a URL: printable ASCII other than space,
from `!` to `~`. This admits some characters that a URL should percent-encode, such as `"`, `<`
and `{`.
-}
isUrlChar : Char -> Bool
isUrlChar c =
    let
        code =
            Char.toCode c
    in
    code > 0x20 && code < 0x7F


{-| Reads the authority of a URL, the part between the scheme and the path or query, into its
host and port, as `parseUrl` describes; the default port is that of the scheme `secure` names.
The error is the reason the authority is invalid.
-}
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


{-| Tells whether a character may appear in a host name: an ASCII letter or digit, `%`, or one of
`-._~!$&'()*+,;=`. A `%` is accepted on its own; what follows it is not checked to be a
percent-encoding.
-}
isRegNameChar : Char -> Bool
isRegNameChar c =
    Char.isAlphaNum c || String.contains (String.fromChar c) "-._~!$&'()*+,;=%"


{-| Reads the port of a URL: 1 to 5 ASCII digits with a value up to 65535, or, for empty text,
the default port of the scheme `secure` names.
-}
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


{-| Returns the port a URL means when it gives none: 443 for `wss` (`secure`) and 80 for `ws`.
-}
defaultPort : Bool -> Int
defaultPort secure =
    if secure then
        443

    else
        80


{-| Returns the value of the `Host` header for a URL: its host, followed by `:` and the port
unless the port is the scheme's default. An IPv6 address is written in brackets, without its
scope.
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


{-| Returns the TLS server name for a URL: its host name, or its address written without
brackets and without its scope.
-}
serverName : Url -> String
serverName url =
    case url.host of
        Name name ->
            name

        Literal address ->
            withoutZone address


{-| Prints an address as `Socket.Address.toString` does, without its scope.
-}
withoutZone : Address -> String
withoutZone address =
    Address.toString address
        |> String.split "%"
        |> List.head
        |> Maybe.withDefault ""



-- HEADER GRAMMAR


{-| Splits a comma-separated header value into its elements, trimmed and lower-cased, with empty
elements dropped: `"keep-alive, Upgrade"` gives `[ "keep-alive", "upgrade" ]`.
-}
tokenList : String -> List String
tokenList value =
    value
        |> String.split ","
        |> List.map (String.trim >> String.toLower)
        |> List.filter ((/=) "")


{-| Returns the elements of every occurrence of the header `name`, in order, each value split,
trimmed and lower-cased as `tokenList` does. `name` must be lower-case, as for `headerValues`.
-}
headerTokens : String -> List ( String, String ) -> List String
headerTokens name headers =
    headerValues name headers
        |> List.concatMap tokenList


{-| Returns the value of every occurrence of the header `name`, in order. Each header's name is
lower-cased before it is compared with `name`, so names match without regard to case, and a
`name` that is not itself lower-case matches nothing.
-}
headerValues : String -> List ( String, String ) -> List String
headerValues name headers =
    headers
        |> List.filter (\( n, _ ) -> String.toLower n == name)
        |> List.map Tuple.second


{-| Tells whether text is an HTTP token (RFC 9110): one or more ASCII letters, digits, or
characters from `` !#$%&'*+-.^_`|~ ``.
-}
isToken : String -> Bool
isToken text =
    text /= "" && String.all isTokenChar text


{-| Tells whether a character may appear in an HTTP token: an ASCII letter or digit, or one of
`` !#$%&'*+-.^_`|~ ``.
-}
isTokenChar : Char -> Bool
isTokenChar c =
    Char.toCode c < 0x80 && (Char.isAlphaNum c || String.contains (String.fromChar c) "!#$%&'*+-.^_`|~")


{-| Tells whether a header may be sent as given: its name is an HTTP token and its value holds no
carriage return, line feed or NUL. Other control characters in the value are allowed.
-}
isValidHeader : ( String, String ) -> Bool
isValidHeader ( name, value ) =
    isToken name && not (String.any (\c -> c == '\u{000D}' || c == '\n' || c == '\u{0000}') value)


{-| The header names, lower-cased, that a header supplied by the caller may not have, in any case:
the headers the handshake writes itself, and `content-length` and `transfer-encoding`.
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


{-| Succeeds when every header supplied by the caller may be sent and none has a reserved name,
and otherwise gives an error message naming the first header that fails.
-}
checkUserHeaders : List ( String, String ) -> Result String ()
checkUserHeaders headers =
    case List.filter (\(( name, _ ) as h) -> not (isValidHeader h) || List.member (String.toLower name) reservedNames) headers of
        [] ->
            Ok ()

        ( name, _ ) :: _ ->
            Err ("invalid or reserved header " ++ name)



-- HANDSHAKE


{-| Builds the headers of a client's opening request, in this order: `Host` with `host`,
`Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Key` with `key`,
`Sec-WebSocket-Version: 13`, then `Sec-WebSocket-Protocol` with the `protocols` joined by `", "`
when there are any, then `Sec-WebSocket-Extensions` when `extensions` is given, then `headers`.

It gives an error message instead when a protocol is not an HTTP token, when a protocol is listed
twice (compared exactly), or when one of `headers` has a name that is not a token, a value that
holds a carriage return, line feed or NUL, or the name, in any case, of a header either side of
the handshake writes (`Sec-WebSocket-Accept` included), `content-length` or `transfer-encoding`.
`host`, `key` and `extensions` are written as given, without checks.

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


{-| Tells whether any string occurs more than once in a list, compared exactly.
-}
hasDuplicates : List String -> Bool
hasDuplicates list =
    case list of
        [] ->
            False

        x :: rest ->
            List.member x rest || hasDuplicates rest


{-| Checks a server's answer to a client's opening request, given the answer's `status` and
`headers`, and returns the protocol the server chose and the extensions it returned.

`expected` describes the request: `expectedAccept` is the `Sec-WebSocket-Accept` value its key
calls for, `protocols` the protocols it offered, and `isH2` whether it went over HTTP/2.

Over HTTP/1.1 the status must be 101, and over HTTP/2 any 2xx. Over HTTP/1.1 the answer must
also have `websocket` among its `Upgrade` elements and `upgrade` among its `Connection` elements
(compared without regard to case), and exactly one `Sec-WebSocket-Accept`, equal to
`expectedAccept` once trimmed; over HTTP/2 none of these three is checked. In both,
`Sec-WebSocket-Protocol` may occur at most once, and its whole value, trimmed, must be exactly
one of `protocols`. The `Sec-WebSocket-Extensions` headers must follow the grammar
`parseExtensions` reads; whether the extensions were offered is not checked here.

A failure gives an error message, paired with the status when the status was what failed and
with `Nothing` otherwise.

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


{-| Checks a client's opening request and returns what the client asked for: its key, its
protocols in order, and its extensions as `parseExtensions` reads them.

The checks are made in this order, and the first that fails decides the answer. Over HTTP/1.1 the
method must be `GET`, the HTTP `version`, written `major.minor` (such as `"1.1"`), 1.1 or later,
and the request must have a `Host` header, `websocket` among its `Upgrade` elements and `upgrade`
among its `Connection` elements. Over HTTP/2 (`isH2`) the method must be `CONNECT`, and those
other checks are not made. In both, `Sec-WebSocket-Version` must occur exactly once with the value
`13` once trimmed. Over HTTP/1.1 there must then be exactly one `Sec-WebSocket-Key`, and it must
be the base64 encoding of 16 bytes. In both, every protocol must be an HTTP token, and the
`Sec-WebSocket-Extensions` headers must follow the grammar `parseExtensions` reads. The method is
compared exactly; header names, and the `Upgrade` and `Connection` elements, without regard to
case.

A failure gives the status to answer with and an error message: 426 when the
`Sec-WebSocket-Version` check failed, and 400 for every other check.

The protocols are the comma-separated elements of every `Sec-WebSocket-Protocol` header, trimmed,
with empty ones dropped and their case kept; a protocol listed twice is not an error. The key is
trimmed. Over HTTP/2 it is not checked: it is the first `Sec-WebSocket-Key` if the request has
one, and empty otherwise.

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


{-| Tells whether an HTTP version written as `major.minor`, such as `"1.1"`, is 1.1 or later.
Text of any other shape, such as `"2"`, is not.
-}
atLeastHttp11 : String -> Bool
atLeastHttp11 version =
    case String.split "." version |> List.map String.toInt of
        [ Just major, Just minor ] ->
            major > 1 || (major == 1 && minor >= 1)

        _ ->
            False


{-| Tells whether a `Sec-WebSocket-Key` is the canonical base64 encoding of 16 bytes: 22 base64
digits, the last of which has its low four bits zero (`A`, `Q`, `g` or `w`), then `==`.
-}
isKey : String -> Bool
isKey key =
    String.length key
        == 24
        && String.endsWith "==" key
        && String.all isBase64Char (String.left 22 key)
        && String.contains (String.slice 21 22 key) "AQgw"


{-| Tells whether a character is a digit of standard base64: an ASCII letter or digit, `+` or
`/`.
-}
isBase64Char : Char -> Bool
isBase64Char c =
    Char.toCode c < 0x80 && (Char.isAlphaNum c || c == '+' || c == '/')


{-| Builds the headers of a server's answer that accepts an opening request, in this order: over
HTTP/1.1, `Upgrade: websocket`, `Connection: Upgrade` and `Sec-WebSocket-Accept` with `accept`;
then `Sec-WebSocket-Protocol` when `protocol` is given, then `Sec-WebSocket-Extensions` when
`extensions` is given, then `headers`. Over HTTP/2 (`isH2`) the first three are left out and
`accept` is not used.

It gives an error message instead when one of `headers` is refused, by the same rule as in
`requestHeaders`. `accept`, `protocol` and `extensions` are written as given, without checks.

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



-- EXTENSIONS


{-| One element of a `Sec-WebSocket-Extensions` header: an extension's name and its parameters.

`params` holds the parameters in the order written, each with its value, or with `Nothing` when
it was written without one. In values from `parseExtensions`, `name` and the parameter names are
lower-case.

-}
type alias Extension =
    { name : String
    , params : List ( String, Maybe String )
    }


{-| Reads the values of every occurrence of the `Sec-WebSocket-Extensions` header, in order, as
one list of extensions, or gives `Nothing` when any value breaks the grammar.

A value is a comma-separated list of extensions. An extension is a token, its name, followed by
any number of parameters, each written `;` and a token, optionally followed by `=` and a value,
which is a token or a quoted string. Spaces and tabs are allowed between any two of these parts,
including on either side of `=`. Empty list elements are skipped, so an empty value, or no
header at all, gives no extensions, where RFC 6455 requires at least one.

A quoted string may not hold a control character other than tab, nor run on from one occurrence
of the header into the next. Its backslash escapes are removed, and what remains must be a
token. Extension and parameter names are lower-cased; values keep their case. Repeated or
unknown parameters are not checked here.

-}
parseExtensions : List String -> Maybe (List Extension)
parseExtensions values =
    values
        |> List.map (String.toList >> lexExtensions [])
        |> combine
        |> Maybe.map (List.intersperse [ XComma ] >> List.concat)
        |> Maybe.andThen (splitOn XComma >> List.filter (not << List.isEmpty) >> List.map parseExtension >> combine)


{-| One lexical item of a `Sec-WebSocket-Extensions` value.

`XWord` carries a run of token characters.

`XQuoted` carries the value of a quoted string, with its quotes and backslash escapes removed.

`XComma`, `XSemi` and `XEquals` are the separators `,`, `;` and `=`.

-}
type XToken
    = XWord String
    | XQuoted String
    | XComma
    | XSemi
    | XEquals


{-| Splits the characters of one header value into lexical items, after the items in `acc`
(which are held in reverse), skipping spaces and tabs. It gives `Nothing` at a character that is
not a token character or a separator, and for a quoted string that `lexQuoted` refuses.
-}
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


{-| Reads the rest of a quoted string after its opening quote, after the characters in `acc`
(held in reverse), and returns its value and the characters after the closing quote. A backslash
makes the next character part of the value, whatever it is. It gives `Nothing` when the closing
quote is missing, or when a control character other than tab, or DEL, appears unescaped.
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


{-| Returns the longest start of a list whose elements all pass `ok`.
-}
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


{-| Splits a list of items at every `separator`, giving the groups between them in order, empty
groups included. An empty list gives one empty group.
-}
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


{-| Reads one extension, a name followed by its parameters, from the items of one list element,
lower-casing the name. It gives `Nothing` when the items do not start with a name or a parameter
is malformed.
-}
parseExtension : List XToken -> Maybe Extension
parseExtension tokens =
    case tokens of
        (XWord name) :: params ->
            parseParams [] params
                |> Maybe.map (\ps -> { name = String.toLower name, params = ps })

        _ ->
            Nothing


{-| Reads an extension's parameters, each `;` and a name, optionally followed by `=` and a value,
after the parameters in `acc` (held in reverse), lower-casing their names. A quoted value must be
a token. It gives `Nothing` for anything else.
-}
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


{-| Returns the values of a list of `Maybe`s in order, or `Nothing` if any of them is `Nothing`.
-}
combine : List (Maybe a) -> Maybe (List a)
combine list =
    List.foldr (Maybe.map2 (::)) (Just []) list


{-| The permessage-deflate settings the two ends have agreed on: for each end's compressor,
whether it takes over context from one message to the next, and how large its window may be.

`serverNoContextTakeover` and `clientNoContextTakeover` are `True` when that end compresses every
message on its own. `serverMaxWindowBits` and `clientMaxWindowBits` are the largest window that
end compresses with, as window bits. Every value this module produces is from 8 to 15, but a field
is a plain `Int` and the compiler accepts any.

The same record is declared as `WebSocket.Negotiated` and as `WebSocket.Internal.Negotiated`.
The three are interchangeable only because record aliases are structural, so they must be kept
identical.

-}
type alias Negotiated =
    { serverNoContextTakeover : Bool
    , clientNoContextTakeover : Bool
    , serverMaxWindowBits : Int
    , clientMaxWindowBits : Int
    }


{-| What a client asks for in its permessage-deflate offer. Any record with these fields will do.

`contextTakeover = False` asks for both ends to compress every message on its own.
`serverMaxWindowBits` is `Just n` to ask the server to compress with at most `n` window bits.
`clientMaxWindowBits` is `Nothing` to leave that parameter out, `Just Nothing` to send it without
a value, and `Just (Just n)` to send `n`, the largest window the client compresses with; the
server may answer with a limit for the client's window only when the parameter is sent. Window
sizes outside 8 to 15 are clamped into that range.

-}
type alias ClientOffer r =
    { r
        | clientMaxWindowBits : Maybe (Maybe Int)
        , serverMaxWindowBits : Maybe Int
        , contextTakeover : Bool
    }


{-| What a server is willing to agree to when it answers a permessage-deflate offer. Any record
with these fields will do.

`maxWindowBits` is the largest window the server compresses with, clamped to 8 to 15.
`contextTakeover = False` makes the server answer that both ends compress every message on its
own, whatever the offer asked.

-}
type alias ServerPolicy r =
    { r | maxWindowBits : Int, contextTakeover : Bool }


{-| Writes the `Sec-WebSocket-Extensions` value of a client's permessage-deflate offer:
`permessage-deflate`, then `client_no_context_takeover` and `server_no_context_takeover` when
`contextTakeover` is `False`, then `client_max_window_bits` (without a value for `Just Nothing`)
and `server_max_window_bits` when they are asked for, all joined by `"; "`. Window sizes are
clamped to 8 to 15.
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


{-| The parameters of one permessage-deflate element, as read from an offer or an answer.

A `NoContextTakeover` field is `True` when its parameter is present, and a window size is
`Nothing` when its parameter is absent. `clientMaxWindowBits` is `Just Nothing` when the
parameter came without a value, which only an offer may do.

-}
type alias DeflateParams =
    { serverNoContextTakeover : Bool
    , clientNoContextTakeover : Bool
    , serverMaxWindowBits : Maybe Int
    , clientMaxWindowBits : Maybe (Maybe Int)
    }


{-| Reads the parameters of a permessage-deflate element: an offer when `forResponse` is `False`,
a server's answer when it is `True`. It gives `Nothing` when a parameter is unknown, is repeated,
or has an invalid value.

The two `*_no_context_takeover` parameters take no value. `server_max_window_bits` needs a window
size. `client_max_window_bits` takes one too, but may come without a value in an offer. A window
size is a decimal number from 8 to 15 without a leading zero; a window size written as a quoted
string in the header reads the same, since `parseExtensions` removes the quotes.

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


{-| Adds one parameter, given by its name and value, to the parameters read so far, under the
rules `deflateParams` describes. It gives `Nothing` when the parameter is unknown or its value is
invalid.
-}
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


{-| Reads a window size: a decimal number from 8 to 15 without a leading zero.
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


{-| Checks the extensions a server `returned` against the client's permessage-deflate `offer`
(`Nothing` when it offered none), and gives the settings agreed, or an error message when the
answer cannot be accepted.

When the server returned no extension, the result is `Ok Nothing`, whatever the offer. Otherwise
there must have been an offer, and the server must have returned exactly one extension, named
`permessage-deflate`. Its parameters may each appear at most once: `server_no_context_takeover`
and `client_no_context_takeover` without a value, and `server_max_window_bits` and
`client_max_window_bits` with a window size from 8 to 15 (no leading zero).
`client_max_window_bits` is allowed only when the offer had it, and `server_max_window_bits` may
not exceed the offer's value, clamped to 8 to 15, when the offer had one. Anything else is an
error.

In the settings, the server's end takes over context unless the answer says
`server_no_context_takeover`, and its window is the answer's `server_max_window_bits`, or 15. The
client's end compresses every message on its own when the answer says
`client_no_context_takeover` or the offer had `contextTakeover = False`, and its window is the
offer's own value (clamped to 8 to 15, or 15 when the offer gave none), or the answer's
`client_max_window_bits` when that is smaller.

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


{-| Returns the settings a client has agreed to, from its offer and the parameters of the
server's answer, as `negotiateClient` describes.
-}
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


{-| Answers a client's extension `offers` under a server's `policy` (`Nothing` for no
compression), giving the settings agreed and the `Sec-WebSocket-Extensions` value of the answer,
or `Nothing` when no offer is accepted.

Only elements named exactly `permessage-deflate` are considered; other extensions are ignored.
They are tried in order and the first with valid parameters is answered. An offer is passed over
when a parameter is unknown or repeated, when a `*_no_context_takeover` parameter has a value, when
`server_max_window_bits` has none, or when a window size is not a decimal number from 8 to 15
without a leading zero.

The answer is `permessage-deflate` followed, joined by `"; "`, by:

  - `server_no_context_takeover` when the offer has it or the policy's `contextTakeover` is
    `False`;
  - `client_no_context_takeover` when the offer has it or the policy's `contextTakeover` is
    `False`;
  - `server_max_window_bits` with the policy's `maxWindowBits` (clamped to 8 to 15), or the
    offer's value when that is smaller, when the offer has the parameter or the size is under 15.

`client_max_window_bits` is never part of the answer. The settings record the client's window as
the value the offer gave, or 15 when it gave none.

-}
negotiateServer : Maybe (ServerPolicy r) -> List Extension -> Maybe ( Negotiated, String )
negotiateServer policy offers =
    case policy of
        Nothing ->
            Nothing

        Just p ->
            firstJust (acceptOffer p) (List.filter (\e -> e.name == "permessage-deflate") offers)


{-| Returns the first `Just` that `f` gives for the elements of a list, taken in order, or
`Nothing` when it gives none.
-}
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


{-| Answers one permessage-deflate offer under `policy`, as `negotiateServer` describes, giving
the settings agreed and the answer's header value, or `Nothing` when the offer's parameters are
invalid.
-}
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
