module AddressGolden exposing (Case, Expected, cases, pythonVersion)

{-| GENERATED FILE — do not edit.

Golden table for Socket.Address (150 inputs, 68 valid), produced by
scripts/gen-address-golden.py with Python 3.11.2 (`ipaddress` for validity and the compressed
IPv6 text; IPv4-mapped printing, octets and predicates computed by the script per
plans/eco-system-sockets.md Appendix D.1).

Regenerate from system-kernel-cpp/ with:

    python3 scripts/gen-address-golden.py

-}


{-| The Python version that produced the table.
-}
pythonVersion : String
pythonVersion =
    "3.11.2"


{-| `family` is 4 or 6; `unmapped` is `toString (unmapIPv4 address)`.
-}
type alias Expected =
    { canonical : String
    , octets : List Int
    , family : Int
    , isLoopback : Bool
    , isUnspecified : Bool
    , isIPv4Mapped : Bool
    , unmapped : String
    }


{-| `expected` is `Nothing` for an input that is not a valid address.
-}
type alias Case =
    { input : String
    , expected : Maybe Expected
    }


cases : List Case
cases =
    [ { input = "0.0.0.0"
      , expected =
            Just
                { canonical = "0.0.0.0"
                , octets = [ 0, 0, 0, 0 ]
                , family = 4
                , isLoopback = False
                , isUnspecified = True
                , isIPv4Mapped = False
                , unmapped = "0.0.0.0"
                }
      }
    , { input = "127.0.0.1"
      , expected =
            Just
                { canonical = "127.0.0.1"
                , octets = [ 127, 0, 0, 1 ]
                , family = 4
                , isLoopback = True
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "127.0.0.1"
                }
      }
    , { input = "127.255.255.254"
      , expected =
            Just
                { canonical = "127.255.255.254"
                , octets = [ 127, 255, 255, 254 ]
                , family = 4
                , isLoopback = True
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "127.255.255.254"
                }
      }
    , { input = "126.255.255.255"
      , expected =
            Just
                { canonical = "126.255.255.255"
                , octets = [ 126, 255, 255, 255 ]
                , family = 4
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "126.255.255.255"
                }
      }
    , { input = "128.0.0.1"
      , expected =
            Just
                { canonical = "128.0.0.1"
                , octets = [ 128, 0, 0, 1 ]
                , family = 4
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "128.0.0.1"
                }
      }
    , { input = "1.2.3.4"
      , expected =
            Just
                { canonical = "1.2.3.4"
                , octets = [ 1, 2, 3, 4 ]
                , family = 4
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1.2.3.4"
                }
      }
    , { input = "10.0.0.255"
      , expected =
            Just
                { canonical = "10.0.0.255"
                , octets = [ 10, 0, 0, 255 ]
                , family = 4
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "10.0.0.255"
                }
      }
    , { input = "192.168.1.10"
      , expected =
            Just
                { canonical = "192.168.1.10"
                , octets = [ 192, 168, 1, 10 ]
                , family = 4
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "192.168.1.10"
                }
      }
    , { input = "255.255.255.255"
      , expected =
            Just
                { canonical = "255.255.255.255"
                , octets = [ 255, 255, 255, 255 ]
                , family = 4
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "255.255.255.255"
                }
      }
    , { input = "1.2.3", expected = Nothing }
    , { input = "1.2.3.4.5", expected = Nothing }
    , { input = "01.2.3.4", expected = Nothing }
    , { input = "1.02.3.4", expected = Nothing }
    , { input = "1.2.3.00", expected = Nothing }
    , { input = "00.0.0.0", expected = Nothing }
    , { input = "256.0.0.1", expected = Nothing }
    , { input = "1.2.3.256", expected = Nothing }
    , { input = "999.0.0.0", expected = Nothing }
    , { input = "1234.1.1.1", expected = Nothing }
    , { input = "1.2.3.-1", expected = Nothing }
    , { input = "+1.2.3.4", expected = Nothing }
    , { input = "0x1.2.3.4", expected = Nothing }
    , { input = "1.2.3.a", expected = Nothing }
    , { input = "1..3.4", expected = Nothing }
    , { input = "1.2.3.", expected = Nothing }
    , { input = ".1.2.3", expected = Nothing }
    , { input = "1.2.3.4.", expected = Nothing }
    , { input = "1,2,3,4", expected = Nothing }
    , { input = "\u{0661}.2.3.4", expected = Nothing }
    , { input = "1.2.3.4%eth0", expected = Nothing }
    , { input = "1.2.3.4%1", expected = Nothing }
    , { input = "", expected = Nothing }
    , { input = " ", expected = Nothing }
    , { input = "\t", expected = Nothing }
    , { input = "localhost", expected = Nothing }
    , { input = " 1.2.3.4", expected = Nothing }
    , { input = "1.2.3.4 ", expected = Nothing }
    , { input = "1.2.3.4\n", expected = Nothing }
    , { input = "::"
      , expected =
            Just
                { canonical = "::"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = True
                , isIPv4Mapped = False
                , unmapped = "::"
                }
      }
    , { input = "::0"
      , expected =
            Just
                { canonical = "::"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = True
                , isIPv4Mapped = False
                , unmapped = "::"
                }
      }
    , { input = "0::0"
      , expected =
            Just
                { canonical = "::"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = True
                , isIPv4Mapped = False
                , unmapped = "::"
                }
      }
    , { input = "::1"
      , expected =
            Just
                { canonical = "::1"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = True
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "::1"
                }
      }
    , { input = "::0:1"
      , expected =
            Just
                { canonical = "::1"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = True
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "::1"
                }
      }
    , { input = "1::"
      , expected =
            Just
                { canonical = "1::"
                , octets = [ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1::"
                }
      }
    , { input = "1::8"
      , expected =
            Just
                { canonical = "1::8"
                , octets = [ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1::8"
                }
      }
    , { input = "0:0:0:0:0:0:0:0"
      , expected =
            Just
                { canonical = "::"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = True
                , isIPv4Mapped = False
                , unmapped = "::"
                }
      }
    , { input = "0:0:0:0:0:0:0:1"
      , expected =
            Just
                { canonical = "::1"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = True
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "::1"
                }
      }
    , { input = "1:2:3:4:5:6:7:8"
      , expected =
            Just
                { canonical = "1:2:3:4:5:6:7:8"
                , octets = [ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1:2:3:4:5:6:7:8"
                }
      }
    , { input = "1:2:3:4:5:6:7::"
      , expected =
            Just
                { canonical = "1:2:3:4:5:6:7:0"
                , octets = [ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1:2:3:4:5:6:7:0"
                }
      }
    , { input = "::2:3:4:5:6:7:8"
      , expected =
            Just
                { canonical = "0:2:3:4:5:6:7:8"
                , octets = [ 0, 0, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "0:2:3:4:5:6:7:8"
                }
      }
    , { input = "1::2:3:4:5:6:7"
      , expected =
            Just
                { canonical = "1:0:2:3:4:5:6:7"
                , octets = [ 0, 1, 0, 0, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1:0:2:3:4:5:6:7"
                }
      }
    , { input = "1:2:3:4:5:6::8"
      , expected =
            Just
                { canonical = "1:2:3:4:5:6:0:8"
                , octets = [ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 0, 0, 8 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1:2:3:4:5:6:0:8"
                }
      }
    , { input = "0001:0002::0003"
      , expected =
            Just
                { canonical = "1:2::3"
                , octets = [ 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1:2::3"
                }
      }
    , { input = "2001:db8::1"
      , expected =
            Just
                { canonical = "2001:db8::1"
                , octets = [ 32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "2001:db8::1"
                }
      }
    , { input = "2001:DB8::1"
      , expected =
            Just
                { canonical = "2001:db8::1"
                , octets = [ 32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "2001:db8::1"
                }
      }
    , { input = "2001:0db8:0000:0000:0000:0000:0000:0001"
      , expected =
            Just
                { canonical = "2001:db8::1"
                , octets = [ 32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "2001:db8::1"
                }
      }
    , { input = "2001:db8:0:0:1:0:0:1"
      , expected =
            Just
                { canonical = "2001:db8::1:0:0:1"
                , octets = [ 32, 1, 13, 184, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "2001:db8::1:0:0:1"
                }
      }
    , { input = "2001:db8::1:0:0:1"
      , expected =
            Just
                { canonical = "2001:db8::1:0:0:1"
                , octets = [ 32, 1, 13, 184, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "2001:db8::1:0:0:1"
                }
      }
    , { input = "2001:0:0:1:0:0:0:1"
      , expected =
            Just
                { canonical = "2001:0:0:1::1"
                , octets = [ 32, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "2001:0:0:1::1"
                }
      }
    , { input = "2001:db8:0:1:1:1:1:1"
      , expected =
            Just
                { canonical = "2001:db8:0:1:1:1:1:1"
                , octets = [ 32, 1, 13, 184, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "2001:db8:0:1:1:1:1:1"
                }
      }
    , { input = "1:0:2:0:3:0:4:0"
      , expected =
            Just
                { canonical = "1:0:2:0:3:0:4:0"
                , octets = [ 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1:0:2:0:3:0:4:0"
                }
      }
    , { input = "0:1:2:3:4:5:6:7"
      , expected =
            Just
                { canonical = "0:1:2:3:4:5:6:7"
                , octets = [ 0, 0, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "0:1:2:3:4:5:6:7"
                }
      }
    , { input = "1:2:3:4:5:6:7:0"
      , expected =
            Just
                { canonical = "1:2:3:4:5:6:7:0"
                , octets = [ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1:2:3:4:5:6:7:0"
                }
      }
    , { input = "0:0:1:2:3:4:5:6"
      , expected =
            Just
                { canonical = "::1:2:3:4:5:6"
                , octets = [ 0, 0, 0, 0, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "::1:2:3:4:5:6"
                }
      }
    , { input = "1:2:3:4:5:6:0:0"
      , expected =
            Just
                { canonical = "1:2:3:4:5:6::"
                , octets = [ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 0, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1:2:3:4:5:6::"
                }
      }
    , { input = "1:0:0:2:0:0:0:3"
      , expected =
            Just
                { canonical = "1:0:0:2::3"
                , octets = [ 0, 1, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1:0:0:2::3"
                }
      }
    , { input = "ff02::1"
      , expected =
            Just
                { canonical = "ff02::1"
                , octets = [ 255, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "ff02::1"
                }
      }
    , { input = "FFFF::"
      , expected =
            Just
                { canonical = "ffff::"
                , octets = [ 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "ffff::"
                }
      }
    , { input = "abcd:ef01:2345:6789:ABCD:EF01:2345:6789"
      , expected =
            Just
                { canonical = "abcd:ef01:2345:6789:abcd:ef01:2345:6789"
                , octets = [ 171, 205, 239, 1, 35, 69, 103, 137, 171, 205, 239, 1, 35, 69, 103, 137 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "abcd:ef01:2345:6789:abcd:ef01:2345:6789"
                }
      }
    , { input = "Fe80::A:b:C:d"
      , expected =
            Just
                { canonical = "fe80::a:b:c:d"
                , octets = [ 254, 128, 0, 0, 0, 0, 0, 0, 0, 10, 0, 11, 0, 12, 0, 13 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "fe80::a:b:c:d"
                }
      }
    , { input = "::ffff:127.0.0.1"
      , expected =
            Just
                { canonical = "::ffff:127.0.0.1"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 127, 0, 0, 1 ]
                , family = 6
                , isLoopback = True
                , isUnspecified = False
                , isIPv4Mapped = True
                , unmapped = "127.0.0.1"
                }
      }
    , { input = "::FFFF:7f00:1"
      , expected =
            Just
                { canonical = "::ffff:127.0.0.1"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 127, 0, 0, 1 ]
                , family = 6
                , isLoopback = True
                , isUnspecified = False
                , isIPv4Mapped = True
                , unmapped = "127.0.0.1"
                }
      }
    , { input = "::ffff:127.255.0.1"
      , expected =
            Just
                { canonical = "::ffff:127.255.0.1"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 127, 255, 0, 1 ]
                , family = 6
                , isLoopback = True
                , isUnspecified = False
                , isIPv4Mapped = True
                , unmapped = "127.255.0.1"
                }
      }
    , { input = "::ffff:0.0.0.0"
      , expected =
            Just
                { canonical = "::ffff:0.0.0.0"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = True
                , unmapped = "0.0.0.0"
                }
      }
    , { input = "::ffff:0:0"
      , expected =
            Just
                { canonical = "::ffff:0.0.0.0"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = True
                , unmapped = "0.0.0.0"
                }
      }
    , { input = "::ffff:192.168.1.1"
      , expected =
            Just
                { canonical = "::ffff:192.168.1.1"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 192, 168, 1, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = True
                , unmapped = "192.168.1.1"
                }
      }
    , { input = "::ffff:128.0.0.1"
      , expected =
            Just
                { canonical = "::ffff:128.0.0.1"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 128, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = True
                , unmapped = "128.0.0.1"
                }
      }
    , { input = "::ffff:1:2"
      , expected =
            Just
                { canonical = "::ffff:0.1.0.2"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 1, 0, 2 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = True
                , unmapped = "0.1.0.2"
                }
      }
    , { input = "0:0:0:0:0:ffff:127.0.0.1"
      , expected =
            Just
                { canonical = "::ffff:127.0.0.1"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 127, 0, 0, 1 ]
                , family = 6
                , isLoopback = True
                , isUnspecified = False
                , isIPv4Mapped = True
                , unmapped = "127.0.0.1"
                }
      }
    , { input = "0:0:0:0:0:FFFF:0a00:0001"
      , expected =
            Just
                { canonical = "::ffff:10.0.0.1"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 10, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = True
                , unmapped = "10.0.0.1"
                }
      }
    , { input = "::fffe:1.2.3.4"
      , expected =
            Just
                { canonical = "::fffe:102:304"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 254, 1, 2, 3, 4 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "::fffe:102:304"
                }
      }
    , { input = "::127.0.0.1"
      , expected =
            Just
                { canonical = "::7f00:1"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "::7f00:1"
                }
      }
    , { input = "::1.2.3.4"
      , expected =
            Just
                { canonical = "::102:304"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "::102:304"
                }
      }
    , { input = "::0.0.0.1"
      , expected =
            Just
                { canonical = "::1"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = True
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "::1"
                }
      }
    , { input = "64:ff9b::1.2.3.4"
      , expected =
            Just
                { canonical = "64:ff9b::102:304"
                , octets = [ 0, 100, 255, 155, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "64:ff9b::102:304"
                }
      }
    , { input = "1:2:3:4:5:6:1.2.3.4"
      , expected =
            Just
                { canonical = "1:2:3:4:5:6:102:304"
                , octets = [ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 1, 2, 3, 4 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "1:2:3:4:5:6:102:304"
                }
      }
    , { input = "::1:ffff:1.2.3.4"
      , expected =
            Just
                { canonical = "::1:ffff:102:304"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 255, 255, 1, 2, 3, 4 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "::1:ffff:102:304"
                }
      }
    , { input = "fe80::1%eth0"
      , expected =
            Just
                { canonical = "fe80::1%eth0"
                , octets = [ 254, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "fe80::1%eth0"
                }
      }
    , { input = "fe80::1%1"
      , expected =
            Just
                { canonical = "fe80::1%1"
                , octets = [ 254, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "fe80::1%1"
                }
      }
    , { input = "fe80::1%en0.100"
      , expected =
            Just
                { canonical = "fe80::1%en0.100"
                , octets = [ 254, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "fe80::1%en0.100"
                }
      }
    , { input = "fe80::1%a_b-c.d"
      , expected =
            Just
                { canonical = "fe80::1%a_b-c.d"
                , octets = [ 254, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "fe80::1%a_b-c.d"
                }
      }
    , { input = "fe80::1%ETH0"
      , expected =
            Just
                { canonical = "fe80::1%ETH0"
                , octets = [ 254, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "fe80::1%ETH0"
                }
      }
    , { input = "fe80::1%123456789012345"
      , expected =
            Just
                { canonical = "fe80::1%123456789012345"
                , octets = [ 254, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "fe80::1%123456789012345"
                }
      }
    , { input = "::1%lo"
      , expected =
            Just
                { canonical = "::1%lo"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 ]
                , family = 6
                , isLoopback = True
                , isUnspecified = False
                , isIPv4Mapped = False
                , unmapped = "::1%lo"
                }
      }
    , { input = "::%lo"
      , expected =
            Just
                { canonical = "::%lo"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = True
                , isIPv4Mapped = False
                , unmapped = "::%lo"
                }
      }
    , { input = "::ffff:127.0.0.1%lo"
      , expected =
            Just
                { canonical = "::ffff:127.0.0.1%lo"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 127, 0, 0, 1 ]
                , family = 6
                , isLoopback = True
                , isUnspecified = False
                , isIPv4Mapped = True
                , unmapped = "127.0.0.1"
                }
      }
    , { input = "::ffff:1.2.3.4%2"
      , expected =
            Just
                { canonical = "::ffff:1.2.3.4%2"
                , octets = [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 1, 2, 3, 4 ]
                , family = 6
                , isLoopback = False
                , isUnspecified = False
                , isIPv4Mapped = True
                , unmapped = "1.2.3.4"
                }
      }
    , { input = ":", expected = Nothing }
    , { input = ":::", expected = Nothing }
    , { input = "::::", expected = Nothing }
    , { input = "1:2:3:4:5:6:7", expected = Nothing }
    , { input = "1:2:3:4:5:6:7:8:9", expected = Nothing }
    , { input = "1::2::3", expected = Nothing }
    , { input = "::1::", expected = Nothing }
    , { input = "1:2:3:4:5:6:7:8::", expected = Nothing }
    , { input = "::1:2:3:4:5:6:7:8", expected = Nothing }
    , { input = "1:2:3:4::5:6:7:8", expected = Nothing }
    , { input = ":1::", expected = Nothing }
    , { input = "::1:", expected = Nothing }
    , { input = "1:", expected = Nothing }
    , { input = ":1", expected = Nothing }
    , { input = "1:::2", expected = Nothing }
    , { input = ":1:2:3:4:5:6:7:8", expected = Nothing }
    , { input = "1:2:3:4:5:6:7:8:", expected = Nothing }
    , { input = "[::1]", expected = Nothing }
    , { input = "12345::", expected = Nothing }
    , { input = "::12345", expected = Nothing }
    , { input = "g::1", expected = Nothing }
    , { input = "::g", expected = Nothing }
    , { input = "0x1::", expected = Nothing }
    , { input = "::-1", expected = Nothing }
    , { input = "::+1", expected = Nothing }
    , { input = "1:2:3:4:5:6:7:8 ", expected = Nothing }
    , { input = " ::1", expected = Nothing }
    , { input = "::1 ", expected = Nothing }
    , { input = ":: 1", expected = Nothing }
    , { input = "::\u{0661}", expected = Nothing }
    , { input = "1.2.3.4::", expected = Nothing }
    , { input = "::1.2.3", expected = Nothing }
    , { input = "::01.2.3.4", expected = Nothing }
    , { input = "::256.0.0.1", expected = Nothing }
    , { input = "::1.2.3.4.5", expected = Nothing }
    , { input = "::1.2.3.4:5", expected = Nothing }
    , { input = "::1.2.3.4:1.2.3.4", expected = Nothing }
    , { input = "1:2:3:4:5:6:7:1.2.3.4", expected = Nothing }
    , { input = "1:2:3:4:5:6:7:8:1.2.3.4", expected = Nothing }
    , { input = "::ffff:1.2.3.4.", expected = Nothing }
    , { input = "::1%", expected = Nothing }
    , { input = "::1%%eth0", expected = Nothing }
    , { input = "::1%eth0%1", expected = Nothing }
    , { input = "::1%eth 0", expected = Nothing }
    , { input = "::1%1234567890123456", expected = Nothing }
    , { input = "::1%eth0/", expected = Nothing }
    , { input = "::1%eth0:1", expected = Nothing }
    , { input = "::1%\u{00E9}", expected = Nothing }
    , { input = "fe80::1%eth0 ", expected = Nothing }
    , { input = "%eth0", expected = Nothing }
    , { input = "%", expected = Nothing }
    , { input = "::ffff:1.2.3.4%", expected = Nothing }
    , { input = "1:2:3:4:5:6:7:8%", expected = Nothing }
    ]
