module AddressTest exposing (suite)

{-| Tests for Socket.Address: the generated golden table (AddressGolden, from
scripts/gen-address-golden.py, which uses Python's `ipaddress` for validity) plus hand-written
cases for the rules in plans/eco-system-sockets.md Appendix D.1 (S1 step 3).
-}

import AddressGolden exposing (Case, Expected)
import Expect
import Socket.Address as Address exposing (Address, Family(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Socket.Address"
        [ describe ("golden (Python " ++ AddressGolden.pythonVersion ++ ")") (List.map goldenCase AddressGolden.cases)
        , fromOctetsTests
        , wellKnownTests
        , unmapTests
        ]



-- GOLDEN


goldenCase : Case -> Test
goldenCase c =
    test (Debug.toString c.input) <|
        \_ ->
            case ( Address.fromString c.input, c.expected ) of
                ( Nothing, Nothing ) ->
                    Expect.pass

                ( Just address, Nothing ) ->
                    Expect.fail ("accepted an invalid address, printed " ++ Address.toString address)

                ( Nothing, Just e ) ->
                    Expect.fail ("rejected a valid address, expected " ++ e.canonical)

                ( Just address, Just e ) ->
                    address |> Expect.all (expectations e)


familyNumber : Family -> Int
familyNumber fam =
    case fam of
        IPv4 ->
            4

        IPv6 ->
            6


expectations : Expected -> List (Address -> Expect.Expectation)
expectations e =
    [ \a -> Address.toString a |> Expect.equal e.canonical
    , \a -> Address.toOctets a |> Expect.equal e.octets
    , \a -> familyNumber (Address.family a) |> Expect.equal e.family
    , \a -> Address.isLoopback a |> Expect.equal e.isLoopback
    , \a -> Address.isUnspecified a |> Expect.equal e.isUnspecified
    , \a -> Address.isIPv4Mapped a |> Expect.equal e.isIPv4Mapped
    , \a -> Address.toString (Address.unmapIPv4 a) |> Expect.equal e.unmapped

    -- The canonical text reads back as the same address.
    , \a -> Address.fromString (Address.toString a) |> Expect.equal (Just a)

    -- The octets rebuild the address, without its scope.
    , \a ->
        Address.fromOctets (Address.toOctets a)
            |> Maybe.map Address.toString
            |> Expect.equal (Just (withoutScope e.canonical))
    ]


withoutScope : String -> String
withoutScope text =
    case String.split "%" text of
        body :: _ ->
            body

        [] ->
            text



-- fromOctets


fromOctetsTests : Test
fromOctetsTests =
    describe "fromOctets"
        [ test "4 octets: IPv4" <|
            \_ ->
                Address.fromOctets [ 192, 0, 2, 1 ]
                    |> Maybe.map Address.toString
                    |> Expect.equal (Just "192.0.2.1")
        , test "16 octets: IPv6" <|
            \_ ->
                Address.fromOctets [ 0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                    |> Maybe.map Address.toString
                    |> Expect.equal (Just "2001:db8::1")
        , test "extremes" <|
            \_ ->
                ( Address.fromOctets [ 0, 0, 0, 0 ] |> Maybe.map Address.toString
                , Address.fromOctets [ 255, 255, 255, 255 ] |> Maybe.map Address.toString
                , Address.fromOctets (List.repeat 16 255) |> Maybe.map Address.toString
                )
                    |> Expect.equal
                        ( Just "0.0.0.0"
                        , Just "255.255.255.255"
                        , Just "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
                        )
        , test "IPv4-mapped octets give an IPv6 address" <|
            \_ ->
                Address.fromOctets (List.repeat 10 0 ++ [ 255, 255, 127, 0, 0, 1 ])
                    |> Maybe.map (\a -> ( Address.family a, Address.toString a ))
                    |> Expect.equal (Just ( IPv6, "::ffff:127.0.0.1" ))
        , test "wrong lengths" <|
            \_ ->
                [ [], [ 1 ], [ 1, 2, 3 ], [ 1, 2, 3, 4, 5 ], List.repeat 15 0, List.repeat 17 0, List.repeat 32 0 ]
                    |> List.map Address.fromOctets
                    |> Expect.equal (List.repeat 7 Nothing)
        , test "values out of range" <|
            \_ ->
                [ [ 256, 0, 0, 1 ], [ 1, 2, 3, -1 ], List.repeat 15 0 ++ [ 256 ], -1 :: List.repeat 15 0 ]
                    |> List.map Address.fromOctets
                    |> Expect.equal (List.repeat 4 Nothing)
        , test "no scope" <|
            \_ ->
                Address.fromString "fe80::1%eth0"
                    |> Maybe.map Address.toOctets
                    |> Maybe.andThen Address.fromOctets
                    |> Expect.equal (Address.fromString "fe80::1")
        ]



-- loopback / any


wellKnownTests : Test
wellKnownTests =
    describe "loopback / any"
        [ test "loopback IPv4" <|
            \_ ->
                Address.loopback IPv4 |> Expect.equal (parse "127.0.0.1")
        , test "loopback IPv6" <|
            \_ ->
                Address.loopback IPv6 |> Expect.equal (parse "::1")
        , test "any IPv4" <|
            \_ ->
                Address.any IPv4 |> Expect.equal (parse "0.0.0.0")
        , test "any IPv6" <|
            \_ ->
                Address.any IPv6 |> Expect.equal (parse "::")
        , test "predicates" <|
            \_ ->
                [ Address.loopback IPv4, Address.loopback IPv6, Address.any IPv4, Address.any IPv6 ]
                    |> List.map (\a -> ( Address.isLoopback a, Address.isUnspecified a, Address.family a ))
                    |> Expect.equal
                        [ ( True, False, IPv4 )
                        , ( True, False, IPv6 )
                        , ( False, True, IPv4 )
                        , ( False, True, IPv6 )
                        ]
        , test "scopes are compared" <|
            \_ ->
                ( parse "fe80::1%eth0" == parse "fe80::1%eth1", parse "fe80::1%eth0" == parse "FE80::0:1%eth0" )
                    |> Expect.equal ( False, True )
        ]



-- unmapIPv4


unmapTests : Test
unmapTests =
    describe "unmapIPv4"
        [ test "a mapped address becomes IPv4 (scope dropped)" <|
            \_ ->
                Address.unmapIPv4 (parse "::ffff:127.0.0.1%lo") |> Expect.equal (parse "127.0.0.1")
        , test "an IPv4-compatible address is unchanged" <|
            \_ ->
                Address.unmapIPv4 (parse "::127.0.0.1") |> Expect.equal (parse "::127.0.0.1")
        , test "IPv4 is unchanged" <|
            \_ ->
                Address.unmapIPv4 (parse "10.0.0.1") |> Expect.equal (parse "10.0.0.1")
        ]


{-| Parse a known-valid address (the unspecified IPv4 address when it does not parse, which
makes the comparing test fail).
-}
parse : String -> Address
parse text =
    Address.fromString text |> Maybe.withDefault (Address.any IPv4)
