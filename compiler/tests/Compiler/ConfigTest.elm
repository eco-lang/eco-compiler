module Compiler.ConfigTest exposing (suite)

{-| Tests that a `mono` object in `eco-config.json` which sets some of its keys
but not `engine` keeps the monomorphizer engine of `Compiler.Config.default`.

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

It also tests inliner whitelist and blacklist names
(plans/seqdict-hash-once-per-function.md, A1):

  - `Config.parseInlineName` reads `package:Module.name` and a bare
    `Module.name` (module = everything before the last `.`), and rejects an
    entry with no `.`, an empty module part or name, more than one `:`, or a
    package that is not two non-empty names around one `/`.
  - `Config.clamp` drops a malformed `inline.whitelist` or `inline.blacklist`
    entry with one warning each and keeps the well-formed ones in order.
  - `cse.hashMerge` is on by default and decodes from the file.

Among what is not tested: the `"solver"` and `"diff"` engine strings, an
unrecognized engine string, and every other setting.

-}

import Compiler.Config as Config
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
        , inlineNameTests
        , Test.test "cse.hashMerge is on by default and decodes from the file" <|
            \_ ->
                Expect.equal ( True, Ok False )
                    ( Config.default.cse.hashMerge
                    , decodeWith (\cfg -> cfg.cse.hashMerge) "{ \"cse\": { \"hashMerge\": false } }"
                    )
        ]


{-| Returns `f` of the configuration `Config.decoder` reads from `src`, or an
error message quoting `src`.
-}
decodeWith : (Config.EcoConfig -> a) -> String -> Result String a
decodeWith f src =
    let
        decoder : D.Decoder () Config.EcoConfig
        decoder =
            Config.decoder
    in
    case D.fromByteString decoder src of
        Ok cfg ->
            Ok (f cfg)

        Err _ ->
            Err ("eco-config did not decode: " ++ src)


{-| The `parseInlineName` and `clamp` tests of the module docstring.
-}
inlineNameTests : Test
inlineNameTests =
    let
        parses entry expected =
            Test.test ("parses " ++ entry) <|
                \_ -> Expect.equal expected (Config.parseInlineName entry)

        rejects entry =
            Test.test ("rejects " ++ entry) <|
                \_ -> Expect.equal Nothing (Config.parseInlineName entry)

        base =
            Config.default

        inline =
            base.inline

        withLists white black =
            { base | inline = { inline | whitelist = white, blacklist = black } }
    in
    Test.describe "inline names"
        [ parses "elm/core:List.map" (Just { package = Just "elm/core", moduleName = "List", name = "map" })
        , parses "eco/system:SeqDict.get" (Just { package = Just "eco/system", moduleName = "SeqDict", name = "get" })
        , parses "the-sett/elm-mlir:Mlir.Bytecode.VarInt.encodeVarInt"
            (Just { package = Just "the-sett/elm-mlir", moduleName = "Mlir.Bytecode.VarInt", name = "encodeVarInt" })
        , parses "Utils.Bytes.Encode.int" (Just { package = Nothing, moduleName = "Utils.Bytes.Encode", name = "int" })
        , rejects "map"
        , rejects "List."
        , rejects ".map"
        , rejects "List..map"
        , rejects "elm/core:"
        , rejects "elm/core:map"
        , rejects "a:b:List.map"
        , rejects "core:List.map"
        , rejects "elm/:List.map"
        , rejects "elm/core/x:List.map"
        , Test.test "clamp drops malformed entries with a warning each" <|
            \_ ->
                let
                    ( cfg, warnings ) =
                        Config.clamp (withLists [ "elm/core:List.map", "bad", "M.f" ] [ "x:y" ])
                in
                Expect.equal
                    ( [ "elm/core:List.map", "M.f" ], [], 2 )
                    ( cfg.inline.whitelist, cfg.inline.blacklist, List.length warnings )
        ]
