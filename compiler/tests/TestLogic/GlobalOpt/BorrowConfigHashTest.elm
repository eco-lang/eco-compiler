module TestLogic.GlobalOpt.BorrowConfigHashTest exposing (suite)

{-| `Compiler.Eco.Config.hash` adds no token for any borrow setting: borrow
inference returns the program unchanged, so a borrow setting cannot change the
emitted code and must not split the build cache.

What is tested:

  - Switching on `enabled`, `report` and `validate` together in `default` leaves
    the hash equal to that of `default`.

Among what is not tested: the `reify` setting, which is never varied, and
`enabled`, `report` and `validate` one at a time.

-}

import Compiler.Eco.Config as Config
import Expect
import Test exposing (Test)


{-| The test on how the borrow settings reach the configuration hash.
-}
suite : Test
suite =
    Test.describe "borrow settings are hash-inert"
        [ Test.test "the borrow block stays hash-inert" <|
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
