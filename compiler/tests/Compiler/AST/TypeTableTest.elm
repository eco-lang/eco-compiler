module Compiler.AST.TypeTableTest exposing (suite)

{-| Cache-serialization plan S3 (ECOT\_003): the per-file type table dedups
exactly the `==`-equal types, assigns ids children-first, and round-trips.
-}

import Array
import Bytes
import Bytes.Decode as BD
import Bytes.Encode as BE
import Compiler.AST.Canonical as Can
import Compiler.AST.StringTable as StringTable exposing (StringTable)
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeTable as TypeTable
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Dict
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (Test)


home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "elm", "core" ) "Basics"


int : Can.Type Name
int =
    Can.TType home "Int" []


listOf : Can.Type Name -> Can.Type Name
listOf t =
    Can.TType (ModuleName.Canonical ( "elm", "core" ) "List") "List" [ t ]


sizeOf : List (Can.Type Name) -> Int
sizeOf ts =
    TypeTable.size (List.foldl TypeTable.add TypeTable.empty ts)


{-| Both members of a pair must get distinct ids: interning both grows the
table by one more than interning the first alone.
-}
distinct : Can.Type Name -> Can.Type Name -> Expect.Expectation
distinct a b =
    Expect.equal (sizeOf [ a ] + 1) (sizeOf [ a, b ])


{-| Encode a table plus one ref per type, then decode them back.
-}
roundTrip : List (Can.Type Name) -> Maybe (List (Can.Type Name))
roundTrip ts =
    let
        tb : TypeTable.Builder
        tb =
            List.foldl TypeTable.add TypeTable.empty ts

        st : StringTable
        st =
            StringTable.build (StringTable.collected (TypeTable.collectStrings tb StringTable.collectAll))

        tt : TypeTable.TypeTable
        tt =
            TypeTable.freeze tb

        bytes =
            BE.encode
                (BE.sequence
                    (StringTable.tableEncoder st
                        :: TypeTable.encoder st tt
                        :: List.map (TypeTable.ref tt) ts
                    )
                )

        dec : BD.Decoder (List (Can.Type Name))
        dec =
            StringTable.tableDecoder
                |> BD.andThen
                    (\st2 ->
                        TypeTable.decoder st2
                            |> BD.andThen (\tdt -> decodeN (List.length ts) (TypeTable.refDecoder tdt))
                    )
    in
    BD.decode dec bytes


decodeN : Int -> BD.Decoder a -> BD.Decoder (List a)
decodeN n d =
    BD.loop ( n, [] )
        (\( k, acc ) ->
            if k <= 0 then
                BD.succeed (BD.Done (List.reverse acc))

            else
                BD.map (\x -> BD.Loop ( k - 1, x :: acc )) d
        )


nameFuzzer : Fuzzer String
nameFuzzer =
    Fuzz.oneOfValues [ "a", "number", "msg", "Int", "List", "x", "comparable" ]


typeFuzzer : Int -> Fuzzer (Can.Type Name)
typeFuzzer depth =
    let
        leaf =
            Fuzz.oneOf
                [ Fuzz.map Can.TVar nameFuzzer
                , Fuzz.constant Can.TUnit
                , Fuzz.constant int
                ]
    in
    if depth <= 0 then
        leaf

    else
        let
            sub =
                typeFuzzer (depth - 1)
        in
        Fuzz.oneOf
            [ leaf
            , Fuzz.map3 (\s -> Can.TLambda (slotOf s)) (Fuzz.intRange 0 3) sub sub
            , Fuzz.map2 (\n args -> Can.TType home n args) nameFuzzer (Fuzz.listOfLengthBetween 0 2 sub)
            , Fuzz.map4
                (\f i ft ext -> Can.TRecord (Dict.fromList [ ( f, Can.FieldType i ft ) ]) ext)
                nameFuzzer
                (Fuzz.intRange 0 300)
                sub
                (Fuzz.maybe nameFuzzer)
            , Fuzz.map3 Can.TTuple sub sub (Fuzz.listOfLengthBetween 0 1 sub)
            , Fuzz.map4
                (\n argName body holey ->
                    Can.TAlias home
                        n
                        [ ( argName, body ) ]
                        (if holey then
                            Can.Holey body

                         else
                            Can.Filled body
                        )
                )
                nameFuzzer
                nameFuzzer
                sub
                Fuzz.bool
            ]


slotOf : Int -> TypeIds.ArrowSlot
slotOf s =
    if s == 0 then
        TypeIds.NoArrow

    else
        TypeIds.SolverRoot (s * 7)


