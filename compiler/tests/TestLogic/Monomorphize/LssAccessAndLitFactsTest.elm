module TestLogic.Monomorphize.LssAccessAndLitFactsTest exposing (suite)

{-| Checks that the lambda sets of functions stored in a record or a list
literal still reach the code that uses them, so that a change which loses them
on the way, leaving the consumer's arrow without an exact set of members, does
not go unnoticed.

A _lambda set_ is the annotation on each arrow of a monomorphized type, a
`Mono.LambdaSetAnno`, saying which functions a value of that type can be.
`Compiler.AST.Monomorphized` owns what each form means. Here, a _singleton_ is
an `LSet` with exactly one member and a _2-set_ is an `LSet` with exactly two;
`LTop`, `LVar` and `LPartial` are neither, whatever they carry.

Each fixture is a module `Test` holding three definitions, `inc` and `dec` of
type `Int -> Int` and `apply g n = g n`, plus the definitions of its shape and
a `testValue` that calls them. `runWith` monomorphizes it with the solver
engine and lambda-set specialization enabled; `TestLogic.TestPipeline` adds a
`main` that makes `testValue` reachable. Three fixtures use a record type with
a function field `f : Int -> Int` and a `String` field `n`, and pass a record
whose `f` is `inc`.

Each test applies one reader to the resulting graph and fails if the pipeline
gives an error, if the reader finds no annotation at all, or if any annotation
it finds is not of the expected kind. Most readers look in the specialization
registry, at every specialization of a definition with a given name.

  - Test 1 (`argShape`): `useRec r = apply r.f 2`, where the record reaches
    `useRec` through a `let` in another definition. The head annotation of the
    first parameter of every specialization of `apply` is a singleton.
  - Test 2 (`calleeShape`): `useRec r = r.f 2`, where the access is itself the
    function called. The head annotation of the type of every record access
    that is called is a singleton.
  - Test 3 (`returnedShape`): `useRec (mk inc)`, where `mk` returns the
    record. The head annotation of field `f` of the record parameter of every
    specialization of `useRec` is a singleton.
  - Test 4 (`listShape`): `let fs = [ inc, dec ] in useL fs`, where `useL`
    ignores its argument. The element arrow of the list parameter of every
    specialization of `useL` is a 2-set.

Among what is not tested: which members a set holds, so a singleton naming a
function other than `inc` would pass; a record or list that is built inside the
consumer, or nested inside another container; and anything after
monomorphization.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , binopsExpr
        , callExpr
        , define
        , intExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , recordExpr
        , strExpr
        , tLambda
        , tRecord
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.MonoTraverse as Traverse
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The four tests, one per fixture shape, as the module docstring lists them.
-}
suite : Test
suite =
    Test.describe "E15 access flow + F4-sig literal facts"
        [ Test.test "1. E15 ARG: `apply r.f 2` hands the HOF the field's singleton" <|
            \() -> expectHeads argShape (calleeHeads "apply") isSingleton "a singleton"
        , Test.test "2. E15 CALLEE: the access-node callee carries the field's singleton" <|
            \() -> expectHeads calleeShape accessCalleeHeads isSingleton "a singleton"
        , Test.test "3. F4-sig: a returned record's field arrow reaches the consumer as the singleton" <|
            \() -> expectHeads returnedShape (fieldHeads "useRec" "f") isSingleton "a singleton"
        , Test.test "4. F4-lit-list: a ground list literal of functions reaches its consumer as the 2-set" <|
            \() -> expectHeads listShape (listElemHeads "useL") isTwoSet "a 2-set"
        ]


{-| Runs `fixture` through `runWith` and passes when `reader` finds at least one
annotation in the resulting graph and `ok` holds for every one of them.

It fails with the pipeline's message when the run gives `Err`, with
"fixture broken" when `reader` finds nothing, and otherwise with `what` and a
rendering of every annotation found. `what` names the expected kind of
annotation and is used only in that message.

-}
expectHeads : Src.Module -> (Mono.MonoGraph -> List Mono.LambdaSetAnno) -> (Mono.LambdaSetAnno -> Bool) -> String -> Expect.Expectation
expectHeads fixture reader ok what =
    case runWith fixture of
        Err e ->
            Expect.fail e

        Ok g ->
            let
                heads =
                    reader g
            in
            if List.isEmpty heads then
                Expect.fail "fixture broken: reader found nothing"

            else if List.all ok heads then
                Expect.pass

            else
                Expect.fail ("expected " ++ what ++ ", got " ++ String.join ", " (List.map describeAnno heads))



