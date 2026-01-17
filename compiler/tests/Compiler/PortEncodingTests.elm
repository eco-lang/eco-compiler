module Compiler.PortEncodingTests exposing (expectSuite)

{-| Test cases for port encoding/decoding.

These tests exercise the Compiler.Optimize.Typed.Port module to improve coverage of:

  - Port encoder generation
  - Port decoder generation
  - JSON encoding/decoding for various Elm types through ports

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( PortDef
        , TypedDef
        , intExpr
        , makePortModule
        , makePortModuleWithTypedDefs
        , tCmd
        , tLambda
        , tRecord
        , tSub
        , tTuple
        , tType
        , tVar
        , varExpr
        )
import Expect exposing (Expectation)
import Test exposing (Test)


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Port encoding " ++ condStr)
        [ encoderTests expectFn condStr
        , decoderTests expectFn condStr
        , complexPortTests expectFn condStr
        ]



-- ============================================================================
-- ENCODER TESTS (Outgoing Ports)
-- ============================================================================


encoderTests : (Src.Module -> Expectation) -> String -> Test
encoderTests expectFn condStr =
    Test.describe ("Encoder " ++ condStr)
        [ Test.test ("Encode Int " ++ condStr) (encodeInt expectFn)
        , Test.test ("Encode Float " ++ condStr) (encodeFloat expectFn)
        , Test.test ("Encode Bool " ++ condStr) (encodeBool expectFn)
        , Test.test ("Encode String " ++ condStr) (encodeString expectFn)
        , Test.test ("Encode Maybe Int " ++ condStr) (encodeMaybeInt expectFn)
        , Test.test ("Encode Maybe String " ++ condStr) (encodeMaybeString expectFn)
        , Test.test ("Encode List Int " ++ condStr) (encodeListInt expectFn)
        , Test.test ("Encode List String " ++ condStr) (encodeListString expectFn)
        , Test.test ("Encode Tuple2 " ++ condStr) (encodeTuple2 expectFn)
        , Test.test ("Encode Tuple3 " ++ condStr) (encodeTuple3 expectFn)
        , Test.test ("Encode Simple Record " ++ condStr) (encodeSimpleRecord expectFn)
        , Test.test ("Encode Nested Record " ++ condStr) (encodeNestedRecord expectFn)
        , Test.test ("Encode Record With List " ++ condStr) (encodeRecordWithList expectFn)
        , Test.test ("Encode List Of Records " ++ condStr) (encodeListOfRecords expectFn)
        , Test.test ("Encode Maybe Record " ++ condStr) (encodeMaybeRecord expectFn)

        -- Note: Json.Value tests require special handling for ambiguous Value type resolution
        -- from both Json.Encode and Json.Decode. Skipped for now.
        -- , Test.test ("Encode Json Value " ++ condStr) (encodeJsonValue expectFn)
        ]


{-| port out : Int -> Cmd msg
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


{-| port out : Float -> Cmd msg
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


{-| port out : Bool -> Cmd msg
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


{-| port out : String -> Cmd msg
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


{-| port out : Maybe Int -> Cmd msg
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


{-| port out : Maybe String -> Cmd msg
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


{-| port out : List Int -> Cmd msg
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


{-| port out : List String -> Cmd msg
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


{-| port out : (Int, String) -> Cmd msg
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


{-| port out : (Int, String, Bool) -> Cmd msg
-}
encodeTuple3 : (Src.Module -> Expectation) -> (() -> Expectation)
encodeTuple3 expectFn _ =
    let
        -- Note: Using nested tuples to simulate 3-tuple since tTuple only takes 2 args
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tTuple (tType "Int" []) (tTuple (tType "String" []) (tType "Bool" []))) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul


{-| port out : { x : Int, y : Int } -> Cmd msg
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


{-| port out : { pos : { x : Int, y : Int } } -> Cmd msg
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


{-| port out : { items : List Int } -> Cmd msg
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


{-| port out : List { x : Int } -> Cmd msg
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


{-| port out : Maybe { x : Int } -> Cmd msg
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


{-| port out : Json.Encode.Value -> Cmd msg
-}
encodeJsonValue : (Src.Module -> Expectation) -> (() -> Expectation)
encodeJsonValue expectFn _ =
    let
        outPort : PortDef
        outPort =
            { name = "out"
            , tipe = tLambda (tType "Value" []) (tCmd (tVar "msg"))
            }

        modul =
            makePortModule "testValue" [ outPort ] (intExpr 0)
    in
    expectFn modul



-- ============================================================================
-- DECODER TESTS (Incoming Ports)
-- ============================================================================


decoderTests : (Src.Module -> Expectation) -> String -> Test
decoderTests expectFn condStr =
    Test.describe ("Decoder " ++ condStr)
        [ Test.test ("Decode Int " ++ condStr) (decodeInt expectFn)
        , Test.test ("Decode Float " ++ condStr) (decodeFloat expectFn)
        , Test.test ("Decode Bool " ++ condStr) (decodeBool expectFn)
        , Test.test ("Decode String " ++ condStr) (decodeString expectFn)
        , Test.test ("Decode Maybe Int " ++ condStr) (decodeMaybeInt expectFn)
        , Test.test ("Decode List Int " ++ condStr) (decodeListInt expectFn)
        , Test.test ("Decode Tuple2 " ++ condStr) (decodeTuple2 expectFn)
        , Test.test ("Decode Simple Record " ++ condStr) (decodeSimpleRecord expectFn)
        , Test.test ("Decode Nested Record " ++ condStr) (decodeNestedRecord expectFn)
        , Test.test ("Decode Record Multi Field " ++ condStr) (decodeRecordMultiField expectFn)
        , Test.test ("Decode List Of Records " ++ condStr) (decodeListOfRecords expectFn)
        , Test.test ("Decode Maybe Record " ++ condStr) (decodeMaybeRecord expectFn)

        -- Note: Json.Value tests require special handling for ambiguous Value type resolution
        -- from both Json.Encode and Json.Decode. Skipped for now.
        -- , Test.test ("Decode Json Value " ++ condStr) (decodeJsonValue expectFn)
        , Test.test ("Decode Nested Maybe " ++ condStr) (decodeNestedMaybe expectFn)
        ]


{-| Helper to create incoming port type: (valueType -> msg) -> Sub msg
-}
incomingPortType : Src.Type -> Src.Type
incomingPortType valueType =
    tLambda (tLambda valueType (tVar "msg")) (tSub (tVar "msg"))


{-| port inp : (Int -> msg) -> Sub msg
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


{-| port inp : (Float -> msg) -> Sub msg
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


{-| port inp : (Bool -> msg) -> Sub msg
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


{-| port inp : (String -> msg) -> Sub msg
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


{-| port inp : (Maybe Int -> msg) -> Sub msg
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


{-| port inp : (List Int -> msg) -> Sub msg
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


{-| port inp : ((Int, String) -> msg) -> Sub msg
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


{-| port inp : ({ x : Int } -> msg) -> Sub msg
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


{-| port inp : ({ pos : { x : Int } } -> msg) -> Sub msg
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


{-| port inp : ({ a : Int, b : String, c : Bool } -> msg) -> Sub msg
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


{-| port inp : (List { x : Int } -> msg) -> Sub msg
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


{-| port inp : (Maybe { x : Int } -> msg) -> Sub msg
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


{-| port inp : (Json.Decode.Value -> msg) -> Sub msg
-}
decodeJsonValue : (Src.Module -> Expectation) -> (() -> Expectation)
decodeJsonValue expectFn _ =
    let
        inPort : PortDef
        inPort =
            { name = "inp"
            , tipe = incomingPortType (tType "Value" [])
            }

        modul =
            makePortModule "testValue" [ inPort ] (intExpr 0)
    in
    expectFn modul


{-| port inp : (Maybe (Maybe Int) -> msg) -> Sub msg
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


complexPortTests : (Src.Module -> Expectation) -> String -> Test
complexPortTests expectFn condStr =
    Test.describe ("Complex port scenarios " ++ condStr)
        [ Test.test ("Multiple ports " ++ condStr) (multiplePorts expectFn)
        , Test.test ("Port with Array " ++ condStr) (portWithArray expectFn)
        , Test.test ("Bidirectional ports " ++ condStr) (bidirectionalPorts expectFn)
        , Test.test ("Port with deep nesting " ++ condStr) (portWithDeepNesting expectFn)
        , Test.test ("Port with multiple records " ++ condStr) (portWithMultipleRecords expectFn)
        ]


{-| Multiple outgoing ports in one module
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


{-| port out : Array Int -> Cmd msg
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


{-| Both incoming and outgoing ports
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


{-| Deeply nested type through port
-}
portWithDeepNesting : (Src.Module -> Expectation) -> (() -> Expectation)
portWithDeepNesting expectFn _ =
    let
        -- List (Maybe (List { x : Int, y : List String }))
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


{-| Multiple record types through port
-}
portWithMultipleRecords : (Src.Module -> Expectation) -> (() -> Expectation)
portWithMultipleRecords expectFn _ =
    let
        -- { user : { name : String, age : Int }, items : List { id : Int, name : String } }
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
