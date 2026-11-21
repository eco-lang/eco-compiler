module Compiler.MonoOpt.NullableMaybeTest exposing (suite)

{-| Tests for the payload rules and the null words of `Compiler.MonoOpt.NullableMaybe`
(plans/constructor-representation-levels.md N1, plans/constructor-representation-followups.md
F2, invariants MONO_033 and HEAP_085).

The tests establish:

  - `admissiblePayload` refuses Int, Float, Char, a kernel-owned type (`Bytes`)
    and a type variable, and accepts every other payload, String, lists, unit
    and `Maybe` included;
  - `censusClass` says "spare" for a payload that can be the word the type
    would otherwise take (Empty for `Maybe`, a null-cons word for a user type);
  - the null word `choose` gives each candidate (with no kernel-visible types
    and no meets): Empty for `Maybe Rec`; the spare word of level 1 for
    `Maybe String` and `Maybe (Maybe Rec)`; level 2 for `Maybe (Maybe String)`
    and level 3 for `Maybe (Maybe (Maybe String))`; the null-cons word of
    `None`'s index for `Opt Bool` and `Opt String` (neither payload can be a
    null-cons word); level 1 for `Opt Color` (`Red` is a null-cons word) and for
    `Maybe (Opt String)` (`Some ""` is Empty);
  - a recursive candidate, `type Nat = Z | S Nat`, is dropped (`S Z` would be
    `Z`'s word) and counted.

-}

import Compiler.Core.TypeIds as TypeIds
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Mono as Mono
import Compiler.MonoOpt.KernelVisible as KernelVisible
import Compiler.MonoOpt.NullableMaybe as NullableMaybe
import Dict
import Expect
import Test exposing (Test, describe, test)


home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "project" ) "Main"


rec : Mono.MonoType
rec =
    Mono.mRecord (Dict.fromList [ ( "x", Mono.MInt ) ])


color : Mono.MonoType
color =
    Mono.mCustom home "Color" []


maybe : Mono.MonoType -> Mono.MonoType
maybe t =
    Mono.mCustom ModuleName.maybe "Maybe" [ t ]


opt : Mono.MonoType -> Mono.MonoType
opt t =
    Mono.mCustom home "Opt" [ t ]


nat : Mono.MonoType
nat =
    Mono.mCustom home "Nat" []


maybeShapes : Mono.MonoType -> List Mono.CtorShape
maybeShapes payload =
    [ { name = "Just", tag = 0, fieldTypes = [ payload ] }, { name = "Nothing", tag = 1, fieldTypes = [] } ]


optShapes : Mono.MonoType -> List Mono.CtorShape
optShapes payload =
    [ { name = "None", tag = 0, fieldTypes = [] }, { name = "Some", tag = 1, fieldTypes = [ payload ] } ]


{-| Every type the tests use, with its constructors.
-}
shapes : List ( Mono.MonoType, List Mono.CtorShape )
shapes =
    [ ( color, [ { name = "Red", tag = 0, fieldTypes = [] }, { name = "Rgb", tag = 1, fieldTypes = [ Mono.MInt, Mono.MInt ] } ] )
    , ( maybe rec, maybeShapes rec )
    , ( maybe Mono.MString, maybeShapes Mono.MString )
    , ( maybe (maybe rec), maybeShapes (maybe rec) )
    , ( maybe (maybe Mono.MString), maybeShapes (maybe Mono.MString) )
    , ( maybe (maybe (maybe Mono.MString)), maybeShapes (maybe (maybe Mono.MString)) )
    , ( opt Mono.MBool, optShapes Mono.MBool )
    , ( opt Mono.MString, optShapes Mono.MString )
    , ( opt color, optShapes color )
    , ( maybe (opt Mono.MString), maybeShapes (opt Mono.MString) )
    , ( nat, [ { name = "Z", tag = 0, fieldTypes = [] }, { name = "S", tag = 1, fieldTypes = [ nat ] } ] )
    , ( maybe Mono.MInt, maybeShapes Mono.MInt )
    ]


