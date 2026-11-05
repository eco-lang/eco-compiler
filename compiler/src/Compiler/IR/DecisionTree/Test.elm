module Compiler.IR.DecisionTree.Test exposing
    ( Test(..), testToComparable
    , testEncoder, testDecoder
    , testEncoderS, testDecoderS, collectStringsFromTest
    , FanTest(..), toFanTest, fromFanTest
    , fanTestEncoder, fanTestDecoder
    , fanTestEncoderS, fanTestDecoderS, collectStringsFromFanTest
    )

{-| A `case` expression is compiled into a _decision tree_, which examines the
value being matched one part at a time and chooses a branch from what it
finds. Each examination is a _test_: a question about the value at one
position, such as whether it was built with a particular constructor or
equals a particular literal. This module defines the tests, once, for both the
erased and the typed decision trees.

A `Test` says what is asked, not where. The position it applies to is a path,
which a decision tree keeps beside the test.

Besides the type, the module gives each test a string key, so that tests can
be compared and kept in sets, and a binary codec for storing tests in compiled
artifacts. The codec comes in two forms. `testEncoderS` writes a test's
strings through a string table, as `Compiler.Core.StringTable` describes, and
`testDecoderS` reads them back. `collectStringsFromTest` gives a collector
those strings before the table is built. `testEncoder` and `testDecoder` are
the same codec with `StringTable.disabled`, which writes the strings inline.

A _fan-out_ examines one position and goes one of several ways by which of
its edge tests the value passes. Only constructor and literal tests are ever
its edge tests: `Bool` and list tests come at most two to a position, and two
are complete, so they always form a chain of tests. `FanTest` is the test of a
fan-out edge, with its own codec of the same two forms.

@docs Test, testToComparable
@docs testEncoder, testDecoder
@docs testEncoderS, testDecoderS, collectStringsFromTest
@docs FanTest, toFanTest, fromFanTest
@docs fanTestEncoder, fanTestDecoder
@docs fanTestEncoderS, fanTestDecoderS, collectStringsFromFanTest

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.Core.Index as Index
import Compiler.Core.Name as Name
import Compiler.Core.StringTable as StringTable exposing (StringTable)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.IR.Source.StringLiteral as ES
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE


{-| A question a decision tree asks about the value at one position, whose
answer decides which way the tree goes.

`IsCtor home name index numAlts opts` asks whether the value was built with
the constructor `name` of a custom type defined in the module `home`. `index`
is the constructor's zero-based position among the type's constructors.
`numAlts` is how many constructors the type has, carried here so that a set
of tests can be judged to cover every constructor without looking the type up.
`opts` is the type's `Can.CtorOpts`, carried so that the JavaScript code
generator can tell how to read the value's tag without looking the type up.

`IsCons` and `IsNil` ask whether a list is non-empty or empty.

`IsInt`, `IsChr` and `IsStr` ask whether the value equals a literal.
`IsChr` and `IsStr` hold the literal as text in the escaped form that
`Compiler.IR.Canonical` describes for `PChr` and `PStr`, which is why a
character is a `String` here.

`IsBool` asks whether a `Bool` is `True` or `False`.

-}
type Test
    = IsCtor ModuleName.Canonical Name.Name Index.ZeroBased Int Can.CtorOpts
    | IsCons
    | IsNil
    | IsInt Int
    | IsChr String
    | IsStr String
    | IsBool Bool


{-| Returns a string that identifies `test`, for comparing tests and keeping
them in sets or as `Dict` keys.

Each kind of test has its own prefix, so tests of different kinds never share
a key. An `IsCtor` key includes the home module, name, index and `numAlts` of
the constructor but not `opts`, which the constructor's type determines. A `Char` or
`String` literal is keyed by the value it denotes (`Compiler.IR.Source.StringLiteral.valueKey`),
so `'a'` and `'\u{0061}'` share a key.

-}
testToComparable : Test -> String
testToComparable test =
    case test of
        IsCtor (ModuleName.Canonical ( author, pkg ) moduleName) name zeroBased numAlts _ ->
            String.concat
                [ "C"
                , author
                , "/"
                , pkg
                , ":"
                , moduleName
                , "."
                , name
                , "/"
                , String.fromInt (Index.toMachine zeroBased)
                , "/"
                , String.fromInt numAlts
                ]

        IsCons ->
            "cons"

        IsNil ->
            "nil"

        IsInt n ->
            "I" ++ String.fromInt n

        IsChr c ->
            "H" ++ ES.valueKey c

        IsStr s ->
            "S" ++ ES.valueKey s

        IsBool b ->
            if b then
                "Bt"

            else
                "Bf"


{-| Encodes a test with its strings written inline. This is `testEncoderS`
with `StringTable.disabled`, so it needs no table, and `testDecoder` reads
what it writes.
-}
testEncoder : Test -> Bytes.Encode.Encoder
testEncoder =
    testEncoderS StringTable.disabled


{-| A decoder for a test written by `testEncoder`.
-}
testDecoder : Bytes.Decode.Decoder Test
testDecoder =
    testDecoderS StringTable.disabled


{-| Encodes `test` as a tag byte, 0 to 6 in the order the constructors are
declared, followed by its fields, with each string written through `st` as
`StringTable.string` writes it.

The strings are the home module and name of an `IsCtor` and the literal of an
`IsChr` or `IsStr`, and `collectStringsFromTest` gives a collector the same
ones. Each must be in `st`, unless `st`'s index width is 0; what happens to a
missing one is described in `Compiler.Core.StringTable`.

An `IsInt` literal is written as `Utils.Bytes.Encode.int64` writes it, exactly
for any 64-bit integer, while an `IsCtor`'s index and `numAlts` are written as
`Utils.Bytes.Encode.int` writes an integer.

-}
testEncoderS : StringTable -> Test -> Bytes.Encode.Encoder
testEncoderS st test =
    case test of
        IsCtor home name index numAlts opts ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , ModuleName.canonicalEncoderS st home
                , StringTable.string st name
                , Index.zeroBasedEncoder index
                , BE.int numAlts
                , Can.ctorOptsEncoder opts
                ]

        IsCons ->
            Bytes.Encode.unsignedInt8 1

        IsNil ->
            Bytes.Encode.unsignedInt8 2

        IsInt value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.int64 value
                ]

        IsChr value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , StringTable.string st value
                ]

        IsStr value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , StringTable.string st value
                ]

        IsBool value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , BE.bool value
                ]


