module TestLogic.GlobalOpt.BorrowOracleOptConfigTest exposing (suite)

{-| OC0.1 (plans/borrow-oracle-consumers.md): the `bopt=1` hash token.

The borrow config block is otherwise hash-inert (enabled/reify/report/
validate mint no token), so `borrow.oracleOpt` — the first artifact-affecting
borrow mode — must key caches: on-vs-off hashes differ, and off hashes
exactly like the historical default (cache continuity, the `aggp` posture).

-}

import Compiler.Eco.Config as Config
import Expect
import Test exposing (Test)


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


withOracleOpt : Bool -> Config.EcoConfig -> Config.EcoConfig
withOracleOpt v cfg =
    let
        borrow =
            cfg.borrow
    in
    { cfg | borrow = { borrow | oracleOpt = v } }
