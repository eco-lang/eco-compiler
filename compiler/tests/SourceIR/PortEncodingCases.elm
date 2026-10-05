module SourceIR.PortEncodingCases exposing (expectSuite)

{-| Ports are how an Elm program sends values out and takes values in, and for
every port a program declares the compiler builds a JSON encoder or decoder
from the port's type. These cases supply programs whose ports carry many
different types, so that whatever a caller checks is checked against each of
those shapes, not only the few an ordinary program would use.

A port module declares ports: typed names with no definition. An _outgoing_
port has a type `a -> Cmd msg` and sends its argument out. An _incoming_ port
has a type `(a -> msg) -> Sub msg` and delivers the values that come in. In
both, `a` is the port's _value type_. Which value types are allowed is decided
by `Compiler.Canonicalize.Effects`. The typed optimizer builds an encoder for
each outgoing port and a decoder for each incoming one
(`Compiler.LocalOpt.Typed.Port`), whether or not the program uses the port.

Every program is a module built by `makePortModule`, so it is named `Test`
and imports, among others, `Array`, `Json.Encode`, `Json.Decode`,
`Platform.Cmd` and `Platform.Sub`. Besides its ports it has one top-level
value, `testValue`, an unannotated integer literal. No program refers to its
ports, so each port is present only as a declaration.

This module asserts nothing itself. `expectSuite` hands the programs, in
order, to the expectation function its caller supplies, and stops at the first
one that function rejects; the caller decides what is checked.

  - Fifteen programs each declare one outgoing port `out`, with value type
    `Int`, `Float`, `Bool`, `String`, `Maybe Int`, `Maybe String`,
    `List Int`, `List String`, `( Int, String )`, `( Int, String, Bool )`,
    `{ x : Int, y : Int }`, `{ pos : { x : Int, y : Int } }`,
    `{ items : List Int }`, `List { x : Int }` or `Maybe { x : Int }`.
  - Thirteen programs each declare one incoming port `inp`, with value type
    `Int`, `Float`, `Bool`, `String`, `Maybe Int`, `List Int`,
    `( Int, String )`, `{ x : Int }`, `{ pos : { x : Int } }`,
    `{ a : Int, b : String, c : Bool }`, `List { x : Int }`,
    `Maybe { x : Int }` or `Maybe (Maybe Int)`.
  - Five programs go further: three outgoing ports in one module, an outgoing
    `Array Int`, an outgoing and an incoming port in one module, an outgoing
    `List (Maybe (List { x : Int, y : List String }))`, and an outgoing record
    that holds a record and a list of records.

Among what is not tested: a `Json.Encode.Value` or `Json.Decode.Value` value
type, an incoming three-element tuple, an incoming `Array`, and a program that sends on
a port or subscribes to one.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( PortDef
        , intExpr
        , makePortModule
        , tCmd
        , tLambda
        , tRecord
        , tSub
        , tTuple
        , tType
        , tVar
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Reporting.Annotation as A
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Returns one test, named "Port encoding " followed by `condStr`, that gives
the programs here to `expectFn` in order and passes when `expectFn` accepts
them all. It stops at the first program `expectFn` rejects and names only that
case, as `Compiler.BulkCheck.bulkCheck` describes.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Port encoding " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Lists every case: the outgoing-port cases, then the incoming-port cases,
then the cases with several ports, an `Array` value type, or a deeply nested
value type, each checked with `expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    List.concat
        [ encoderCases expectFn
        , decoderCases expectFn
        , complexPortCases expectFn
        ]



-- ============================================================================
-- ENCODER TESTS (Outgoing Ports)
-- ============================================================================


{-| Lists the cases that each declare one outgoing port `out`, one per value
type.
-}
encoderCases : (Src.Module -> Expectation) -> List TestCase
encoderCases expectFn =
    [ { label = "Encode Int", run = encodeInt expectFn }
    , { label = "Encode Float", run = encodeFloat expectFn }
    , { label = "Encode Bool", run = encodeBool expectFn }
    , { label = "Encode String", run = encodeString expectFn }
    , { label = "Encode Maybe Int", run = encodeMaybeInt expectFn }
    , { label = "Encode Maybe String", run = encodeMaybeString expectFn }
    , { label = "Encode List Int", run = encodeListInt expectFn }
    , { label = "Encode List String", run = encodeListString expectFn }
    , { label = "Encode Tuple2", run = encodeTuple2 expectFn }
    , { label = "Encode Tuple3", run = encodeTuple3 expectFn }
    , { label = "Encode Simple Record", run = encodeSimpleRecord expectFn }
    , { label = "Encode Nested Record", run = encodeNestedRecord expectFn }
    , { label = "Encode Record With List", run = encodeRecordWithList expectFn }
    , { label = "Encode List Of Records", run = encodeListOfRecords expectFn }
    , { label = "Encode Maybe Record", run = encodeMaybeRecord expectFn }

    -- No case carries a Value: both Json modules are imported with everything
    -- exposed and each has its own Value, so an unqualified Value is ambiguous.
    ]


{-| Passes `expectFn` a module declaring the outgoing port
`out : Int -> Cmd msg`.
-}
encodeInt : (Src.Module -> Expectation) -> (() -> Expectation)
encodeInt expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tType "Int" []) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 42)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : Float -> Cmd msg`.
-}
encodeFloat : (Src.Module -> Expectation) -> (() -> Expectation)
encodeFloat expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tType "Float" []) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : Bool -> Cmd msg`.
-}
encodeBool : (Src.Module -> Expectation) -> (() -> Expectation)
encodeBool expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tType "Bool" []) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : String -> Cmd msg`.
-}
encodeString : (Src.Module -> Expectation) -> (() -> Expectation)
encodeString expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tType "String" []) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : Maybe Int -> Cmd msg`.
-}
encodeMaybeInt : (Src.Module -> Expectation) -> (() -> Expectation)
encodeMaybeInt expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tType "Maybe" [ tType "Int" [] ]) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : Maybe String -> Cmd msg`.
-}
encodeMaybeString : (Src.Module -> Expectation) -> (() -> Expectation)
encodeMaybeString expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tType "Maybe" [ tType "String" [] ]) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : List Int -> Cmd msg`.
-}
encodeListInt : (Src.Module -> Expectation) -> (() -> Expectation)
encodeListInt expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tType "List" [ tType "Int" [] ]) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : List String -> Cmd msg`.
-}
encodeListString : (Src.Module -> Expectation) -> (() -> Expectation)
encodeListString expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tType "List" [ tType "String" [] ]) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : ( Int, String ) -> Cmd msg`.
-}
encodeTuple2 : (Src.Module -> Expectation) -> (() -> Expectation)
encodeTuple2 expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tTuple (tType "Int" []) (tType "String" [])) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : ( Int, String, Bool ) -> Cmd msg`, whose value type is a three-element
tuple built by `tTuple3`.
-}
encodeTuple3 : (Src.Module -> Expectation) -> (() -> Expectation)
encodeTuple3 expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tTuple3 (tType "Int" []) (tType "String" []) (tType "Bool" [])) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : { x : Int, y : Int } -> Cmd msg`.
-}
encodeSimpleRecord : (Src.Module -> Expectation) -> (() -> Expectation)
encodeSimpleRecord expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe =
                tLambda
                    (tRecord [ ( "x", tType "Int" [] ), ( "y", tType "Int" [] ) ])
                    (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : { pos : { x : Int, y : Int } } -> Cmd msg`.