{-| Produces a decoder for a test written by `testEncoderS` with the same
table. A tag byte above 6 makes it fail.
-}
testDecoderS : StringTable -> Bytes.Decode.Decoder Test
testDecoderS st =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map5 IsCtor
                            (ModuleName.canonicalDecoderS st)
                            (StringTable.stringDec st)
                            Index.zeroBasedDecoder
                            BD.int
                            Can.ctorOptsDecoder

                    1 ->
                        Bytes.Decode.succeed IsCons

                    2 ->
                        Bytes.Decode.succeed IsNil

                    3 ->
                        Bytes.Decode.map IsInt BD.int64

                    4 ->
                        Bytes.Decode.map IsChr (StringTable.stringDec st)

                    5 ->
                        Bytes.Decode.map IsStr (StringTable.stringDec st)

                    6 ->
                        Bytes.Decode.map IsBool BD.bool

                    _ ->
                        Bytes.Decode.fail
            )


{-| Returns the collector `acc` after giving it every string `testEncoderS`
writes for `test`: the home module and name of an `IsCtor`, or the literal of
an `IsChr` or `IsStr`. The collector keeps each as its own rule decides.
-}
collectStringsFromTest : Test -> StringTable.Collector -> StringTable.Collector
collectStringsFromTest test acc =
    case test of
        IsCtor home name _ _ _ ->
            acc
                |> ModuleName.collectStringsFromCanonical home
                |> StringTable.add name

        IsCons ->
            acc

        IsNil ->
            acc

        IsInt _ ->
            acc

        IsChr value ->
            StringTable.add value acc

        IsStr value ->
            StringTable.add value acc

        IsBool _ ->
            acc



