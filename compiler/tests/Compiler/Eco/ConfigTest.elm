module Compiler.Eco.ConfigTest exposing (suite)

{-| Tests that a `mono` object in `eco-config.json` which sets some of its keys
but not `engine` keeps the monomorphizer engine of `Compiler.Eco.Config.default`.

`Config.decoder` treats the file as a partial override of `default`, so a
missing key keeps its default value. Without these tests, a fallback for a
missing `engine` that differs from `default`'s would go unnoticed: setting one
lambda-set (LSS) setting or one watchdog limit would then also switch engines.

The fixtures are short JSON documents written inline, each decoded with
`Config.decoder` through `Compiler.Json.Decode.fromByteString`; only the
decoded `mono.engine` is compared.

What the tests establish:

  - A document with no `mono` object decodes to `default`'s engine.
  - A `mono` object with only `lss`, with only `limits`, or with no keys
    decodes to `default`'s engine.
  - An explicit `"engine": "subst"` decodes to `EngineSubst`.

Among what is not tested: the `"solver"` and `"diff"` engine strings, an
unrecognized engine string, and every setting other than `mono.engine`.

-}

import Compiler.Eco.Config as Config
import Compiler.Json.Decode as D
import Expect
import Test exposing (Test)


{-| Returns the `mono.engine` that `Config.decoder` reads from the JSON text
`src`, or, when decoding fails, an error message quoting `src`.
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


{-| The tests of the `mono.engine` fallback, as the module docstring lists
them.
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