-}
encodeNestedRecord : (Src.Module -> Expectation) -> (() -> Expectation)
encodeNestedRecord expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe =
                tLambda
                    (tRecord [ ( "pos", tRecord [ ( "x", tType "Int" [] ), ( "y", tType "Int" [] ) ] ) ])
                    (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : { items : List Int } -> Cmd msg`.
-}
encodeRecordWithList : (Src.Module -> Expectation) -> (() -> Expectation)
encodeRecordWithList expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe =
                tLambda
                    (tRecord [ ( "items", tType "List" [ tType "Int" [] ] ) ])
                    (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : List { x : Int } -> Cmd msg`.
-}
encodeListOfRecords : (Src.Module -> Expectation) -> (() -> Expectation)
encodeListOfRecords expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe =
                tLambda
                    (tType "List" [ tRecord [ ( "x", tType "Int" [] ) ] ])
                    (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : Maybe { x : Int } -> Cmd msg`.
-}
encodeMaybeRecord : (Src.Module -> Expectation) -> (() -> Expectation)
encodeMaybeRecord expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe =
                tLambda
                    (tType "Maybe" [ tRecord [ ( "x", tType "Int" [] ) ] ])
                    (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul



-- ============================================================================
-- DECODER TESTS (Incoming Ports)
-- ============================================================================


{-| Lists the cases that each declare one incoming port `inp`, one per value
type.
-}
decoderCases : (Src.Module -> Expectation) -> List TestCase
decoderCases expectFn =
    [ { label = "Decode Int", run = decodeInt expectFn }
    , { label = "Decode Float", run = decodeFloat expectFn }
    , { label = "Decode Bool", run = decodeBool expectFn }
    , { label = "Decode String", run = decodeString expectFn }
    , { label = "Decode Maybe Int", run = decodeMaybeInt expectFn }
    , { label = "Decode List Int", run = decodeListInt expectFn }
    , { label = "Decode Tuple2", run = decodeTuple2 expectFn }
    , { label = "Decode Simple Record", run = decodeSimpleRecord expectFn }
    , { label = "Decode Nested Record", run = decodeNestedRecord expectFn }
    , { label = "Decode Record Multi Field", run = decodeRecordMultiField expectFn }
    , { label = "Decode List Of Records", run = decodeListOfRecords expectFn }
    , { label = "Decode Maybe Record", run = decodeMaybeRecord expectFn }
    , { label = "Decode Nested Maybe", run = decodeNestedMaybe expectFn }

    -- No case carries a Value: both Json modules are imported with everything
    -- exposed and each has its own Value, so an unqualified Value is ambiguous.
    ]


{-| Builds the type of an incoming port whose value type is `valueType`:
`(valueType -> msg) -> Sub msg`.
-}
incomingPortType : Src.Type -> Src.Type
incomingPortType valueType =
    tLambda (tLambda valueType (tVar "msg")) (tSub (tVar "msg"))


{-| Passes `expectFn` a module declaring the incoming port
`inp : (Int -> msg) -> Sub msg`.
-}
decodeInt : (Src.Module -> Expectation) -> (() -> Expectation)
decodeInt expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tType "Int" [])
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the incoming port
`inp : (Float -> msg) -> Sub msg`.
-}
decodeFloat : (Src.Module -> Expectation) -> (() -> Expectation)
decodeFloat expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tType "Float" [])
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the incoming port
`inp : (Bool -> msg) -> Sub msg`.
-}
decodeBool : (Src.Module -> Expectation) -> (() -> Expectation)
decodeBool expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tType "Bool" [])
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the incoming port
`inp : (String -> msg) -> Sub msg`.
-}
decodeString : (Src.Module -> Expectation) -> (() -> Expectation)
decodeString expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tType "String" [])
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the incoming port
`inp : (Maybe Int -> msg) -> Sub msg`.
-}
decodeMaybeInt : (Src.Module -> Expectation) -> (() -> Expectation)
decodeMaybeInt expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tType "Maybe" [ tType "Int" [] ])
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the incoming port
`inp : (List Int -> msg) -> Sub msg`.
-}
decodeListInt : (Src.Module -> Expectation) -> (() -> Expectation)
decodeListInt expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tType "List" [ tType "Int" [] ])
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the incoming port
`inp : (( Int, String ) -> msg) -> Sub msg`.
-}
decodeTuple2 : (Src.Module -> Expectation) -> (() -> Expectation)
decodeTuple2 expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tTuple (tType "Int" []) (tType "String" []))
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the incoming port
`inp : ({ x : Int } -> msg) -> Sub msg`.
-}
decodeSimpleRecord : (Src.Module -> Expectation) -> (() -> Expectation)
decodeSimpleRecord expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tRecord [ ( "x", tType "Int" [] ) ])
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the incoming port
`inp : ({ pos : { x : Int } } -> msg) -> Sub msg`.
-}
decodeNestedRecord : (Src.Module -> Expectation) -> (() -> Expectation)
decodeNestedRecord expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tRecord [ ( "pos", tRecord [ ( "x", tType "Int" [] ) ] ) ])
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the incoming port
`inp : ({ a : Int, b : String, c : Bool } -> msg) -> Sub msg`.
-}
decodeRecordMultiField : (Src.Module -> Expectation) -> (() -> Expectation)
decodeRecordMultiField expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe =
                incomingPortType
                    (tRecord
                        [ ( "a", tType "Int" [] )
                        , ( "b", tType "String" [] )
                        , ( "c", tType "Bool" [] )
                        ]
                    )
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the incoming port
`inp : (List { x : Int } -> msg) -> Sub msg`.
-}
decodeListOfRecords : (Src.Module -> Expectation) -> (() -> Expectation)
decodeListOfRecords expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tType "List" [ tRecord [ ( "x", tType "Int" [] ) ] ])
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the incoming port
`inp : (Maybe { x : Int } -> msg) -> Sub msg`.
-}
decodeMaybeRecord : (Src.Module -> Expectation) -> (() -> Expectation)
decodeMaybeRecord expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tType "Maybe" [ tRecord [ ( "x", tType "Int" [] ) ] ])
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the incoming port
`inp : (Maybe (Maybe Int) -> msg) -> Sub msg`.
-}
decodeNestedMaybe : (Src.Module -> Expectation) -> (() -> Expectation)
decodeNestedMaybe expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tType "Maybe" [ tType "Maybe" [ tType "Int" [] ] ])
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul



-- ============================================================================
-- COMPLEX PORT TESTS
-- ============================================================================


{-| Lists the cases with several ports in one module, an `Array` value type, or a
deeply nested value type.
-}
complexPortCases : (Src.Module -> Expectation) -> List TestCase
complexPortCases expectFn =
    [ { label = "Multiple ports", run = multiplePorts expectFn }
    , { label = "Port with Array", run = portWithArray expectFn }
    , { label = "Bidirectional ports", run = bidirectionalPorts expectFn }
    , { label = "Port with deep nesting", run = portWithDeepNesting expectFn }
    , { label = "Port with multiple records", run = portWithMultipleRecords expectFn }
    ]


{-| Passes `expectFn` a module declaring three outgoing ports:
`sendInt : Int -> Cmd msg`, `sendString : String -> Cmd msg` and
`sendBool : Bool -> Cmd msg`.
-}
multiplePorts : (Src.Module -> Expectation) -> (() -> Expectation)
multiplePorts expectFn _ =
    let
        port1 : PortDef
        port1 =
            { name = "sendInt"
            , tipe = tLambda (tType "Int" []) (tCmd (tVar "msg"))
            }

        port2 : PortDef
        port2 =
            { name = "sendString"
            , tipe = tLambda (tType "String" []) (tCmd (tVar "msg"))
            }

        port3 : PortDef
        port3 =
            { name = "sendBool"
            , tipe = tLambda (tType "Bool" []) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ port1, port2, port3 ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`out : Array Int -> Cmd msg`.
-}
portWithArray : (Src.Module -> Expectation) -> (() -> Expectation)
portWithArray expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tType "Array" [ tType "Int" [] ]) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port
`sendData : Int -> Cmd msg` and the incoming port
`receiveData : (Int -> msg) -> Sub msg`.
-}
bidirectionalPorts : (Src.Module -> Expectation) -> (() -> Expectation)
bidirectionalPorts expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "sendData"
            , tipe = tLambda (tType "Int" []) (tCmd (tVar "msg"))
            }

        inPort : PortDef
        inPort =
            { name = "receiveData"
            , tipe = incomingPortType (tType "Int" [])
            }

        modul =
            makePortModule "testValue" [ outPort, inPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port `out` with value type
`List (Maybe (List { x : Int, y : List String }))`.
-}
portWithDeepNesting : (Src.Module -> Expectation) -> (() -> Expectation)
portWithDeepNesting expectFn _ =
    let
        deepType =
            tType "List"
                [ tType "Maybe"
                    [ tType "List"
                        [ tRecord
                            [ ( "x", tType "Int" [] )
                            , ( "y", tType "List" [ tType "String" [] ] )
                            ]
                        ]
                    ]
                ]

        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda deepType (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Passes `expectFn` a module declaring the outgoing port `out` with value type
`{ user : { name : String, age : Int }, items : List { id : Int, name : String } }`.
-}
portWithMultipleRecords : (Src.Module -> Expectation) -> (() -> Expectation)
portWithMultipleRecords expectFn _ =
    let
        complexRecordType =
            tRecord
                [ ( "user"
                  , tRecord
                        [ ( "name", tType "String" [] )
                        , ( "age", tType "Int" [] )
                        ]
                  )
                , ( "items"
                  , tType "List"
                        [ tRecord
                            [ ( "id", tType "Int" [] )
                            , ( "name", tType "String" [] )
                            ]
                        ]
                  )
                ]

        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda complexRecordType (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| Builds the three-element tuple type `( a, b, c )`, which
`Compiler.AST.SourceBuilder` has no builder for, with empty comment slots.
-}
tTuple3 : Src.Type -> Src.Type -> Src.Type -> Src.Type
tTuple3 a b c =
    let
        eol t =
            ( ( [], [], Nothing ), t )
    in
    A.At A.zero (Src.TTuple (eol a) (eol b) [ eol c ])