-- ====== FIXTURES ======


{-| The source type `Int -> Int`, which every function placed in a record or
list here has.
-}
hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| The source record type `{ f : Int -> Int, n : String }`, the record that
carries a function in the record fixtures.
-}
recT : Src.Type
recT =
    tRecord [ ( "f", hInt ), ( "n", tType "String" [] ) ]


{-| The definitions every fixture starts from: `inc x = x + 1`,
`dec x = x - 1` and `apply g n = g n`, where `g : Int -> Int`.
-}
base : List { name : String, args : List Src.Pattern, tipe : Src.Type, body : Src.Expr }
base =
    [ { name = "inc", args = [ pVar "x" ], tipe = hInt, body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) }
    , { name = "dec", args = [ pVar "x" ], tipe = hInt, body = binopsExpr [ ( varExpr "x", "-" ) ] (intExpr 1) }
    , { name = "apply", args = [ pVar "g", pVar "n" ], tipe = tLambda hInt hInt, body = callExpr (varExpr "g") [ varExpr "n" ] }
    ]


{-| The fixture for test 1, where a field access is passed as an argument:
`useRec r = apply r.f 2`, `build cb = let r = { f = cb, n = "x" } in useRec r`
and `testValue = build inc`.
-}
argShape : Src.Module
argShape =
    makeModuleWithTypedDefsUnionsAliases "Test"
        (base
            ++ [ { name = "useRec", args = [ pVar "r" ], tipe = tLambda recT (tType "Int" []), body = callExpr (varExpr "apply") [ accessExpr (varExpr "r") "f", intExpr 2 ] }
               , { name = "build"
                 , args = [ pVar "cb" ]
                 , tipe = tLambda hInt (tType "Int" [])
                 , body = letExpr [ define "r" [] (recordExpr [ ( "f", varExpr "cb" ), ( "n", strExpr "x" ) ]) ] (callExpr (varExpr "useRec") [ varExpr "r" ])
                 }
               , { name = "testValue", args = [], tipe = tType "Int" [], body = callExpr (varExpr "build") [ varExpr "inc" ] }
               ]
        )
        []
        []


{-| The fixture for test 2, where a field access is itself the function
called: `useRec r = r.f 2`, with `build` and `testValue` as in `argShape`.
-}
calleeShape : Src.Module
calleeShape =
    makeModuleWithTypedDefsUnionsAliases "Test"
        (base
            ++ [ { name = "useRec", args = [ pVar "r" ], tipe = tLambda recT (tType "Int" []), body = callExpr (accessExpr (varExpr "r") "f") [ intExpr 2 ] }
               , { name = "build"
                 , args = [ pVar "cb" ]
                 , tipe = tLambda hInt (tType "Int" [])
                 , body = letExpr [ define "r" [] (recordExpr [ ( "f", varExpr "cb" ), ( "n", strExpr "x" ) ]) ] (callExpr (varExpr "useRec") [ varExpr "r" ])
                 }
               , { name = "testValue", args = [], tipe = tType "Int" [], body = callExpr (varExpr "build") [ varExpr "inc" ] }
               ]
        )
        []
        []


{-| The fixture for test 3, where the record is the result of a definition:
`mk cb = { f = cb, n = "x" }`, `useRec r = apply r.f 2` and
`testValue = useRec (mk inc)`.
-}
returnedShape : Src.Module
returnedShape =
    makeModuleWithTypedDefsUnionsAliases "Test"
        (base
            ++ [ { name = "useRec", args = [ pVar "r" ], tipe = tLambda recT (tType "Int" []), body = callExpr (varExpr "apply") [ accessExpr (varExpr "r") "f", intExpr 2 ] }
               , { name = "mk", args = [ pVar "cb" ], tipe = tLambda hInt recT, body = recordExpr [ ( "f", varExpr "cb" ), ( "n", strExpr "x" ) ] }
               , { name = "testValue", args = [], tipe = tType "Int" [], body = callExpr (varExpr "useRec") [ callExpr (varExpr "mk") [ varExpr "inc" ] ] }
               ]
        )
        []
        []


