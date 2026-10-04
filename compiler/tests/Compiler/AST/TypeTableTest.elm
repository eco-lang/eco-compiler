module Compiler.AST.TypeTableTest exposing (suite)

{-| Tests for `Compiler.AST.TypeTable`, the table of distinct types that a typed
artifact stores once per file and refers to by id. Without them, a change that
merged two types the table must keep apart, or that broke the table's encoding,
could make a cached artifact decode to the wrong types or not decode at all.

The table merges two types only when they are `==`. That is Elm's structural
equality, which compares all the data a `Can.Type` carries, so types a reader
might call the same, such as two arrows that differ only in their arrow slot,
get separate entries. Entries are numbered children first: a row refers only to
rows before it, which lets the decoder build the table in one forward pass.

The fixture types are `int` and `listOf`, both homed in elm/core, and types
written out in each test. Most tests measure a table by `TypeTable.size` after
adding a list of types to an empty builder.

The tests establish:

  - Merging: adding `Int`, `List Int` twice and `Int -> List Int` gives 3
    entries. Adding a tuple of `Int` and `List Int` after those two types adds
    exactly one. Two two-field records whose dicts were built by inserting the
    fields in opposite orders share one entry.
  - Keeping apart: each of eight pairs gets two entries. The pairs are arrows
    with `NoArrow` and with `SolverRoot 0`, arrows with `SolverRoot 0` and
    `SolverRoot 7`, an alias with a `Holey` and with a `Filled` body, one-field
    records with field index 0 and 1, an empty closed record and one extending
    `r`, an alias with its argument named `a` and named `b`, a type whose home
    package differs only in its author, and tuples of two and three elements.
  - Round trip: a string table, the type table and one reference per type are
    encoded together and decode back to the same list of types. This is checked
    for seven hand-written types, one of them repeated, for 300 distinct type
    variables, and for 200 lists of one to six types from `typeFuzzer 3`. With
    300 entries the table is past the 256 that one-byte references can number,
    so its references are two bytes wide; the test checks the round trip, not
    the width. The string table is built from `TypeTable.collectStrings` alone,
    so a string it failed to register would come back as a different string and
    fail these comparisons.
  - Children-first decoding: a hand-written table whose single row is an arrow
    referring to row 0, itself, fails to decode.
  - `refMaybe` returns `Nothing` for `List Int` against a table holding only
    `Int`.

Among what is not tested: the encoded bytes themselves, since nothing is
compared with a fixed byte sequence; four-byte references; the `Arrow` slot;
`ref`'s crash on a type that was never added; a row with an unknown tag; which
id a given type receives; and the values `hashType` returns.

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


{-| The home of most fixture types: elm/core's `Basics` module.
-}
home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "elm", "core" ) "Basics"


{-| The type `Int`, homed in elm/core's `Basics`.
-}
int : Can.Type Name
int =
    Can.TType home "Int" []


{-| Returns the type `List t`, homed in elm/core's `List` module.
-}
listOf : Can.Type Name -> Can.Type Name
listOf t =
    Can.TType (ModuleName.Canonical ( "elm", "core" ) "List") "List" [ t ]


{-| Returns the number of entries in a table built by adding `ts`, in order, to
an empty builder.
-}
sizeOf : List (Can.Type Name) -> Int
sizeOf ts =
    TypeTable.size (List.foldl TypeTable.add TypeTable.empty ts)


{-| Returns an expectation that adding `b` after `a` grows the table by exactly
one entry.

When every child of `b` already occurs in `a`, as in each pair this module
passes, that one entry is `b` itself, so the expectation holds only if `b` was
not merged with `a`. A `b` that brought a new child of its own would grow the
table by more than one and fail.

-}
distinct : Can.Type Name -> Can.Type Name -> Expect.Expectation
distinct a b =
    Expect.equal (sizeOf [ a ] + 1) (sizeOf [ a, b ])


{-| Returns the types decoded after encoding `ts` as a string table, a type
table and one reference per type, or `Nothing` if the decode fails.

The string table holds only the strings `TypeTable.collectStrings` registers
for the type table, and the type table holds `ts` added in order to an empty
builder.

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


{-| Produces a decoder that runs `d` `n` times and returns the results in the
order they were read.
-}
decodeN : Int -> BD.Decoder a -> BD.Decoder (List a)
decodeN n d =
    BD.loop ( n, [] )
        (\( k, acc ) ->
            if k <= 0 then
                BD.succeed (BD.Done (List.reverse acc))

            else
                BD.map (\x -> BD.Loop ( k - 1, x :: acc )) d
        )


{-| A fuzzer for the names in fuzzed types, drawn from seven fixed strings. The
same names serve as type variables, type and alias names, record field names,
extension variables and alias argument names.
-}
nameFuzzer : Fuzzer String
nameFuzzer =
    Fuzz.oneOfValues [ "a", "number", "msg", "Int", "List", "x", "comparable" ]


{-| Produces a fuzzer for types nested at most `depth` levels above the leaves.

At depth 0 it gives a leaf: a type variable, unit or `Int`. At a greater depth
it gives a leaf or one of the following, built from types of one less depth: an
arrow whose slot comes from `slotOf`; a type homed in `Basics` with up to two
arguments; a one-field record, with a field index from 0 to 300 and an optional
extension variable; a tuple of two or three elements; or an alias with one
argument whose type is also the alias body, either `Holey` or `Filled`. Field
indexes of 128 and above take two bytes of the variable-length integer encoding.

-}
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


{-| Returns the arrow slot the fuzzer uses for `s`: `NoArrow` for 0, otherwise
`SolverRoot (s * 7)`.
-}
slotOf : Int -> TypeIds.ArrowSlot
slotOf s =
    if s == 0 then
        TypeIds.NoArrow

    else
        TypeIds.SolverRoot (s * 7)


{-| The type-table tests, in the groups the module docstring lists.
-}
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