shapesOf : Mono.MonoType -> Maybe (List Mono.CtorShape)
shapesOf t =
    List.filter (\( k, _ ) -> k == t) shapes |> List.head |> Maybe.map Tuple.second


choice : NullableMaybe.Choice
choice =
    NullableMaybe.choose { userTypes = True }
        KernelVisible.empty
        []
        (List.foldl (\( k, s ) acc -> Mono.layoutMapInsert k s acc) Mono.layoutMapEmpty shapes)


nullWordOf : Mono.MonoType -> Maybe Mono.NullWord
nullWordOf t =
    Mono.layoutMapGet t choice.nullable |> Maybe.map (\i -> i.info.nullWord)


spare : Int -> Maybe Mono.NullWord
spare level =
    Just { nullCons = False, index = level }


suite : Test
suite =
    describe "Compiler.MonoOpt.NullableMaybe payloads and null words"
        [ test "refused payloads" <|
            \_ ->
                [ Mono.MInt
                , Mono.MFloat
                , Mono.MChar
                , Mono.mCustom ModuleName.bytes "Bytes" []
                , Mono.MVar TypeIds.firstMVarId Mono.CEcoValue
                ]
                    |> List.filter NullableMaybe.admissiblePayload
                    |> Expect.equal []
        , test "accepted payloads" <|
            \_ ->
                [ Mono.MBool
                , Mono.MString
                , Mono.MUnit
                , Mono.mList Mono.MInt
                , Mono.mRecord Dict.empty
                , Mono.mTuple (Mono.T2 Mono.MInt Mono.MInt)
                , rec
                , Mono.mFunction Mono.topSynth [ Mono.MInt ] Mono.MInt
                , color
                , maybe rec
                ]
                    |> List.all NullableMaybe.admissiblePayload
                    |> Expect.equal True
        , test "census classes" <|
            \_ ->
                [ NullableMaybe.censusClass shapesOf True rec
                , NullableMaybe.censusClass shapesOf True Mono.MString
                , NullableMaybe.censusClass shapesOf True color
                , NullableMaybe.censusClass shapesOf False Mono.MString
                , NullableMaybe.censusClass shapesOf False color
                , NullableMaybe.censusClass shapesOf True Mono.MInt
                ]
                    |> Expect.equal [ "adm", "spare", "adm", "adm", "spare", "inadm" ]
        , test "Maybe Rec keeps the Empty word" <|
            \_ -> nullWordOf (maybe rec) |> Expect.equal (Just Mono.emptyNullWord)
        , test "Maybe String and Maybe (Maybe Rec) take the level-1 spare word" <|
            \_ -> [ nullWordOf (maybe Mono.MString), nullWordOf (maybe (maybe rec)) ] |> Expect.equal [ spare 1, spare 1 ]
        , test "nested Maybe String takes one level per layer" <|
            \_ ->
                [ nullWordOf (maybe (maybe Mono.MString)), nullWordOf (maybe (maybe (maybe Mono.MString))) ]
                    |> Expect.equal [ spare 2, spare 3 ]
        , test "Opt Bool and Opt String keep None's null-cons word" <|
            \_ ->
                [ nullWordOf (opt Mono.MBool), nullWordOf (opt Mono.MString) ]
                    |> Expect.equal [ Just { nullCons = True, index = 0 }, Just { nullCons = True, index = 0 } ]
        , test "Opt Color and Maybe (Opt String) take the level-1 spare word" <|
            \_ -> [ nullWordOf (opt color), nullWordOf (maybe (opt Mono.MString)) ] |> Expect.equal [ spare 1, spare 1 ]
        , test "a recursive candidate is dropped and counted" <|
            \_ ->
                ( nullWordOf nat, choice.stats.excludedRecursive )
                    |> Expect.equal ( Nothing, 1 )
        , test "Maybe Int is not a candidate" <|
            \_ -> nullWordOf (maybe Mono.MInt) |> Expect.equal Nothing
        ]