{-| The fixture for test 4, a list literal of two functions bound in a `let`:
`useL gs = 0`, of type `List (Int -> Int) -> Int`, and
`testValue = let fs = [ inc, dec ] in useL fs`.
-}
listShape : Src.Module
listShape =
    makeModuleWithTypedDefsUnionsAliases "Test"
        (base
            ++ [ { name = "useL", args = [ pVar "gs" ], tipe = tLambda (tType "List" [ hInt ]) (tType "Int" []), body = intExpr 0 }
               , { name = "testValue", args = [], tipe = tType "Int" [], body = letExpr [ define "fs" [] (listExpr [ varExpr "inc", varExpr "dec" ]) ] (callExpr (varExpr "useL") [ varExpr "fs" ]) }
               ]
        )
        []
        []



-- ====== HARNESS / READERS ======


{-| Monomorphizes `srcModule` with the solver engine, the default specialization
limits and the default lambda-set configuration with `enabled` set, returning
the graph or the pipeline's error message.
-}
runWith : Src.Module -> Result String Mono.MonoGraph
runWith srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults | enabled = True }
        srcModule


{-| Returns the type of every specialization in the registry of a top-level
definition named `target`, in any module.
-}
entries : String -> Mono.MonoGraph -> List Mono.MonoType
entries target (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, t ) ->
                    if name == target then
                        t :: acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Returns, for every specialization of `target` whose type is a function, the
head annotation of its first parameter's type.

The head annotation is the annotation on the outermost arrow; a parameter whose
type is not a function contributes `LTop`, as `Mono.headAnno` gives.

-}
calleeHeads : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
calleeHeads target g =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ (p0 :: _) _ ->
                    Just (Mono.headAnno p0)

                _ ->
                    Nothing
        )
        (entries target g)


{-| Returns, for every specialization of `target` whose first parameter is a
record with a field named `field`, the head annotation of that field's type.
-}
fieldHeads : String -> String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
fieldHeads target field g =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ ((Mono.MRecord _ fs) :: _) _ ->
                    Maybe.map Mono.headAnno (Dict.get field fs)

                _ ->
                    Nothing
        )
        (entries target g)


{-| Returns, for every specialization of `target` whose first parameter is a
list, the head annotation of the list's element type.
-}
listElemHeads : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
listElemHeads target g =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ _ ((Mono.MList _ inner) :: _) _ ->
                    Just (Mono.headAnno inner)

                _ ->
                    Nothing
        )
        (entries target g)


{-| Returns the head annotation of the type of every record access that is the
function of a call, anywhere in the body of a `MonoDefine` or `MonoTailFunc`
node. Other kinds of node are not searched.
-}
accessCalleeHeads : Mono.MonoGraph -> List Mono.LambdaSetAnno
accessCalleeHeads (Mono.MonoGraph g) =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    List.foldl
                        (\e a ->
                            Traverse.foldExpr
                                (\x acc2 ->
                                    case x of
                                        Mono.MonoCall _ ((Mono.MonoRecordAccess _ _ _) as callee) _ _ _ ->
                                            Mono.headAnno (Mono.typeOf callee) :: acc2

                                        _ ->
                                            acc2
                                )
                                a
                                e
                        )
                        acc
                        (nodeExprs node)

                Nothing ->
                    acc
        )
        []
        g.nodes


{-| Returns the body of a `MonoDefine` or `MonoTailFunc` node, and nothing for
any other kind of node.
-}
nodeExprs : Mono.MonoNode -> List Mono.MonoExpr
nodeExprs node =
    case node of
        Mono.MonoDefine e _ ->
            [ e ]

        Mono.MonoTailFunc _ e _ ->
            [ e ]

        _ ->
            []


{-| Tells whether an annotation is an `LSet` with exactly one member.
-}
isSingleton : Mono.LambdaSetAnno -> Bool
isSingleton anno =
    case anno of
        Mono.LSet [ _ ] ->
            True

        _ ->
            False


{-| Tells whether an annotation is an `LSet` with exactly two members.
-}
isTwoSet : Mono.LambdaSetAnno -> Bool
isTwoSet anno =
    case anno of
        Mono.LSet [ _, _ ] ->
            True

        _ ->
            False


{-| Renders an annotation for a failure message: its constructor and its member
ids, its variable number, or the label of its top kind.
-}
describeAnno : Mono.LambdaSetAnno -> String
describeAnno anno =
    case anno of
        Mono.LSet ms ->
            "LSet[" ++ String.join "," (List.map String.fromInt ms) ++ "]"

        Mono.LVar v ->
            "LVar" ++ String.fromInt v

        Mono.LTop k ->
            "LTop:" ++ Mono.topKindLabel k

        Mono.LPartial ms ->
            "LPartial[" ++ String.join "," (List.map String.fromInt ms) ++ "]"
