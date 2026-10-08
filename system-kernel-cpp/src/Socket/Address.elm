module Socket.Address exposing
    ( Address, Family(..), Endpoint(..), InetEndpoint
    , fromString, toString, fromOctets, toOctets
    , family, loopback, any, isLoopback, isUnspecified, isIPv4Mapped, unmapIPv4
    )

{-| IPv4 and IPv6 addresses, and the endpoints of sockets.

This module is pure Elm: parsing and printing never touch the network, so they behave the same
on every platform and backend. Host names are not addresses; resolve them with
[`Socket.lookup`](Socket#lookup), or connect to a name directly with
[`Socket.Tcp.connectToHost`](Socket-Tcp#connectToHost).

    Socket.Address.fromString "::FFFF:127.0.0.1"
        |> Maybe.map Socket.Address.toString
    --> Just "::ffff:127.0.0.1"


## Addresses

@docs Address, Family, fromString, toString, fromOctets, toOctets, family


## Well-known addresses

@docs loopback, any


## Classification

@docs isLoopback, isUnspecified, isIPv4Mapped, unmapIPv4


## Endpoints

@docs Endpoint, InetEndpoint

-}

import System.File.Path exposing (Path)



-- ADDRESSES


{-| An IPv4 or an IPv6 address. An IPv6 address may carry a scope (zone), such as the `eth0` of
`fe80::1%eth0`, which names the network interface a link-local address belongs to.

Two addresses are equal (`==`) when they have the same family, the same bits and the same
scope text.

-}
type Address
    = V4 Int
    | V6 (List Int) String


{-| The two address families.
-}
type Family
    = IPv4
    | IPv6


{-| Parse an address.

  - **IPv4:** four decimal fields from 0 to 255, separated by dots. Leading zeros are not
    allowed (`"01.2.3.4"` is rejected), as in the C library's `inet_pton` and Node's `net.isIP`.
  - **IPv6:** the text form of RFC 4291: groups of 1 to 4 hexadecimal digits (in either case)
    separated by colons, at most one `::` standing for one or more zero groups, and optionally a
    dotted IPv4 address as the last two groups (`"::ffff:192.0.2.1"`). Without `::` there must be
    exactly 8 groups; with it, at most 7.
  - An IPv6 address may end in a scope: `%` followed by 1 to 15 characters from `A-Z`, `a-z`,
    `0-9`, `_`, `.` and `-` (an interface name such as `"eth0"` or an interface number such as
    `"2"`).

Anything else, including surrounding whitespace, gives `Nothing`.

    fromString "192.168.0.1"   -- an IPv4 address
    fromString "fe80::1%eth0"  -- an IPv6 address with a scope
    fromString "localhost"     --> Nothing

-}
fromString : String -> Maybe Address
fromString text =
    case String.indexes "%" text of
        [] ->
            if String.contains ":" text then
                parseV6 text ""

            else
                parseV4 text |> Maybe.map V4

        i :: _ ->
            let
                scope =
                    String.dropLeft (i + 1) text
            in
            if isValidScope scope then
                parseV6 (String.left i text) scope

            else
                Nothing


{-| Print an address in its canonical form, which [`fromString`](#fromString) reads back.

  - IPv4: dotted decimal, `"127.0.0.1"`.
  - IPv6 (RFC 5952): lower-case hexadecimal without leading zeros; the longest run of two or more
    zero groups (the leftmost one if there is a tie) is written `::`, and a single zero group is
    written `0`. IPv4-mapped addresses are written `"::ffff:a.b.c.d"`. The scope, if any, follows
    after a `%`.

```
fromString "2001:DB8:0:0:1:0:0:1" |> Maybe.map toString
--> Just "2001:db8::1:0:0:1"
```

-}
toString : Address -> String
toString address =
    case address of
        V4 n ->
            dotted (v4Octets n)

        V6 octets scope ->
            let
                body =
                    if isMappedOctets octets then
                        "::ffff:" ++ dotted (List.drop 12 octets)

                    else
                        compressGroups (groupsOf octets)
            in
            if scope == "" then
                body

            else
                body ++ "%" ++ scope


{-| Build an address from its bytes in network order: 4 values give an IPv4 address and 16 values an
IPv6 address (without a scope). Any other length, or a value outside 0–255, gives `Nothing`.

    fromOctets [ 127, 0, 0, 1 ] |> Maybe.map toString
    --> Just "127.0.0.1"

-}
fromOctets : List Int -> Maybe Address
fromOctets octets =
    if List.all (\o -> o >= 0 && o <= 255) octets then
        case List.length octets of
            4 ->
                Just (V4 (fromBytes octets))

            16 ->
                Just (V6 octets "")

            _ ->
                Nothing

    else
        Nothing


{-| The bytes of an address in network order: 4 for IPv4, 16 for IPv6. The scope is not included.
-}
toOctets : Address -> List Int
toOctets address =
    case address of
        V4 n ->
            v4Octets n

        V6 octets _ ->
            octets


{-| The family of an address. An IPv4-mapped address such as `"::ffff:127.0.0.1"` is an IPv6
address; [`unmapIPv4`](#unmapIPv4) turns it into an IPv4 one.
-}
family : Address -> Family
family address =
    case address of
        V4 _ ->
            IPv4

        V6 _ _ ->
            IPv6



-- WELL-KNOWN ADDRESSES


{-| The loopback address of a family: `127.0.0.1` or `::1`.
-}
loopback : Family -> Address
loopback fam =
    case fam of
        IPv4 ->
            V4 0x7F000001

        IPv6 ->
            V6 (List.repeat 15 0 ++ [ 1 ]) ""


{-| The unspecified ("any") address of a family: `0.0.0.0` or `::`. Listening on it accepts
connections on every interface.
-}
any : Family -> Address
any fam =
    case fam of
        IPv4 ->
            V4 0

        IPv6 ->
            V6 (List.repeat 16 0) ""



-- CLASSIFICATION


{-| `True` for loopback addresses: `127.0.0.0/8`, `::1`, and the IPv4-mapped forms of
`127.0.0.0/8` (such as `::ffff:127.0.0.1`). The scope is ignored.
-}
isLoopback : Address -> Bool
isLoopback address =
    case address of
        V4 n ->
            n // 0x01000000 == 127

        V6 octets _ ->
            if isMappedOctets octets then
                List.head (List.drop 12 octets) == Just 127

            else
                octets == List.repeat 15 0 ++ [ 1 ]


{-| `True` for the unspecified addresses `0.0.0.0` and `::`. The scope is ignored.
-}
isUnspecified : Address -> Bool
isUnspecified address =
    case address of
        V4 n ->
            n == 0

        V6 octets _ ->
            List.all (\o -> o == 0) octets


{-| `True` for IPv4-mapped IPv6 addresses (`::ffff:0:0/96`), such as `::ffff:127.0.0.1`. A socket
bound to an IPv6 address that also accepts IPv4 traffic reports its IPv4 peers this way.
-}
isIPv4Mapped : Address -> Bool
isIPv4Mapped address =
    case address of
        V4 _ ->
            False

        V6 octets _ ->
            isMappedOctets octets


{-| Turn an IPv4-mapped IPv6 address into the IPv4 address it maps (`::ffff:127.0.0.1` becomes
`127.0.0.1`). Every other address is returned unchanged.
-}
unmapIPv4 : Address -> Address
unmapIPv4 address =
    case address of
        V6 octets _ ->
            if isMappedOctets octets then
                V4 (fromBytes (List.drop 12 octets))

            else
                address

        V4 _ ->
            address



-- ENDPOINTS


{-| One end of a socket connection.

  - `Inet` is an IPv4 or IPv6 address and a port.
  - `Unix` is the path of a Unix domain socket. An unnamed socket, such as the client side of a
    Unix connection or the remote end seen by a Unix server, has the
    [empty path](System-File-Path#empty).

-}
type Endpoint
    = Inet InetEndpoint
    | Unix Path


{-| An address and a port.
-}
type alias InetEndpoint =
    { address : Address
    , port_ : Int
    }



-- PARSING


parseV4 : String -> Maybe Int
parseV4 text =
    case String.split "." text of
        [ a, b, c, d ] ->
            Maybe.map4 (\w x y z -> ((w * 256 + x) * 256 + y) * 256 + z)
                (parseOctet a)
                (parseOctet b)
                (parseOctet c)
                (parseOctet d)

        _ ->
            Nothing


{-| A decimal field: 1–3 ASCII digits, no leading zero unless the field is `0`, at most 255.
-}
parseOctet : String -> Maybe Int
parseOctet field =
    let
        len =
            String.length field
    in
    if len < 1 || len > 3 || not (String.all Char.isDigit field) then
        Nothing

    else if len > 1 && String.startsWith "0" field then
        Nothing

    else
        String.toInt field
            |> Maybe.andThen
                (\n ->
                    if n <= 255 then
                        Just n

                    else
                        Nothing
                )


{-| One group of 1–4 ASCII hex digits.
-}
parseGroup : String -> Maybe Int
parseGroup group =
    let
        len =
            String.length group
    in
    if len < 1 || len > 4 || not (String.all Char.isHexDigit group) then
        Nothing

    else
        Just (String.foldl (\c acc -> acc * 16 + hexValue c) 0 group)


hexValue : Char -> Int
hexValue c =
    let
        code =
            Char.toCode c
    in
    if code >= 0x30 && code <= 0x39 then
        code - 0x30

    else if code >= 0x61 && code <= 0x66 then
        code - 0x61 + 10

    else
        code - 0x41 + 10


{-| The 16-bit groups of a colon-separated side of an IPv6 address (`""` has none). Only the
last group of the address (`allowDotted`) may be a dotted IPv4 address, which gives two groups.
-}
parseGroups : Bool -> String -> Maybe (List Int)
parseGroups allowDotted side =
    if side == "" then
        Just []

    else
        let
            fields =
                String.split ":" side

            count =
                List.length fields

            parseField i field =
                if allowDotted && i == count - 1 && String.contains "." field then
                    parseV4 field |> Maybe.map (\n -> [ n // 0x00010000, modBy 0x00010000 n ])

                else
                    parseGroup field |> Maybe.map List.singleton
        in
        List.indexedMap parseField fields
            |> combine
            |> Maybe.map List.concat


parseV6 : String -> String -> Maybe Address
parseV6 text scope =
    let
        build groups =
            V6 (List.concatMap (\g -> [ g // 256, modBy 256 g ]) groups) scope
    in
    case String.split "::" text of
        [ whole ] ->
            parseGroups True whole
                |> Maybe.andThen
                    (\groups ->
                        if List.length groups == 8 then
                            Just (build groups)

                        else
                            Nothing
                    )

        [ left, right ] ->
            Maybe.map2
                (\hi lo ->
                    let
                        missing =
                            8 - List.length hi - List.length lo
                    in
                    if missing >= 1 then
                        Just (build (hi ++ List.repeat missing 0 ++ lo))

                    else
                        Nothing
                )
                (parseGroups False left)
                (parseGroups True right)
                |> Maybe.andThen identity

        _ ->
            Nothing


isValidScope : String -> Bool
isValidScope scope =
    let
        len =
            String.length scope
    in
    len >= 1 && len <= 15 && String.all isScopeChar scope


isScopeChar : Char -> Bool
isScopeChar c =
    Char.isAlphaNum c || c == '_' || c == '.' || c == '-'


combine : List (Maybe a) -> Maybe (List a)
combine maybes =
    List.foldr (Maybe.map2 (::)) (Just []) maybes



-- PRINTING


v4Octets : Int -> List Int
v4Octets n =
    [ n // 0x01000000, modBy 256 (n // 0x00010000), modBy 256 (n // 256), modBy 256 n ]


fromBytes : List Int -> Int
fromBytes octets =
    List.foldl (\o acc -> acc * 256 + o) 0 octets


dotted : List Int -> String
dotted octets =
    String.join "." (List.map String.fromInt octets)


isMappedOctets : List Int -> Bool
isMappedOctets octets =
    List.take 12 octets == List.repeat 10 0 ++ [ 255, 255 ]


groupsOf : List Int -> List Int
groupsOf octets =
    case octets of
        hi :: lo :: rest ->
            (hi * 256 + lo) :: groupsOf rest

        _ ->
            []


{-| RFC 5952: the longest run of two or more zero groups (leftmost on ties) becomes `::`.
-}
compressGroups : List Int -> String
compressGroups groups =
    let
        hex =
            toHex

        -- ( bestStart, bestLength, ( runStart, runLength ) ) over the indexed groups
        step i g ( bestStart, bestLen, ( runStart, runLen ) ) =
            if g == 0 then
                let
                    start =
                        if runLen == 0 then
                            i

                        else
                            runStart

                    len =
                        runLen + 1
                in
                if len > bestLen then
                    ( start, len, ( start, len ) )

                else
                    ( bestStart, bestLen, ( start, len ) )

            else
                ( bestStart, bestLen, ( 0, 0 ) )

        ( best, bestLength, _ ) =
            List.foldl (\( i, g ) acc -> step i g acc) ( -1, 0, ( 0, 0 ) ) (List.indexedMap Tuple.pair groups)
    in
    if bestLength >= 2 then
        String.join ":" (List.map hex (List.take best groups))
            ++ "::"
            ++ String.join ":" (List.map hex (List.drop (best + bestLength) groups))

    else
        String.join ":" (List.map hex groups)


toHex : Int -> String
toHex n =
    let
        digit d =
            String.slice d (d + 1) "0123456789abcdef"

        go m acc =
            if m < 16 then
                digit m ++ acc

            else
                go (m // 16) (digit (modBy 16 m) ++ acc)
    in
    go n ""
