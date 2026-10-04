module TestLogic.GlobalOpt.BorrowOracleOptConfigTest exposing (suite)

{-| `Compiler.Eco.Config.hash` adds a token for the borrow setting `oracleOpt`
when it is on, so a configuration hashes differently from the same configuration
with it off. Without these tests, `hash` could leave the setting out and nothing
would notice.

`Config.hash` turns a configuration into a string of `|`-separated tokens, which
`Builder.Elm.Details` uses as a cache key. Which settings add a token, and when,
is stated in `Compiler.Eco.Config`. The token for `oracleOpt` is `bopt=1`.

The fixture is `Config.default`, changed only in its `borrow` settings.

The tests establish:

  - Setting `oracleOpt` to `False` in `default` leaves the hash equal to that of
    `default`. Because `oracleOpt` is off in `default`, the two configurations
    are equal, so this test pins only that `default` keeps it off.
  - Setting `oracleOpt` to `True` in `default` gives a hash that differs from
    that of `default` and contains `bopt=1`.
  - Switching on `enabled`, `report` and `validate` together in `default` leaves
    the hash equal to that of `default`.

Among what is not tested: the `reify` setting, which is never varied;
`enabled`, `report` and `validate` one at a time; `oracleOpt` on any
configuration other than `default`; and where in the hash the `bopt=1` token
sits.

-}

import Compiler.Eco.Config as Config
import Expect
import Test exposing (Test)


{-| The three tests on how the borrow settings reach the configuration hash.
-}
suite : Test
suite =
    Test.describe "OC0.1 borrow.oracleOpt hash token"
        [ Test.test "oracleOpt=False hashes identically to default (cache continuity)" <|
            \_ ->
                Expect.equal
                    (Config.hash Config.default)
                    (Config.hash (withOracleOpt False Config.default))
        , Test.test "oracleOpt=True changes the hash and carries bopt=1" <|
            \_ ->
                let
                    onHash =
                        Config.hash (withOracleOpt True Config.default)
                in
                if onHash == Config.hash Config.default then
                    Expect.fail "borrow.oracleOpt=True must change Config.hash (cache-poisoning hazard)"

                else if String.contains "bopt=1" onHash then
                    Expect.pass

                else
                    Expect.fail ("bopt=1 token missing from: " ++ onHash)
        , Test.test "the rest of the borrow block stays hash-inert" <|
            \_ ->
                let
                    d =
                        Config.default

                    borrow =
                        d.borrow

                    noisy =
                        { d | borrow = { borrow | enabled = True, report = True, validate = True } }
                in
                Expect.equal (Config.hash d) (Config.hash noisy)
        ]


{-| Returns `cfg` with its borrow setting `oracleOpt` set to `v` and every other
setting unchanged.
-}
withOracleOpt : Bool -> Config.EcoConfig -> Config.EcoConfig
withOracleOpt v cfg =
    let
        borrow =
            cfg.borrow
    in
    { cfg | borrow = { borrow | oracleOpt = v } }
