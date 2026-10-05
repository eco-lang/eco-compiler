module TestLogic.LocalOpt.TypedOptTypes exposing (expectAllExprsHaveTypes)

{-| A check that every type the typed optimizer stores on an expression is well
formed: every named type in it is a type that exists, applied to as many
arguments as it declares, and every alias in it is applied to as many arguments
as it has parameters.

The subject is the _typed local graph_, the `TOpt.LocalGraph` that
`TestLogic.TestPipeline.runToTypedOpt` builds for one test program: a map
from global to node, in which the nodes for its definitions hold
`Compiler.AST.TypedOptimized` expressions. Every such expression carries its
type in its `Meta`, as a `Can.Type` rather than a `Maybe`, so a type cannot be
missing; what can go wrong is its shape. The monomorphizer turns a named type
applied to the wrong number of arguments into a wrong layout rather than an
error, so a malformed type would otherwise travel on unnoticed.

`expectAllExprsHaveTypes` runs the program to typed optimization and walks
every expression of every definition, port and recursive group (functions and
values), including the branches a `case` holds inline in its decision tree and
those it jumps to. For each expression it checks `TOpt.typeOf`, and it also
checks the parameter types of functions and tail-recursive definitions, the
declared type of each `let` definition, and the type a `Destruct` stores. A
named type is known when it is declared by one of the modules in
`Compiler.Elm.Interface.Basic.testIfaces` or by the program's own module, or
is one of two types no test interface declares: the built-in `List`, and
elm/json's `Json.Decode.Decoder`, which the typed optimizer builds port decoders
with but the test interface of `Json.Decode` leaves out. Its expected argument
count is the number of variables of that declaration (one for each of those
two). An
alias's expected argument count comes from the same places.

Among what is not checked: that a type variable is bound by an enclosing
annotation, the alias body an alias carries against its declaration, and the
nodes that hold no expression (constructors, enums, boxes, links, kernels and
effect managers).

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.ModuleName as ModuleName
import Data.Map
import Dict exposing (Dict)
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` to typed optimization and passes when every type the walk
reaches is well formed, as the module docstring describes. Fails with
`TestLogic.TestPipeline.runToTypedOpt`'s message when it returns `Err`, and
otherwise with one line per malformed type. The program must define
`testValue`, as `TestLogic.TestPipeline` describes.
-}
expectAllExprsHaveTypes : Src.Module -> Expect.Expectation
expectAllExprsHaveTypes srcModule =
    case Pipeline.runToTypedOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                arities =
                    knownArities result.canonical

                issues =
                    collectExprTypeIssues arities result.localGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" (unique issues))



-- ============================================================================
-- KNOWN TYPES
-- ============================================================================


{-| The number of type variables of every custom type and every alias that a
type may name, each keyed by `typeKey` of its home and name.
-}
type alias Arities =
    { unions : Dict String Int
    , aliases : Dict String Int
    }


{-| Returns the arities of `List`, of `Json.Decode.Decoder`, and of the custom
types and aliases declared by the interfaces in `Basic.testIfaces` and by the
program's own canonical module.
-}
knownArities : Can.Module -> Arities
knownArities (Can.Module moduleData) =
    let
        fromIfaces =
            Dict.foldl
                (\moduleName (I.Interface idata) acc ->
                    let
                        home =
                            ModuleName.Canonical idata.home moduleName
                    in
                    { unions =
                        Dict.foldl
                            (\name union a -> Dict.insert (typeKey home name) (unionArity (ifaceUnion union)) a)
                            acc.unions
                            idata.unions
                    , aliases =
                        Dict.foldl
                            (\name alias a -> Dict.insert (typeKey home name) (aliasArity (ifaceAlias alias)) a)
                            acc.aliases
                            idata.aliases
                    }
                )
                { unions =
                    Dict.fromList
                        [ ( typeKey ModuleName.list "List", 1 )
                        , ( typeKey ModuleName.jsonDecode "Decoder", 1 )
                        ]
                , aliases = Dict.empty
                }
                Basic.testIfaces
    in
    { unions =
        Dict.foldl
            (\name union a -> Dict.insert (typeKey moduleData.name name) (unionArity union) a)
            fromIfaces.unions
            moduleData.unions
    , aliases =
        Dict.foldl
            (\name alias a -> Dict.insert (typeKey moduleData.name name) (aliasArity alias) a)
            fromIfaces.aliases
            moduleData.aliases
    }


{-| Returns the declaration an interface records for a custom type.
-}
ifaceUnion : I.Union -> Can.Union
ifaceUnion union =
    case union of
        I.OpenUnion u ->
            u

        I.ClosedUnion u ->
            u

        I.PrivateUnion u ->
            u


{-| Returns the declaration an interface records for an alias.
-}
ifaceAlias : I.Alias -> Can.Alias
ifaceAlias alias =
    case alias of
        I.PublicAlias a ->
            a

        I.PrivateAlias a ->
            a


{-| Returns the number of type variables a custom type declares.
-}
unionArity : Can.Union -> Int
unionArity (Can.Union data) =
    List.length data.vars


{-| Returns the number of parameters an alias declares.
-}
aliasArity : Can.Alias -> Int
aliasArity (Can.Alias vars _) =
    List.length vars


{-| Returns the key of a named type: its package, module and name.
-}
typeKey : ModuleName.Canonical -> Name -> String
typeKey (ModuleName.Canonical ( author, project ) moduleName) name =
    author ++ "/" ++ project ++ ":" ++ moduleName ++ "." ++ name



-- ============================================================================
-- TYPE CHECK
-- ============================================================================


{-| Returns a problem, prefixed with `context`, for every named type in
`tipe` that is unknown or applied to the wrong number of arguments, and for
every alias applied to the wrong number of arguments. It looks into function
arguments and results, type arguments, record fields, tuple elements, alias
arguments and alias bodies.
-}
typeIssues : Arities -> String -> Can.Type Name -> List String
typeIssues arities context tipe =
    case tipe of
        Can.TLambda _ a b ->
            typeIssues arities context a ++ typeIssues arities context b

        Can.TVar _ ->
            []

        Can.TType home name args ->
            let
                key =
                    typeKey home name
            in
            (case Dict.get key arities.unions of
                Nothing ->
                    [ context ++ ": unknown type " ++ key ]

                Just arity ->
                    if arity == List.length args then
                        []

                    else
                        [ context
                            ++ ": "
                            ++ key
                            ++ " applied to "
                            ++ String.fromInt (List.length args)
                            ++ " argument(s), declared with "
                            ++ String.fromInt arity
                        ]
            )
                ++ List.concatMap (typeIssues arities context) args

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ t) acc -> typeIssues arities context t ++ acc) [] fields

        Can.TUnit ->
            []

        Can.TTuple a b cs ->
            List.concatMap (typeIssues arities context) (a :: b :: cs)

        Can.TAlias home name args aliasType ->
            let
                key =
                    typeKey home name

                arityIssue =
                    case Dict.get key arities.aliases of
                        Nothing ->
                            [ context ++ ": unknown alias " ++ key ]

                        Just arity ->
                            if arity == List.length args then
                                []

                            else
                                [ context
                                    ++ ": alias "
                                    ++ key
                                    ++ " applied to "
                                    ++ String.fromInt (List.length args)
                                    ++ " argument(s), declared with "
                                    ++ String.fromInt arity
                                ]

                body =
                    case aliasType of
                        Can.Holey t ->
                            t

                        Can.Filled t ->
                            t
            in
            arityIssue
                ++ List.concatMap (\( _, t ) -> typeIssues arities context t) args
                ++ typeIssues arities context body



-- ============================================================================
-- WALK
-- ============================================================================


{-| Returns the problems found in the nodes of a typed local graph, each node
labelled by its global as `Module.name`.
-}
collectExprTypeIssues : Arities -> TOpt.LocalGraph Name -> List String
collectExprTypeIssues arities (TOpt.LocalGraph data) =
    Data.Map.foldl
        (\global node acc ->
            nodeIssues arities (globalToString global) node ++ acc
        )
        []
        data.nodes


{-| Returns a global as `Module.name`, leaving out the package.
-}
globalToString : TOpt.Global -> String
globalToString (TOpt.Global home name) =
    case home of
        ModuleName.Canonical _ moduleName ->
            moduleName ++ "." ++ name


{-| Returns the problems in one node: in the body of a `Define`,
`TrackedDefine`, `PortIncoming` or `PortOutgoing` node, or in the values and
definitions of a `Cycle`. Every other kind of node gives none.
-}
nodeIssues : Arities -> String -> TOpt.Node Name -> List String
nodeIssues arities context node =
    case node of
        TOpt.Define expr _ _ ->
            exprIssues arities context expr

        TOpt.TrackedDefine _ expr _ _ ->
            exprIssues arities context expr

        TOpt.Cycle _ values defs _ ->
            List.concatMap (\( name, e ) -> exprIssues arities (context ++ " value " ++ name) e) values
                ++ List.concatMap (defIssues arities context) defs

        TOpt.PortIncoming expr _ _ ->
            exprIssues arities context expr

        TOpt.PortOutgoing expr _ _ ->
            exprIssues arities context expr

        _ ->
            []


{-| Returns the problems in a definition: its declared type, the types of a
`TailDef`'s parameters, and its body.
-}
defIssues : Arities -> String -> TOpt.Def Name -> List String
defIssues arities context def =
    case def of
        TOpt.Def _ name expr tipe ->
            typeIssues arities (context ++ " Def " ++ name) tipe
                ++ exprIssues arities (context ++ " Def " ++ name) expr

        TOpt.TailDef _ name params expr tipe _ ->
            typeIssues arities (context ++ " TailDef " ++ name) tipe
                ++ List.concatMap (\( _, t ) -> typeIssues arities (context ++ " TailDef " ++ name ++ " param") t) params
                ++ exprIssues arities (context ++ " TailDef " ++ name) expr


{-| Returns the problems in the type of `expr` and of every expression inside
it, together with the parameter types of functions, the definitions of `let`s
and the types `Destruct`s store.
-}
exprIssues : Arities -> String -> TOpt.Expr Name -> List String
exprIssues arities context expr =
    typeIssues arities context (TOpt.typeOf expr)
        ++ (case expr of
                TOpt.Function _ params body _ ->
                    List.concatMap (\( _, t ) -> typeIssues arities (context ++ " param") t) params
                        ++ exprIssues arities context body

                TOpt.TrackedFunction _ params body _ ->
                    List.concatMap (\( _, t ) -> typeIssues arities (context ++ " param") t) params
                        ++ exprIssues arities context body

                TOpt.Call _ f args _ ->
                    List.concatMap (exprIssues arities context) (f :: args)

                TOpt.TailCall _ args _ ->
                    List.concatMap (\( _, e ) -> exprIssues arities context e) args

                TOpt.If branches final _ ->
                    List.concatMap (\( c, t ) -> exprIssues arities context c ++ exprIssues arities context t) branches
                        ++ exprIssues arities context final

                TOpt.Let def body _ ->
                    defIssues arities context def
                        ++ exprIssues arities context body

                TOpt.Destruct (TOpt.Destructor _ _ meta) body _ ->
                    typeIssues arities (context ++ " destructor") meta.tipe
                        ++ exprIssues arities context body

                TOpt.Case _ _ decider jumps _ ->
                    List.concatMap (exprIssues arities context) (inlineLeaves decider)
                        ++ List.concatMap (\( _, e ) -> exprIssues arities context e) jumps

                TOpt.List _ items _ ->
                    List.concatMap (exprIssues arities context) items

                TOpt.Access record _ _ _ ->
                    exprIssues arities context record

                TOpt.Update _ record fields _ ->
                    exprIssues arities context record
                        ++ List.concatMap (exprIssues arities context) (Data.Map.values fields)

                TOpt.Record fields _ ->
                    List.concatMap (exprIssues arities context) (Dict.values fields)

                TOpt.TrackedRecord _ fields _ ->
                    List.concatMap (exprIssues arities context) (Data.Map.values fields)

                TOpt.Tuple _ a b rest _ ->
                    List.concatMap (exprIssues arities context) (a :: b :: rest)

                _ ->
                    []
           )


{-| Returns the expressions at the `Inline` leaves of a decision tree.
-}
inlineLeaves : TOpt.Decider (TOpt.Choice Name) -> List (TOpt.Expr Name)
inlineLeaves decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            [ e ]

        TOpt.Leaf (TOpt.Jump _) ->
            []

        TOpt.Chain _ success failure ->
            inlineLeaves success ++ inlineLeaves failure

        TOpt.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> inlineLeaves d) edges ++ inlineLeaves fallback


{-| Returns `xs` without repeated elements, keeping the first of each.
-}
unique : List String -> List String
unique xs =
    List.foldl
        (\x ( seen, acc ) ->
            if Dict.member x seen then
                ( seen, acc )

            else
                ( Dict.insert x () seen, x :: acc )
        )
        ( Dict.empty, [] )
        xs
        |> Tuple.second
        |> List.reverse