-- ====== FAN-OUT TESTS ======


{-| The test of one edge of a fan-out. Each constructor asks what the `Test`
constructor of the same kind asks, with the same fields: `FCtor` as `IsCtor`,
`FInt` as `IsInt`, `FChr` as `IsChr` and `FStr` as `IsStr`.
-}
type FanTest
    = FCtor ModuleName.Canonical Name.Name Index.ZeroBased Int Can.CtorOpts
    | FInt Int
    | FChr String
    | FStr String


{-| Returns the `FanTest` that asks what `test` asks, or `Nothing` for a
`Bool` or list test, which no fan-out has.
-}
toFanTest : Test -> Maybe FanTest
toFanTest test =
    case test of
        IsCtor home name index numAlts opts ->
            Just (FCtor home name index numAlts opts)

        IsInt value ->
            Just (FInt value)

        IsChr value ->
            Just (FChr value)

        IsStr value ->
            Just (FStr value)

        IsCons ->
            Nothing

        IsNil ->
            Nothing

        IsBool _ ->
            Nothing


{-| Returns the `Test` that asks what `test` asks.
-}
fromFanTest : FanTest -> Test
fromFanTest test =
    case test of
        FCtor home name index numAlts opts ->
            IsCtor home name index numAlts opts

        FInt value ->
            IsInt value

        FChr value ->
            IsChr value

        FStr value ->
            IsStr value


{-| Encodes a fan-out test with its strings written inline. This is
`fanTestEncoderS` with `StringTable.disabled`, and `fanTestDecoder` reads what
it writes.
-}
fanTestEncoder : FanTest -> Bytes.Encode.Encoder
fanTestEncoder =
    fanTestEncoderS StringTable.disabled


{-| A decoder for a fan-out test written by `fanTestEncoder`.
-}
fanTestDecoder : Bytes.Decode.Decoder FanTest
fanTestDecoder =
    fanTestDecoderS StringTable.disabled


{-| Encodes `test` as a tag byte, 0 to 3 in the order the constructors are
declared, followed by its fields, written as `testEncoderS` writes the fields
of the `Test` of the same kind.
-}
fanTestEncoderS : StringTable -> FanTest -> Bytes.Encode.Encoder
fanTestEncoderS st test =
    case test of
        FCtor home name index numAlts opts ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , ModuleName.canonicalEncoderS st home
                , StringTable.string st name
                , Index.zeroBasedEncoder index
                , BE.int numAlts
                , Can.ctorOptsEncoder opts
                ]

        FInt value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.int64 value
                ]

        FChr value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , StringTable.string st value
                ]

        FStr value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , StringTable.string st value
                ]


{-| Produces a decoder for a fan-out test written by `fanTestEncoderS` with the
same table. A tag byte above 3 makes it fail.
-}
fanTestDecoderS : StringTable -> Bytes.Decode.Decoder FanTest
fanTestDecoderS st =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map5 FCtor
                            (ModuleName.canonicalDecoderS st)
                            (StringTable.stringDec st)
                            Index.zeroBasedDecoder
                            BD.int
                            Can.ctorOptsDecoder

                    1 ->
                        Bytes.Decode.map FInt BD.int64

                    2 ->
                        Bytes.Decode.map FChr (StringTable.stringDec st)

                    3 ->
                        Bytes.Decode.map FStr (StringTable.stringDec st)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Returns the collector `acc` after giving it every string
`fanTestEncoderS` writes for `test`: the home module and name of an `FCtor`, or
the literal of an `FChr` or `FStr`.
-}
collectStringsFromFanTest : FanTest -> StringTable.Collector -> StringTable.Collector
collectStringsFromFanTest test acc =
    case test of
        FCtor home name _ _ _ ->
            acc
                |> ModuleName.collectStringsFromCanonical home
                |> StringTable.add name

        FInt _ ->
            acc

        FChr value ->
            StringTable.add value acc

        FStr value ->
            StringTable.add value acc
