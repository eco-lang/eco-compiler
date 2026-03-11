module Compiler.AST.DecisionTree.Test exposing
    ( Test(..), testToComparable
    , testEncoder, testDecoder
    )

{-| Runtime tests for pattern matching decision trees.

This module defines the `Test` type used by both erased and typed decision trees.
It is placed in the AST layer to avoid circular dependencies between AST and
LocalOpt layers.

@docs Test, testToComparable
@docs testEncoder, testDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Canonical as Can
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import System.TypeCheck.IO as IO
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE


{-| A runtime test to determine which branch to take in a decision tree.

  - `IsCtor`: Tests if a value is a specific custom type constructor
  - `IsCons`: Tests if a list is non-empty (has cons cell)
  - `IsNil`: Tests if a list is empty
  - `IsTuple`: Tests if a value is a tuple
  - `IsInt`: Tests if a value equals a specific integer
  - `IsChr`: Tests if a value equals a specific character
  - `IsStr`: Tests if a value equals a specific string
  - `IsBool`: Tests if a value equals a specific boolean

-}
type Test
    = IsCtor IO.Canonical Name.Name Index.ZeroBased Int Can.CtorOpts
    | IsCons
    | IsNil
    | IsTuple
    | IsInt Int
    | IsChr String
    | IsStr String
    | IsBool Bool


{-| Convert a Test to a comparable String for use as a dictionary key.
-}
testToComparable : Test -> String
testToComparable test =
    case test of
        IsCtor (IO.Canonical ( author, pkg ) moduleName) name zeroBased numAlts opts ->
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


ctorOptsToString : Can.CtorOpts -> String
ctorOptsToString opts =
    case opts of
        Can.Normal ->
            "N"

        Can.Enum ->
            "E"

        Can.Unbox ->
            "U"


{-| Encode a Test to bytes for serialization.
-}
testEncoder : Test -> Bytes.Encode.Encoder
testEncoder test =
    case test of
        IsCtor home name index numAlts opts ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , ModuleName.canonicalEncoder home
                , BE.string name
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
                , BE.int value
                ]

        IsChr value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , BE.string value
                ]

        IsStr value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , BE.string value
                ]

        IsBool value ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , BE.bool value
                ]


{-| Decode a Test from bytes.
-}
testDecoder : Bytes.Decode.Decoder Test
testDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map5 IsCtor
                            ModuleName.canonicalDecoder
                            BD.string
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
                        Bytes.Decode.map IsInt BD.int

                    5 ->
                        Bytes.Decode.map IsChr BD.string

                    6 ->
                        Bytes.Decode.map IsStr BD.string

                    7 ->
                        Bytes.Decode.map IsBool BD.bool

                    _ ->
                        Bytes.Decode.fail
            )
