module Socket.Address exposing
    ( Address, Family(..), Endpoint(..), InetEndpoint
    , fromString, toString, fromOctets, toOctets
    , family, loopback, any, isLoopback, isUnspecified, isIPv4Mapped, unmapIPv4
    )

{-| Many socket functions in this package take an IP address or the endpoint of a socket as a
value of this module rather than as text, and this module defines those values: IPv4 and IPv6
addresses, and the endpoints of sockets.

An [`Address`](#Address) is valid by construction. It is made only here: by parsing text with
[`fromString`](#fromString), from bytes with [`fromOctets`](#fromOctets), as one of the
well-known addresses, or with [`unmapIPv4`](#unmapIPv4). [`toString`](#toString) prints every
address in one canonical form, which `fromString` reads back as the same address. Parsing and
printing are pure Elm and never touch the network, so they behave the same on every platform
and backend.

Host names are not addresses: `fromString "localhost"` is `Nothing`. Resolve a name with
[`Socket.lookup`](Socket#lookup), or connect to one directly with
[`Socket.Tcp.connectToHost`](Socket-Tcp#connectToHost).

Four terms are used throughout.

An IPv6 address may carry a _scope_ (also called a zone): the text after a `%`, such as the `eth0`
of `fe80::1%eth0`, which names the network interface a link-local address belongs to. The scope
is part of the address, so `fe80::1%eth0` and `fe80::1` are not equal.

The _unspecified_ address, `0.0.0.0` or `::`, names no particular host. [`any`](#any) returns it.

An _IPv4-mapped_ address is an IPv6 address that carries an IPv4 address in its last 32 bits,
written `::ffff:a.b.c.d`. It is an IPv6 address and is not equal to the IPv4 address it carries;
[`unmapIPv4`](#unmapIPv4) returns that IPv4 address. A TCP listener or UDP socket on the
unspecified IPv6 address with `ipv6Only = False` sees its IPv4 peers this way.

An _endpoint_ is where a socket is: an address and a port, or the path of a Unix domain socket.

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

import Path exposing (Path)



-- ADDRESSES


{-| An IPv4 or IPv6 address, valid by construction; an IPv6 address may also carry a scope.

A value is obtained from [`fromString`](#fromString), [`fromOctets`](#fromOctets),
[`loopback`](#loopback), [`any`](#any) or [`unmapIPv4`](#unmapIPv4), so every `Address` is valid:
[`toString`](#toString) prints it as text that `fromString` reads back as the same address.

Two addresses are equal (`==`) when they have the same family, the same bits and the same scope
text, compared exactly. An IPv4-mapped address is therefore never equal to the IPv4 address it
carries, and `fe80::1%eth0` is not equal to `fe80::1%ETH0`.

-}
type Address
    = V4 Int
    | V6 (List Int) String


{-| Which of the two kinds of address a value is: `IPv4`, 32 bits, or `IPv6`, 128 bits. An
IPv4-mapped address is `IPv6`.
-}
type Family
    = IPv4
    | IPv6


{-| Parses the text of an IPv4 or IPv6 address, giving `Nothing` for anything that is not one.

  - **IPv4:** four decimal fields from 0 to 255, separated by dots, each of 1 to 3 ASCII digits.
    A leading zero is not allowed (`"01.2.3.4"` is rejected).
  - **IPv6:** the text form of RFC 4291: groups of 1 to 4 hexadecimal digits (in either case)
    separated by colons, at most one `::` standing for one or more zero groups, and optionally a
    dotted IPv4 address, written as above, in place of the last two groups
    (`"::ffff:192.0.2.1"`). Without `::` there must be exactly 8 groups; with it, at most 7. A
    dotted ending counts as two groups.
  - An IPv6 address may end in a scope: `%` followed by 1 to 15 characters from `A-Z`, `a-z`,
    `0-9`, `_`, `.` and `-`, such as the interface name `"eth0"` or the interface number `"2"`.
    An IPv4 address cannot have a scope.

Anything else, including surrounding whitespace, gives `Nothing`.

    fromString "localhost"
    --> Nothing

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


{-| Prints an address in its canonical form, which [`fromString`](#fromString) reads back as the
same address.

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


{-| Builds an address from its bytes in network order: 4 values give an IPv4 address and 16 values
an IPv6 address (without a scope). Any other length, or a value outside 0–255, gives `Nothing`.

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


{-| Returns the bytes of an address in network order: 4 for IPv4, 16 for IPv6. The scope is not
included.
-}
toOctets : Address -> List Int
toOctets address =
    case address of
        V4 n ->
            v4Octets n

        V6 octets _ ->
            octets


{-| Returns the family of an address. An IPv4-mapped address such as `"::ffff:127.0.0.1"` is an IPv6
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


{-| Returns the loopback address of a family, `127.0.0.1` or `::1`, the address by which a host
reaches itself. [`isLoopback`](#isLoopback) accepts more addresses than these two.
-}
loopback : Family -> Address
loopback fam =
    case fam of
        IPv4 ->
            V4 0x7F000001

        IPv6 ->
            V6 (List.repeat 15 0 ++ [ 1 ]) ""


{-| Returns the unspecified address of a family, `0.0.0.0` or `::`.

As the address to listen or bind on, it stands for every local interface rather than one.
Whether the IPv6 one also takes IPv4 traffic is set by `ipv6Only` in
[`Socket.Tcp.ListenOptions`](Socket-Tcp#ListenOptions) and
[`Socket.Udp.BindOptions`](Socket-Udp#BindOptions). [`Http.Server`](Http-Server) has no
`ipv6Only` and listens as if it were `False`.

-}
any : Family -> Address
any fam =
    case fam of
        IPv4 ->
            V4 0

        IPv6 ->
            V6 (List.repeat 16 0) ""



-- CLASSIFICATION


{-| Returns `True` for loopback addresses: `127.0.0.0/8`, `::1`, and the IPv4-mapped forms of
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


{-| Returns `True` for the unspecified addresses `0.0.0.0` and `::`. The scope is ignored. Unlike
[`isLoopback`](#isLoopback), this does not look inside an IPv4-mapped address: `::ffff:0.0.0.0`
is not unspecified.
-}
isUnspecified : Address -> Bool
isUnspecified address =
    case address of
        V4 n ->
            n == 0

        V6 octets _ ->
            List.all (\o -> o == 0) octets


{-| Returns `True` for IPv4-mapped IPv6 addresses (`::ffff:0:0/96`), such as `::ffff:127.0.0.1`,
whatever their scope.
-}
isIPv4Mapped : Address -> Bool
isIPv4Mapped address =
    case address of
        V4 _ ->
            False

        V6 octets _ ->
            isMappedOctets octets


{-| Turns an IPv4-mapped IPv6 address into the IPv4 address it carries (`::ffff:127.0.0.1` becomes
`127.0.0.1`), dropping any scope. Every other address is returned unchanged.
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


{-| Where a stream socket is: one end of a connection, or the place a listener listens.

`Inet` carries an IP address and a port.

`Unix` carries the path of a Unix domain socket. The [empty path](Path#empty) stands for an
unnamed socket: a connection made with `Socket.Unix` has it as its local endpoint, and a
connection accepted by a Unix listener has it as its remote endpoint.

-}
type Endpoint
    = Inet InetEndpoint
    | Unix Path


{-| An IP address and a port number.

`port_` has its underscore because `port` is a reserved word in Elm. It is a plain `Int`, and
the type does not restrict it to the port range 0–65535.

-}
type alias InetEndpoint =
    { address : Address
    , port_ : Int
    }



-- PARSING


{-| Parses dotted-decimal IPv4 text into the address as one 32-bit number, most significant byte
first.
-}
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


{-| Parses one field of an IPv4 address: 1 to 3 ASCII digits, no leading zero unless the field is
`0`, at most 255.
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


{-| Parses one group of an IPv6 address, 1 to 4 ASCII hexadecimal digits of either case, as a 16-bit
number.
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


{-| Returns the value of a hexadecimal digit of either case. Any other character gives a
meaningless number, so it is applied only to digits `parseGroup` has checked.
-}
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


{-| Parses the colon-separated groups on one side of an IPv6 address's `::`, or of the whole address
when there is no `::`, into 16-bit numbers; `""` has none. With `allowDotted`, the last field may
be a dotted IPv4 address, which gives two groups.
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


{-| Parses IPv6 text that has had its scope removed into an address carrying `scope`. Without `::`
the groups must number exactly 8; a `::` fills in at least one zero group to make 8. A dotted
IPv4 ending is accepted only after the `::`, or at the end of an address without one.
-}
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


{-| Tells whether text is an acceptable scope: 1 to 15 characters, each allowed by `isScopeChar`.
-}
isValidScope : String -> Bool
isValidScope scope =
    let
        len =
            String.length scope
    in
    len >= 1 && len <= 15 && String.all isScopeChar scope


{-| Tells whether a character may appear in a scope: an ASCII letter or digit, `_`, `.` or `-`.
-}
isScopeChar : Char -> Bool
isScopeChar c =
    Char.isAlphaNum c || c == '_' || c == '.' || c == '-'


{-| Returns the values of a list of `Maybe`s in order, or `Nothing` if any of them is `Nothing`.
-}
combine : List (Maybe a) -> Maybe (List a)
combine maybes =
    List.foldr (Maybe.map2 (::)) (Just []) maybes



-- PRINTING


{-| Splits an IPv4 address held as one 32-bit number into its four bytes, most significant first.
-}
v4Octets : Int -> List Int
v4Octets n =
    [ n // 0x01000000, modBy 256 (n // 0x00010000), modBy 256 (n // 256), modBy 256 n ]


{-| Returns the number that a list of bytes spells, most significant byte first.
-}
fromBytes : List Int -> Int
fromBytes octets =
    List.foldl (\o acc -> acc * 256 + o) 0 octets


{-| Prints bytes as decimal numbers joined by dots.
-}
dotted : List Int -> String
dotted octets =
    String.join "." (List.map String.fromInt octets)


{-| Tells whether the bytes of an IPv6 address begin with the IPv4-mapped prefix: ten zero bytes,
then two bytes of 255.
-}
isMappedOctets : List Int -> Bool
isMappedOctets octets =
    List.take 12 octets == List.repeat 10 0 ++ [ 255, 255 ]


{-| Pairs bytes into 16-bit groups, the first of each pair being the high byte. An odd byte left at
the end is dropped.
-}
groupsOf : List Int -> List Int
groupsOf octets =
    case octets of
        hi :: lo :: rest ->
            (hi * 256 + lo) :: groupsOf rest

        _ ->
            []


{-| Prints IPv6 groups as RFC 5952 text: lower-case hexadecimal without leading zeros, with the
longest run of two or more zero groups written `::`, the leftmost one when runs tie.
-}
compressGroups : List Int -> String
compressGroups groups =
    let
        hex =
            toHex

        -- Only a strictly longer run replaces the best, so the leftmost of equal runs wins.
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


{-| Prints a non-negative number in lower-case hexadecimal, without leading zeros.
-}
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
