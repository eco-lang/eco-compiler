module Compiler.AST.DecisionTree.Test exposing
    ( Test(..), testToComparable
    , testEncoder, testDecoder
    , testEncoderS, testDecoderS, collectStringsFromTest
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
strings through a string table, as `Compiler.AST.StringTable` describes, and
`testDecoderS` reads them back. `collectStringsFromTest` gives a collector
those strings before the table is built. `testEncoder` and `testDecoder` are
the same codec with `StringTable.disabled`, which writes the strings inline.

@docs Test, testToComparable
@docs testEncoder, testDecoder
@docs testEncoderS, testDecoderS, collectStringsFromTest

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.AST.StringTable as StringTable exposing (StringTable)
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
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

`IsTuple` is the test for a tuple pattern or the unit pattern. Every value of
a tuple or unit type has the same shape, so nothing about the value can make
it fail.

`IsInt`, `IsChr` and `IsStr` ask whether the value equals a literal.
`IsChr` and `IsStr` hold the literal as text in the escaped form that
`Compiler.AST.Canonical` describes for `PChr` and `PStr`, which is why a
character is a `String` here.

`IsBool` asks whether a `Bool` is `True` or `False`.

-}
type Test
    = IsCtor ModuleName.Canonical Name.Name Index.ZeroBased Int Can.CtorOpts
    | IsCons
    | IsNil
    | IsTuple
    | IsInt Int
    | IsChr String
    | IsStr String
    | IsBool Bool


{-| Returns a string that identifies `test`, for comparing tests and keeping
them in sets or as `Dict` keys.

Each kind of test has its own prefix, so tests of different kinds never share
a key, and an `IsCtor` key includes all five of its fields. A literal is keyed
by its escaped text, so two literals that denote the same value can get
different keys, for instance `'a'` and `'\u{0061}'`.

-}
testToComparable : Test -> String
testToComparable test =
    case test of
        IsCtor (ModuleName.Canonical ( author, pkg ) moduleName) name zeroBased numAlts opts ->
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
                , "/"
                , ctorOptsToString opts
                ]

        IsCons ->
            "cons"

        IsNil ->
            "nil"

        IsTuple ->
            "tup"

        IsInt n ->
            "I" ++ String.fromInt n

        IsChr c ->
            "H" ++ c

        IsStr s ->
            "S" ++ s

        IsBool b ->
            if b then
                "Bt"

            else
                "Bf"


{-| Returns the one-letter code for `opts` in an `IsCtor` key.
-}
ctorOptsToString : Can.CtorOpts -> String
ctorOptsToString opts =
    case opts of
        Can.Normal ->
            "N"

        Can.Enum ->
            "E"

        Can.Unbox ->
            "U"


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


{-| Encodes `test` as a tag byte, 0 to 7 in the order the constructors are
declared, followed by its fields, with each string written through `st` as
`StringTable.string` writes it.

The strings are the home module and name of an `IsCtor` and the literal of an
`IsChr` or `IsStr`, and `collectStringsFromTest` gives a collector the same
ones. Each must be in `st`, unless `st`'s index width is 0; what happens to a
missing one is described in `Compiler.AST.StringTable`.

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

        IsTuple ->
            Bytes.Encode.unsignedInt8 3

        IsInt value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , BE.int64 value
                ]

        IsChr value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , StringTable.string st value
                ]

        IsStr value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , StringTable.string st value
                ]

        IsBool value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , BE.bool value
                ]


{-| Produces a decoder for a test written by `testEncoderS` with the same
table. A tag byte above 7 makes it fail.
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
                        Bytes.Decode.succeed IsTuple

                    4 ->
                        Bytes.Decode.map IsInt BD.int64

                    5 ->
                        Bytes.Decode.map IsChr (StringTable.stringDec st)

                    6 ->
                        Bytes.Decode.map IsStr (StringTable.stringDec st)

                    7 ->
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

        IsTuple ->
            acc

        IsInt _ ->
            acc

        IsChr value ->
            StringTable.add value acc

        IsStr value ->
            StringTable.add value acc

        IsBool _ ->
            acc