suite : Test
suite =
    Test.describe "TypeTable (cache-serialization S3, ECOT_003)"
        [ Test.describe "dedup"
            [ Test.test "Int, List Int, List Int, Int -> List Int has 3 entries" <|
                \_ ->
                    Expect.equal 3
                        (sizeOf [ int, listOf int, listOf int, Can.TLambda TypeIds.NoArrow int (listOf int) ])
            , Test.test "re-interning over existing subtrees adds exactly one" <|
                \_ ->
                    Expect.equal (sizeOf [ int, listOf int ] + 1)
                        (sizeOf [ int, listOf int, Can.TTuple int (listOf int) [] ])
            , Test.test "records built in opposite insertion orders merge" <|
                \_ ->
                    let
                        fa =
                            ( "a", Can.FieldType 0 int )

                        fb =
                            ( "b", Can.FieldType 1 Can.TUnit )

                        r1 =
                            Can.TRecord (Dict.insert "b" (Tuple.second fb) (Dict.fromList [ fa ])) Nothing

                        r2 =
                            Can.TRecord (Dict.insert "a" (Tuple.second fa) (Dict.fromList [ fb ])) Nothing
                    in
                    Expect.equal (sizeOf [ r1 ]) (sizeOf [ r1, r2 ])
            ]
        , Test.describe "must not merge"
            [ Test.test "NoArrow vs SolverRoot 0" <|
                \_ -> distinct (Can.TLambda TypeIds.NoArrow int int) (Can.TLambda (TypeIds.SolverRoot 0) int int)
            , Test.test "SolverRoot 0 vs SolverRoot 7" <|
                \_ -> distinct (Can.TLambda (TypeIds.SolverRoot 0) int int) (Can.TLambda (TypeIds.SolverRoot 7) int int)
            , Test.test "Holey vs Filled" <|
                \_ -> distinct (Can.TAlias home "A" [] (Can.Holey int)) (Can.TAlias home "A" [] (Can.Filled int))
            , Test.test "field index 0 vs 1" <|
                \_ ->
                    distinct (Can.TRecord (Dict.fromList [ ( "f", Can.FieldType 0 int ) ]) Nothing)
                        (Can.TRecord (Dict.fromList [ ( "f", Can.FieldType 1 int ) ]) Nothing)
            , Test.test "ext Nothing vs Just r" <|
                \_ ->
                    distinct (Can.TRecord Dict.empty Nothing) (Can.TRecord Dict.empty (Just "r"))
            , Test.test "alias arg names a vs b" <|
                \_ -> distinct (Can.TAlias home "A" [ ( "a", int ) ] (Can.Filled int)) (Can.TAlias home "A" [ ( "b", int ) ] (Can.Filled int))
            , Test.test "packages differing only in author" <|
                \_ ->
                    distinct (Can.TType (ModuleName.Canonical ( "elm", "core" ) "M") "T" [])
                        (Can.TType (ModuleName.Canonical ( "eco", "core" ) "M") "T" [])
            , Test.test "tuple arity 2 vs 3" <|
                \_ -> distinct (Can.TTuple int int []) (Can.TTuple int int [ int ])
            ]
        , Test.describe "round trip"
            [ Test.test "hand-written types" <|
                \_ ->
                    let
                        ts =
                            [ int
                            , listOf int
                            , Can.TLambda (TypeIds.SolverRoot 3) int (listOf (Can.TVar "a"))
                            , Can.TRecord (Dict.fromList [ ( "x", Can.FieldType 2 int ) ]) (Just "r")
                            , Can.TAlias home "A" [ ( "a", int ) ] (Can.Holey (Can.TVar "a"))
                            , Can.TTuple Can.TUnit int [ int ]
                            , int
                            ]
                    in
                    Expect.equal (Just ts) (roundTrip ts)
            , Test.test "300 distinct vars use 2-byte refs and still round-trip" <|
                \_ ->
                    let
                        ts =
                            List.map (\i -> Can.TVar ("v" ++ String.fromInt i)) (List.range 1 300)
                    in
                    Expect.equal (Just ts) (roundTrip ts)
            , Test.fuzzWith { runs = 200, distribution = Test.noDistribution } (Fuzz.listOfLengthBetween 1 6 (typeFuzzer 3)) "fuzzed types" <|
                \ts -> Expect.equal (Just ts) (roundTrip ts)
            ]
        , Test.describe "children-first decode"
            [ Test.test "a self reference fails the decode" <|
                \_ ->
                    let
                        bytes =
                            BE.encode
                                (BE.sequence
                                    [ StringTable.tableEncoder (StringTable.build (StringTable.collected StringTable.collectAll))
                                    , BE.unsignedInt8 1
                                    , BE.unsignedInt32 Bytes.BE 1
                                    , BE.unsignedInt8 0
                                    , BE.unsignedInt8 0
                                    , BE.unsignedInt8 0
                                    , BE.unsignedInt8 0
                                    ]
                                )
                    in
                    Expect.equal Nothing
                        (BD.decode (StringTable.tableDecoder |> BD.andThen (\st -> TypeTable.decoder st |> BD.map (TypeTable.decodedTypes >> Array.length))) bytes)
            ]
        , Test.test "refMaybe on an un-interned type is Nothing (encoder drift)" <|
            \_ ->
                Expect.equal Nothing
                    (TypeTable.refMaybe (TypeTable.freeze (TypeTable.add int TypeTable.empty)) (listOf int))
        ]
