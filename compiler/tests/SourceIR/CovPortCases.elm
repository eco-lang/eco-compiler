module SourceIR.CovPortCases exposing (expectSuite)

{-| Port modules whose ports carry the value types `SourceIR.PortEncodingCases`
leaves out, so that a caller's check can be run on the encoders and decoders
the typed optimizer (`Compiler.LocalOpt.Typed.Port`) builds for them: a type
alias, the unit type, a JSON value, `Bytes`, an `Array` and a three-element
tuple coming in.

These cases assert nothing themselves. Each one builds a program and hands it
to the expectation function the caller supplies.

Every program is the source text of a port module named `Test`, parsed as an
application module, that imports `Array`, `Bytes`, `Json.Encode` and
`Json.Decode`, declares one port and defines `testValue` as the integer `1`,
so no program refers to its port. Default imports of modules that
`Compiler.Elm.Interface.Basic.testIfaces` lacks are dropped. The cases, by
label, and the port each declares:

  - "Outgoing alias": `out : Point -> Cmd msg`, with `type alias Point =
    { x : Int }`.
  - "Outgoing unit": `out : () -> Cmd msg`.
  - "Outgoing JSON value": `out : Json.Encode.Value -> Cmd msg`.
  - "Outgoing bytes": `out : Bytes.Bytes -> Cmd msg`.
  - "Incoming alias": `inp : (Point -> msg) -> Sub msg`.
  - "Incoming unit": `inp : (() -> msg) -> Sub msg`.
  - "Incoming JSON value": `inp : (Json.Encode.Value -> msg) -> Sub msg`.
  - "Incoming bytes": `inp : (Bytes.Bytes -> msg) -> Sub msg`.
  - "Incoming array": `inp : (Array.Array Int -> msg) -> Sub msg`.
  - "Incoming triple": `inp : (( Int, String, Bool ) -> msg) -> Sub msg`.

All the cases run inside one test through `Compiler.BulkCheck.bulkCheck`,
which stops at the first case that fails and reports its label.

Among what is not tested: a program that sends on a port or subscribes to one.

-}

import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Core.Annotation as A
import Compiler.Elm.Interface.Basic as Basic
import Compiler.IR.Source as Src
import Compiler.Parse.Module as Parse
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Port value types " followed by `condStr`, that
passes when `expectFn` passes on every case's program and otherwise fails with
the label of the first case whose program it fails on.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Port value types " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns every case, each running `expectFn` on its program, in the order
of the module documentation.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.map
        (\( label, port_ ) ->
            { label = label
            , run =
                \_ ->
                    case parse port_ of
                        Ok modul ->
                            expectFn modul

                        Err message ->
                            Expect.fail message
            }
        )
        ports


{-| Parses the port module declaring `port_`, keeping only the imports the mock
interfaces can resolve.
-}
parse : String -> Result String Src.Module
parse port_ =
    let
        source =
            "port module Test exposing (..)\n\nimport Array\nimport Bytes\nimport Json.Decode\nimport Json.Encode\n\n\ntype alias Point =\n    { x : Int }\n\n\nport "
                ++ port_
                ++ "\n\n\ntestValue =\n    1\n"
    in
    case Parse.fromByteString Parse.Application source of
        Ok (Src.Module m) ->
            Ok (Src.Module { m | imports = List.filter isMockImport m.imports })

        Err _ ->
            Err "fixture failed to parse"


{-| Whether an import names one of the mock interfaces.
-}
isMockImport : Src.Import -> Bool
isMockImport (Src.Import ( _, A.At _ name ) _ _) =
    Dict.member name Basic.testIfaces


{-| The label and the port declaration of each case.
-}
ports : List ( String, String )
ports =
    [ ( "Outgoing alias", "out : Point -> Cmd msg" )
    , ( "Outgoing unit", "out : () -> Cmd msg" )
    , ( "Outgoing JSON value", "out : Json.Encode.Value -> Cmd msg" )
    , ( "Outgoing bytes", "out : Bytes.Bytes -> Cmd msg" )
    , ( "Incoming alias", "inp : (Point -> msg) -> Sub msg" )
    , ( "Incoming unit", "inp : (() -> msg) -> Sub msg" )
    , ( "Incoming JSON value", "inp : (Json.Encode.Value -> msg) -> Sub msg" )
    , ( "Incoming bytes", "inp : (Bytes.Bytes -> msg) -> Sub msg" )
    , ( "Incoming array", "inp : (Array.Array Int -> msg) -> Sub msg" )
    , ( "Incoming triple", "inp : (( Int, String, Bool ) -> msg) -> Sub msg" )
    ]
