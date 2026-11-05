module TestLogic.Type.AnnotationVarsDistinct exposing (expectAnnotationVarsDistinct)

{-| A check that the annotation type checking gives each top-level definition
has one type variable per variable of the definition's solved type, and
quantifies over all of them.

Hindley-Milner generalizes a definition over every free variable of its type,
each a variable of its own. An annotation that names two of the solved type's
variables alike is less general than the type, so another module using the
definition through its interface is held to it: a valid call can be rejected.
`Compiler.Type.Type.toAnnotation` once did this to the later members of an
unannotated recursive group, which share variables with the earlier ones.

`expectAnnotationVarsDistinct` type checks a module with
`TestLogic.TestPipeline.runToTypeCheck`. For each definition in
`annotationVars`, it reads the definition's solved type from the solver's
store (`Compiler.Type.SolverSnapshot`), counts its distinct variable classes,
and fails unless the annotation's type mentions as many distinct names and the
annotation quantifies over each of them. The variables of a type are found as
`toAnnotation` finds them: through function arguments and results, type
arguments, alias arguments, record fields and extensions, and tuple elements,
but not lambda sets.

-}

import Array exposing (Array)
import Compiler.IR.Canonical as Can
import Compiler.IR.Source as Src
import Compiler.IR.Typed.TypeVars as Vars
import Compiler.Type.SolverSnapshot as SolverSnapshot
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Set exposing (Set)
import TestLogic.TestPipeline as Pipeline


{-| Fails when some top-level definition's annotation of `srcModule` names
fewer or more distinct variables than its solved type has, or leaves one
unquantified, as the module docstring describes.
-}
expectAnnotationVarsDistinct : Src.Module -> Expectation
expectAnnotationVarsDistinct srcModule =
    case Pipeline.runToTypeCheck srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            case
                Dict.toList result.annotationVars
                    |> List.filterMap (problemFor result.solverState.cells result.annotations)
            of
                [] ->
                    Expect.pass

                problems ->
                    Expect.fail (String.join "\n" problems)


{-| Returns a description of what is wrong with the annotation of `name`,
whose solved type is that of `var`, or `Nothing` when it is right.
-}
problemFor : Array Vars.PointCell -> Dict String (Can.Annotation String) -> ( String, Vars.Variable ) -> Maybe String
problemFor cells annotations ( name, var ) =
    case Dict.get name annotations of
        Just (Can.Forall freeVars tipe) ->
            let
                classes =
                    Set.size (variableClasses cells var ( Set.empty, Set.empty ) |> Tuple.second)

                names =
                    typeVarNames tipe Set.empty

                unquantified =
                    Set.toList (Set.filter (\n -> not (Dict.member n freeVars)) names)
            in
            if Set.size names /= classes then
                Just
                    (name
                        ++ ": the solved type has "
                        ++ String.fromInt classes
                        ++ " type variables, but the annotation names "
                        ++ String.fromInt (Set.size names)
                        ++ " ("
                        ++ String.join ", " (Set.toList names)
                        ++ ")"
                    )

            else if not (List.isEmpty unquantified) then
                Just (name ++ ": the annotation does not quantify over " ++ String.join ", " unquantified)

            else
                Nothing

        Nothing ->
            Just (name ++ ": no annotation")


{-| Adds the root of every variable class reachable from `var` to the second
set, the first holding the roots already visited.
-}
variableClasses : Array Vars.PointCell -> Vars.Variable -> ( Set Int, Set Int ) -> ( Set Int, Set Int )
variableClasses cells var ( visited, found ) =
    let
        (Vars.Pt root) =
            SolverSnapshot.resolveVariable { cells = cells } var
    in
    if Set.member root visited then
        ( visited, found )

    else
        case Array.get root cells of
            Just (Vars.Root _ desc) ->
                let
                    visited1 =
                        Set.insert root visited

                    go vars acc =
                        List.foldl (variableClasses cells) acc vars
                in
                case desc.content of
                    Vars.FlexVar _ ->
                        ( visited1, Set.insert root found )

                    Vars.FlexSuper _ _ ->
                        ( visited1, Set.insert root found )

                    Vars.RigidVar _ ->
                        ( visited1, Set.insert root found )

                    Vars.RigidSuper _ _ ->
                        ( visited1, Set.insert root found )

                    Vars.Alias _ _ args _ ->
                        go (List.map Tuple.second args) ( visited1, found )

                    Vars.Structure flatType ->
                        case flatType of
                            Vars.App1 _ _ args ->
                                go args ( visited1, found )

                            Vars.Fun1 arg body ->
                                go [ arg, body ] ( visited1, found )

                            Vars.FunL arg body _ ->
                                go [ arg, body ] ( visited1, found )

                            Vars.Record1 fields extension ->
                                go (extension :: Dict.values fields) ( visited1, found )

                            Vars.Tuple1 a b cs ->
                                go (a :: b :: cs) ( visited1, found )

                            _ ->
                                ( visited1, found )

                    _ ->
                        ( visited1, found )

            _ ->
                ( visited, found )


{-| Adds the name of every type variable `tipe` mentions to `acc`.
-}
typeVarNames : Can.Type String -> Set String -> Set String
typeVarNames tipe acc =
    case tipe of
        Can.TLambda _ arg result ->
            typeVarNames result (typeVarNames arg acc)

        Can.TVar n ->
            Set.insert n acc

        Can.TType _ _ args ->
            List.foldl typeVarNames acc args

        Can.TRecord fields maybeExt ->
            Dict.foldl (\_ (Can.FieldType _ t) a -> typeVarNames t a)
                (Maybe.withDefault acc (Maybe.map (\e -> Set.insert e acc) maybeExt))
                fields

        Can.TUnit ->
            acc

        Can.TTuple a b cs ->
            List.foldl typeVarNames acc (a :: b :: cs)

        Can.TAlias _ _ args _ ->
            List.foldl (\( _, t ) a -> typeVarNames t a) acc args
