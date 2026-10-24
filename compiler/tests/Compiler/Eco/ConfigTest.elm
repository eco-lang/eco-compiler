module Compiler.Eco.ConfigTest exposing (suite)

{-| Tests that `Compiler.Eco.Config.decoder` keeps the default monomorphizer
engine when an `eco-config.json` overrides only part of the `mono` object.

SD-2: `monoDecoder` reads a missing `engine` key as the string `"subst"`, so a
document whose `mono` object sets only `lss` or `limits` selects `EngineSubst`,
while `Config.default` (and a document with no `mono` object at all) selects
`EngineSolver`. Setting one LSS knob or one watchdog limit therefore silently
switches engines and turns lambda-set specialization off, against the module's
own rule that a missing key takes its value from `default`.

What the tests establish:

  - A document with no `mono` object decodes to `default`'s engine (a control
    that passes today).
  - A `mono` object with only `lss`, only `limits`, or no keys at all decodes
    to `default`'s engine. These fail while the missing-`engine` fallback is
    `"subst"`.
  - An explicit `"engine": "subst"` still selects `EngineSubst`.

-}

import Compiler.Eco.Config as Config
import Compiler.Json.Decode as D
import Expect
import Test exposing (Test)


{-| The engine `src` decodes to, or the decode failure rendered as a string.
-}
engineOf : String -> Result String Config.MonoEngine
engineOf src =
    let
        decoder : D.Decoder () Config.EcoConfig
        decoder =
            Config.decoder
    in
    case D.fromByteString decoder src of
        Ok cfg ->
            Ok cfg.mono.engine

        Err _ ->
            Err ("eco-config did not decode: " ++ src)


{-| The SD-2 tests.
-}
suite : Test
suite =
    Test.describe "SD-2: Config.decoder mono.engine default"
        [ Test.test "no mono object keeps default's engine (control)" <|
            \_ ->
                engineOf "{ \"cse\": { \"enabled\": true } }"
                    |> Expect.equal (Ok Config.default.mono.engine)
        , Test.test "SD-2: mono with only lss keeps default's engine" <|
            \_ ->
                engineOf "{ \"mono\": { \"lss\": { \"maxSetSize\": 8 } } }"
                    |> Expect.equal (Ok Config.default.mono.engine)
        , Test.test "SD-2: mono with only limits keeps default's engine" <|
            \_ ->
                engineOf "{ \"mono\": { \"limits\": { \"specBreadth\": 1000 } } }"
                    |> Expect.equal (Ok Config.default.mono.engine)
        , Test.test "SD-2: empty mono object keeps default's engine" <|
            \_ ->
                engineOf "{ \"mono\": {} }"
                    |> Expect.equal (Ok Config.default.mono.engine)
        , Test.test "explicit engine subst still selects EngineSubst" <|
            \_ ->
                engineOf "{ \"mono\": { \"engine\": \"subst\" } }"
                    |> Expect.equal (Ok Config.EngineSubst)
        ]
