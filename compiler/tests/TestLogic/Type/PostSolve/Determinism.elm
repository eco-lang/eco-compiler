module TestLogic.Type.PostSolve.Determinism exposing (expectDeterministicTypes)

{-| Test logic for the invariant that type inference is deterministic: the same
program, compiled twice, gets the same types.

The type checker runs as a `System.TypeCheck.IO` action over a store of cells,
through `IO.unsafePerformIO`. If its result depended on anything but its input,
the same program could get different types from two runs, and without this
check nothing would notice.

`expectDeterministicTypes` runs one `Src.Module` through
`TestLogic.TestPipeline.runToPostSolve` twice, in the same test process, and
compares the node types after PostSolve. The node types are an array indexed
by node id, holding the type of each expression or pattern that has one. Two
types count as equal when they are _structurally equal_: the same constructors
with the same module and type names, type variable names, record field names,
field indices and extension variables, alias arguments and alias bodies. The
arrow slot that every `Can.TLambda` carries is not compared.

Among what is not checked: the annotations, the node types before PostSolve and
the kernel type environment of the two runs; and whether a run in another process, or another build, gives the same types.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Creates an expectation that two runs of `srcModule` through PostSolve give
structurally equal node types.

It fails if either run fails, naming which one. Otherwise it fails if the two
arrays differ in length, or if a node is typed in one run and not the other or
typed differently in the two, listing each such difference on its own line.

-}
expectDeterministicTypes : Src.Module -> Expect.Expectation
expectDeterministicTypes srcModule =
    case ( Pipeline.runToPostSolve srcModule, Pipeline.runToPostSolve srcModule ) of
        ( Err msg1, _ ) ->
            Expect.fail ("First run failed: " ++ msg1)

        ( _, Err msg2 ) ->
            Expect.fail ("Second run failed: " ++ msg2)

        ( Ok result1, Ok result2 ) ->
            let
                nodeTypesMatch =
                    compareNodeTypes result1.nodeTypesPost result2.nodeTypesPost
            in
            if List.isEmpty nodeTypesMatch then
                Expect.pass

            else
                Expect.fail ("Non-deterministic types:\n" ++ String.join "\n" nodeTypesMatch)



-- ============================================================================
-- DETERMINISM VERIFICATION
-- ============================================================================


{-| Returns a description of each difference between the node types of a
first run, `types1`, and a second run, `types2`, or an empty list if there is
none.

A difference in length is reported first. Then every node id below the longer
length is compared, and a node typed in one run but not the other, or typed
differently in the two, is reported by its node id, the highest id first.

-}
compareNodeTypes : Array.Array (Maybe (Can.Type Name)) -> Array.Array (Maybe (Can.Type Name)) -> List String
compareNodeTypes types1 types2 =
    let
        keyIssues =
            if Array.length types1 /= Array.length types2 then
                [ "Different number of nodes: " ++ String.fromInt (Array.length types1) ++ " vs " ++ String.fromInt (Array.length types2) ]

            else
                []

        typeAt nodeId types =
            Array.get nodeId types |> Maybe.andThen identity

        typeIssues =
            List.foldl
                (\nodeId acc ->
                    case ( typeAt nodeId types1, typeAt nodeId types2 ) of
                        ( Nothing, Nothing ) ->
                            acc

                        ( Just _, Nothing ) ->
                            ("NodeId " ++ String.fromInt nodeId ++ " missing in second run") :: acc

                        ( Nothing, Just _ ) ->
                            ("NodeId " ++ String.fromInt nodeId ++ " missing in first run") :: acc

                        ( Just type1, Just type2 ) ->
                            if typesStructurallyEqual type1 type2 then
                                acc

                            else
                                ("NodeId " ++ String.fromInt nodeId ++ " has different type") :: acc
                )
                []
                (List.range 0 (max (Array.length types1) (Array.length types2) - 1))
    in
    keyIssues ++ typeIssues


{-| Returns whether two types are structurally equal: built from the same
constructors with equal names and arguments, all the way down.

Type variables are equal only when their names are, so `a -> a` and `b -> b`
differ. The arrow slot of a `Can.TLambda` is ignored; everything else the type
carries is compared.

-}
typesStructurallyEqual : Can.Type Name -> Can.Type Name -> Bool
typesStructurallyEqual type1 type2 =
    case ( type1, type2 ) of
        ( Can.TVar name1, Can.TVar name2 ) ->
            name1 == name2

        ( Can.TLambda _ arg1 result1, Can.TLambda _ arg2 result2 ) ->
            typesStructurallyEqual arg1 arg2 && typesStructurallyEqual result1 result2

        ( Can.TType mod1 name1 args1, Can.TType mod2 name2 args2 ) ->
            mod1 == mod2 && name1 == name2 && List.length args1 == List.length args2 && List.all identity (List.map2 typesStructurallyEqual args1 args2)

        ( Can.TRecord fields1 ext1, Can.TRecord fields2 ext2 ) ->
            ext1 == ext2 && recordFieldsEqual fields1 fields2

        ( Can.TUnit, Can.TUnit ) ->
            True

        ( Can.TTuple a1 b1 cs1, Can.TTuple a2 b2 cs2 ) ->
            typesStructurallyEqual a1 a2
                && typesStructurallyEqual b1 b2
                && (List.length cs1 == List.length cs2)
                && List.all identity (List.map2 typesStructurallyEqual cs1 cs2)

        ( Can.TAlias mod1 name1 args1 aliased1, Can.TAlias mod2 name2 args2 aliased2 ) ->
            mod1
                == mod2
                && name1
                == name2
                && List.length args1
                == List.length args2
                && List.all identity (List.map2 (\( n1, t1 ) ( n2, t2 ) -> n1 == n2 && typesStructurallyEqual t1 t2) args1 args2)
                && aliasedTypesEqual aliased1 aliased2

        _ ->
            False


{-| Returns whether two records' fields have the same names, and each field the
same field index and a structurally equal type.
-}
recordFieldsEqual : Dict.Dict String (Can.FieldType Name) -> Dict.Dict String (Can.FieldType Name) -> Bool
recordFieldsEqual fields1 fields2 =
    let
        keys1 =
            Dict.keys fields1

        keys2 =
            Dict.keys fields2
    in
    keys1
        == keys2
        && List.all
            (\key ->
                case ( Dict.get key fields1, Dict.get key fields2 ) of
                    ( Just (Can.FieldType idx1 t1), Just (Can.FieldType idx2 t2) ) ->
                        idx1 == idx2 && typesStructurallyEqual t1 t2

                    _ ->
                        False
            )
            keys1


{-| Returns whether two alias bodies are both `Holey` or both `Filled`, with
structurally equal types.
-}
aliasedTypesEqual : Can.AliasType Name -> Can.AliasType Name -> Bool
aliasedTypesEqual alias1 alias2 =
    case ( alias1, alias2 ) of
        ( Can.Holey t1, Can.Holey t2 ) ->
            typesStructurallyEqual t1 t2

        ( Can.Filled t1, Can.Filled t2 ) ->
            typesStructurallyEqual t1 t2

        _ ->
            False
