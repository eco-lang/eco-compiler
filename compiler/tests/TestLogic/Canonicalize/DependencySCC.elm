module TestLogic.Canonicalize.DependencySCC exposing (expectSCCGroups, expectValidSCCs)

{-| A checker for how canonicalization groups a module's top-level
definitions, meant to catch a canonicalizer that groups them wrongly.

The canonicalizer sorts a module's top-level definitions into the strongly
connected components (SCCs) of their dependency graph, and gives the module
its declarations as a chain of them, each component after the components it
depends on. A definition in a component of its own that does not depend on
itself is a `Can.Declare`. A group of definitions that depend on each other,
or a single definition that depends on itself, is one `Can.DeclareRec`.
`Compiler.Canonicalize.Module` owns this grouping, and the rule that decides
which cycles among definitions with no arguments are errors.

`expectValidSCCs` runs a source module through
`TestLogic.TestPipeline.runToPostSolve` and walks the canonical declarations.
A definition's dependencies are the module's own top-level definitions that
its body names (`Can.VarTopLevel` with the module's home), at any depth,
inside lambdas and `let` bodies included. It reports:

  - a `Declare`d definition that depends on itself;
  - a dependency on a definition declared in a later component (a dependency
    order violation; it also rules out a cycle that spans two components);
  - a single-definition `DeclareRec` that does not depend on itself;
  - a `DeclareRec` group of several definitions that is not strongly
    connected through dependencies within the group.

`expectSCCGroups` does the same and also compares the grouping with an
expected one.

Not checked: the relative order of components that do not depend on each
other, and dependencies through ports or effect managers.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Data.Map as DMap
import Dict exposing (Dict)
import Expect
import Set exposing (Set)
import TestLogic.TestPipeline as Pipeline


{-| A component of the declaration chain: its definitions' names, in
declaration order, and whether it is a `Can.DeclareRec`.
-}
type alias Group =
    { names : List Name
    , isRec : Bool
    , deps : List ( Name, Set Name )
    }


{-| Runs `srcModule` through `TestLogic.TestPipeline.runToPostSolve` and
checks its canonical declarations as the module docstring describes. Fails
with the pipeline's message if a stage fails, and with one line per problem
otherwise.
-}
expectValidSCCs : Src.Module -> Expect.Expectation
expectValidSCCs srcModule =
    withGroups srcModule (\_ -> Expect.pass)


{-| Like `expectValidSCCs`, and also expects the components to be exactly
`expected`: each pair is a component's definition names (in any order) and
whether it is a `Can.DeclareRec`. The components are compared in any order.
-}
expectSCCGroups : List ( List Name, Bool ) -> Src.Module -> Expect.Expectation
expectSCCGroups expected srcModule =
    let
        normalize =
            List.map (\( names, isRec ) -> ( List.sort names, isRec )) >> List.sortBy (Tuple.first >> String.join ",")
    in
    withGroups srcModule
        (\groups ->
            List.map (\g -> ( g.names, g.isRec )) groups
                |> normalize
                |> Expect.equal (normalize expected)
        )


{-| Runs the pipeline, checks the grouping, and hands the groups to `andThen`
when no problem is found.
-}
withGroups : Src.Module -> (List Group -> Expect.Expectation) -> Expect.Expectation
withGroups srcModule andThen =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                (Can.Module moduleData) =
                    result.canonical

                groups =
                    collectGroups moduleData.name moduleData.decls

                issues =
                    checkGroups groups
            in
            if List.isEmpty issues then
                andThen groups

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- SCC VERIFICATION
-- ============================================================================


{-| Returns the components of `decls`, in declaration order, with each
definition's dependencies on top-level definitions of module `home`.
-}
collectGroups : ModuleName.Canonical -> Can.Decls -> List Group
collectGroups home decls =
    case decls of
        Can.Declare def rest ->
            { names = [ defName def ], isRec = False, deps = [ defDeps home def ] }
                :: collectGroups home rest

        Can.DeclareRec def defs rest ->
            { names = List.map defName (def :: defs), isRec = True, deps = List.map (defDeps home) (def :: defs) }
                :: collectGroups home rest

        Can.SaveTheEnvironment ->
            []


{-| Returns one message per problem in `groups`, as the module docstring lists.
-}
checkGroups : List Group -> List String
checkGroups groups =
    let
        allNames =
            List.concatMap .names groups |> Set.fromList

        step group ( declared, issues ) =
            let
                inGroup =
                    Set.fromList group.names

                orderIssues =
                    List.concatMap
                        (\( name, deps ) ->
                            Set.toList deps
                                |> List.filter (\d -> Set.member d allNames && not (Set.member d declared) && not (Set.member d inGroup))
                                |> List.map (\d -> "'" ++ name ++ "' depends on '" ++ d ++ "', which is declared in a later component")
                        )
                        group.deps
            in
            ( Set.union declared inGroup, issues ++ orderIssues ++ checkGroupShape group )
    in
    List.foldl step ( Set.empty, [] ) groups |> Tuple.second


{-| Checks the recursion shape of one component: a `Declare` must not depend
on itself, a single `DeclareRec` must, and a larger `DeclareRec` must be
strongly connected through dependencies within the group.
-}
checkGroupShape : Group -> List String
checkGroupShape group =
    case ( group.isRec, group.deps ) of
        ( False, [ ( name, deps ) ] ) ->
            if Set.member name deps then
                [ "Non-recursive definition '" ++ name ++ "' references itself" ]

            else
                []

        ( False, _ ) ->
            [ "A Declare component holds " ++ String.fromInt (List.length group.deps) ++ " definitions" ]

        ( True, [ ( name, deps ) ] ) ->
            if Set.member name deps then
                []

            else
                [ "Recursive group of one definition '" ++ name ++ "' does not reference itself" ]

        ( True, ( first, _ ) :: _ ) ->
            let
                inGroup =
                    Set.fromList group.names

                edges =
                    Dict.fromList (List.map (\( n, ds ) -> ( n, Set.intersect ds inGroup )) group.deps)

                reverseEdges =
                    Dict.fromList
                        (List.map
                            (\n -> ( n, Set.filter (\m -> Dict.get m edges |> Maybe.map (Set.member n) |> Maybe.withDefault False) inGroup ))
                            group.names
                        )
            in
            if reachable edges first == inGroup && reachable reverseEdges first == inGroup then
                []

            else
                [ "Recursive group [" ++ String.join ", " group.names ++ "] is not strongly connected" ]

        ( True, [] ) ->
            [ "Empty recursive group" ]


{-| The nodes reachable from `start` in `edges`, `start` included.
-}
reachable : Dict Name (Set Name) -> Name -> Set Name
reachable edges start =
    let
        go frontier seen =
            case frontier of
                [] ->
                    seen

                n :: rest ->
                    if Set.member n seen then
                        go rest seen

                    else
                        go (Set.toList (Maybe.withDefault Set.empty (Dict.get n edges)) ++ rest) (Set.insert n seen)
    in
    go [ start ] Set.empty


{-| The name of a definition.
-}
defName : Can.Def -> Name
defName def =
    case def of
        Can.Def (A.At _ name) _ _ ->
            name

        Can.TypedDef (A.At _ name) _ _ _ _ ->
            name


{-| A definition's name and the top-level names of module `home` its body
references.
-}
defDeps : ModuleName.Canonical -> Can.Def -> ( Name, Set Name )
defDeps home def =
    ( defName def, defBodyReferences home def )


{-| The top-level names of module `home` that the body of `def` references.
-}
defBodyReferences : ModuleName.Canonical -> Can.Def -> Set Name
defBodyReferences home def =
    case def of
        Can.Def _ _ expr ->
            collectTopLevelReferences home expr

        Can.TypedDef _ _ _ expr _ ->
            collectTopLevelReferences home expr


{-| Returns the names of the top-level definitions of module `home`
(`Can.VarTopLevel`) that an expression references, at any depth.
-}
collectTopLevelReferences : ModuleName.Canonical -> Can.Expr -> Set Name
collectTopLevelReferences home (A.At _ exprInfo) =
    let
        go =
            collectTopLevelReferences home

        many =
            List.foldl (\e acc -> Set.union acc (go e)) Set.empty
    in
    case exprInfo.node of
        Can.VarTopLevel varHome name ->
            if varHome == home then
                Set.singleton name

            else
                Set.empty

        Can.Lambda _ body ->
            go body

        Can.Call fn args ->
            many (fn :: args)

        Can.If branches else_ ->
            many (else_ :: List.concatMap (\( c, t ) -> [ c, t ]) branches)

        Can.Let def body ->
            Set.union (defBodyReferences home def) (go body)

        Can.LetRec defs body ->
            List.foldl (\d acc -> Set.union acc (defBodyReferences home d)) (go body) defs

        Can.LetDestruct _ value body ->
            many [ value, body ]

        Can.Case value branches ->
            many (value :: List.map (\(Can.CaseBranch _ e) -> e) branches)

        Can.Access record _ ->
            go record

        Can.Update record fields ->
            DMap.foldl (\_ (Can.FieldUpdate _ e) acc -> Set.union acc (go e)) (go record) fields

        Can.Record fields ->
            DMap.foldl (\_ e acc -> Set.union acc (go e)) Set.empty fields

        Can.Tuple a b rest ->
            many (a :: b :: rest)

        Can.List exprs ->
            many exprs

        Can.Negate e ->
            go e

        Can.Binop _ _ _ _ left right ->
            many [ left, right ]

        _ ->
            Set.empty
