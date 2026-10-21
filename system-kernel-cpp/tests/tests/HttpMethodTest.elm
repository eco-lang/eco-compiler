module HttpMethodTest exposing (suite)

{-| Tests `Http.Method.fromString` and `Http.Method.toString` (plans/eco-system-typed-api.md A1).

What the tests establish:

  - Every listed method, `OPTIONS` included, round-trips: `fromString (toString m) == m`, and its
    name is the constructor's.
  - `fromString` matches exactly: a name in another case, or an unlisted one, is `UNKNOWN` with
    the name as given, and `toString (UNKNOWN name)` gives the name back.

-}

import Expect
import Http.Method as Method exposing (Method(..))
import Test exposing (Test, describe, test)


listed : List ( Method, String )
listed =
    [ ( GET, "GET" )
    , ( HEAD, "HEAD" )
    , ( POST, "POST" )
    , ( PUT, "PUT" )
    , ( DELETE, "DELETE" )
    , ( CONNECT, "CONNECT" )
    , ( OPTIONS, "OPTIONS" )
    , ( TRACE, "TRACE" )
    , ( PATCH, "PATCH" )
    ]


suite : Test
suite =
    describe "Http.Method"
        [ describe "listed methods"
            (List.map
                (\( method, name ) ->
                    test name <|
                        \_ ->
                            Expect.all
                                [ \_ -> Method.toString method |> Expect.equal name
                                , \_ -> Method.fromString name |> Expect.equal method
                                ]
                                ()
                )
                listed
            )
        , test "OPTIONS is its own constructor, not UNKNOWN" <|
            \_ -> Method.fromString "OPTIONS" |> Expect.equal OPTIONS
        , test "names match exactly: another case is UNKNOWN" <|
            \_ -> Method.fromString "get" |> Expect.equal (UNKNOWN "get")
        , test "an unlisted method is UNKNOWN with its name" <|
            \_ -> Method.fromString "PROPFIND" |> Expect.equal (UNKNOWN "PROPFIND")
        , test "toString of UNKNOWN gives the name back" <|
            \_ -> Method.toString (UNKNOWN "PROPFIND") |> Expect.equal "PROPFIND"
        ]
