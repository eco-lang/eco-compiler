module Compiler.AST.TypedOptimizedCodecTest exposing (suite)

{-| The build writes typed-optimized graphs to disk as bytes and reads them
back (`Builder.Build` a module's local graph, `Builder.Elm.Details` a package's
global graph), so a decoder that does not read back what its encoder wrote
would give a later build something other than the graph that was saved. These
tests run the graph codecs of `Compiler.AST.TypedOptimized` over many small
programs to check for that.

An encoded graph begins with a format-version byte, then a _string table_, the
distinct strings the rest of the encoding refers to by index (see
`Compiler.AST.StringTable`), then a _type table_, the distinct types it refers
to by id (see `Compiler.AST.TypeTable`), and then the graph itself. A type
variable is _constrained_ when its name starts with `number`, `comparable`,
`appendable` or `compappend`, as `Compiler.Data.Name` tests it.
`TOpt.computeVarSupers` maps every name collected from a local graph that starts
with one of those words, type variable or not, to its constraint.

The fixture is the programs that `SourceIR.Suite.StandardTestSuites` hands to
the check it is given. Each is compiled by `TestLogic.TestPipeline.runToTypedOpt`
to a typed local graph, and its global graph is that local graph added to an
empty global graph by `Builder.GraphAssembly.addTypedLocalGraph`. A program the
pipeline rejects fails with the pipeline's message, and a graph that does not
decode fails too.

For each program the test checks that:

  - re-encoding the decoded local graph gives the same bytes as encoding the
    original;
  - re-encoding the decoded global graph gives the same bytes as encoding the
    original;
  - encoding the local graph a second time gives the same bytes as the first;
  - the decoded local graph's annotations equal the original's;
  - the string table and type table at the start of the local encoding decode
    on their own;
  - every constrained name among the type-variable names, record extension
    names and alias parameter names in the types of that table is a key of
    `TOpt.computeVarSupers` of the original local graph.

Among what is not tested:

  - that the decoded graph equals the original apart from its annotations. The
    decoder fills some parts with fixed values, the local graph's `main` and
    `fields` among them, and a part the encoder does not write passes the
    re-encoding checks;
  - that encoding the global graph twice gives the same bytes, or that its
    annotations survive;
  - a global graph built from more than one module;
  - the `varSupers` stored in the graph, as distinct from what
    `computeVarSupers` returns, and whether `computeVarSupers` returns names
    that are not constrained;
  - that an encoding with the wrong format-version byte is rejected.

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


{-| Returns the bytes of `b` as a list of numbers from 0 to 255, in order.
-}
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


{-| Returns `acc` with the type-variable names of `t` added: each `TVar`, each
record's extension variable, and each alias's parameter names, together with
those inside the alias's arguments and its body. A name is added once for
every place it occurs.
-}
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


{-| Returns the types in the type table of `bytes`, an encoding written by
`TOpt.localGraphEncoder`, or `Nothing` if its string table or type table does
not decode. It skips the format-version byte without checking it and reads
nothing after the type table.
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


{-| Tells whether `n` is a constrained name, one that starts with `number`,
`comparable`, `appendable` or `compappend`.
-}
isSuper : Name -> Bool
isSuper n =
    N.isNumberType n || N.isComparableType n || N.isAppendableType n || N.isCompappendType n


{-| Compiles `srcModule` to a typed local graph and checks it, and the global
graph made from it, with the six assertions the module docstring lists.

It fails with the pipeline's message if compilation fails, and with a message
naming the local or the global graph if that graph does not decode; when
neither decodes, the message names the local graph.

-}
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


{-| The codec round-trip tests: `expectCodec` applied to the programs of
`SourceIR.Suite.StandardTestSuites`.
-}
suite : Test
suite =
    Test.describe "TypedOptimized .ecot v2 codec (cache-serialization S3, G5)"
        [ StandardTestSuites.expectSuite expectCodec "round-trips through the v2 codec"
        ]
