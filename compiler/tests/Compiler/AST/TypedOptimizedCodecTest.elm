module Compiler.AST.TypedOptimizedCodecTest exposing (suite)

{-| Cache-serialization plan S3 gate G5: the `.ecot` v2 graph codecs
(string table + type table, ECOT\_002/003) round-trip every standard test
module.

  - re-encode idempotence: `encode (decode (encode g)) == encode g`, for the
    local graph and for its global-graph assembly;
  - annotations survive unchanged (no erasure applies to them);
  - determinism: encoding twice gives the same bytes;
  - varSupers completeness: every `TVar` in the decoded TYPE TABLE whose name
    carries a super prefix is a key of `computeVarSupers g`.

-}

import Array
import Builder.GraphAssembly as GA
import Bytes exposing (Bytes)
import Bytes.Decode as BD
import Bytes.Encode as BE
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.StringTable as StringTable
import Compiler.AST.TypeTable as TypeTable
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as N exposing (Name)
import Dict
import Expect exposing (Expectation)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


toList : Bytes -> List Int
toList b =
    BD.decode
        (BD.loop ( Bytes.width b, [] )
            (\( n, acc ) ->
                if n <= 0 then
                    BD.succeed (BD.Done (List.reverse acc))

                else
                    BD.map (\x -> BD.Loop ( n - 1, x :: acc )) BD.unsignedInt8
            )
        )
        b
        |> Maybe.withDefault []


tvars : Can.Type Name -> List Name -> List Name
tvars t acc =
    case t of
        Can.TVar n ->
            n :: acc

        Can.TLambda _ a b ->
            tvars a (tvars b acc)

        Can.TType _ _ args ->
            List.foldl tvars acc args

        Can.TRecord fields ext ->
            Dict.foldl (\_ (Can.FieldType _ ft) a -> tvars ft a) (Maybe.withDefault acc (Maybe.map (\e -> e :: acc) ext)) fields

        Can.TUnit ->
            acc

        Can.TTuple a b cs ->
            List.foldl tvars (tvars a (tvars b acc)) cs

        Can.TAlias _ _ args aliased ->
            let
                body =
                    case aliased of
                        Can.Holey x ->
                            x

                        Can.Filled x ->
                            x
            in
            List.foldl (\( n, x ) a -> tvars x (n :: a)) (tvars body acc) args


{-| The decoded type table of a v2 local-graph encoding (prefix only).
-}
tableTypes : Bytes -> Maybe (List (Can.Type Name))
tableTypes bytes =
    BD.decode
        (BD.unsignedInt8
            |> BD.andThen (\_ -> StringTable.tableDecoder)
            |> BD.andThen TypeTable.decoder
            |> BD.map (TypeTable.decodedTypes >> Array.toList)
        )
        bytes


isSuper : Name -> Bool
isSuper n =
    N.isNumberType n || N.isComparableType n || N.isAppendableType n || N.isCompappendType n


expectCodec : Src.Module -> Expectation
expectCodec srcModule =
    case Pipeline.runToTypedOpt srcModule of
        Err e ->
            Expect.fail e

        Ok artifacts ->
            let
                g =
                    artifacts.localGraph

                bytes =
                    BE.encode (TOpt.localGraphEncoder g)

                global =
                    GA.addTypedLocalGraph g TOpt.emptyGlobalGraph

                gbytes =
                    BE.encode (TOpt.globalGraphEncoder global)
            in
            case ( BD.decode TOpt.localGraphDecoder bytes, BD.decode TOpt.globalGraphDecoder gbytes ) of
                ( Just g2, Just global2 ) ->
                    let
                        (TOpt.LocalGraph d1) =
                            g

                        (TOpt.LocalGraph d2) =
                            g2

                        supers =
                            TOpt.computeVarSupers g

                        missing =
                            tableTypes bytes
                                |> Maybe.withDefault []
                                |> List.foldl tvars []
                                |> List.filter (\n -> isSuper n && not (Dict.member n supers))
                    in
                    Expect.all
                        [ \_ -> Expect.equal (toList bytes) (toList (BE.encode (TOpt.localGraphEncoder g2)))
                        , \_ -> Expect.equal (toList gbytes) (toList (BE.encode (TOpt.globalGraphEncoder global2)))
                        , \_ -> Expect.equal (toList bytes) (toList (BE.encode (TOpt.localGraphEncoder g)))
                        , \_ -> Expect.equal d1.annotations d2.annotations
                        , \_ -> Expect.notEqual Nothing (tableTypes bytes)
                        , \_ -> Expect.equal [] missing
                        ]
                        ()

                ( Nothing, _ ) ->
                    Expect.fail "local graph decode failed"

                ( _, Nothing ) ->
                    Expect.fail "global graph decode failed"


suite : Test
suite =
    Test.describe "TypedOptimized .ecot v2 codec (cache-serialization S3, G5)"
        [ StandardTestSuites.expectSuite expectCodec "round-trips through the v2 codec"
        ]
