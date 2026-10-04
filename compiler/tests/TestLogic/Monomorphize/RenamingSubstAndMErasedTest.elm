module TestLogic.Monomorphize.RenamingSubstAndMErasedTest exposing (suite)

{-| Runs the substitution engine on three small programs, so that a change
making it return an error on one of them fails a test here.

The programs are monomorphized with `TestLogic.TestPipeline.runToMono`, which
uses the substitution engine (`Compiler.Monomorphize.Monomorphize`), not the
solver engine the compiler uses by default. A _specialization_ is one copy of a
definition, held as a node of the resulting graph. Call a specialization _fully
monomorphic_ when its own type holds no type variable (`MVar`) at all. A
_number variable_ is an `MVar _ CNumber`, a type variable constrained to
`number` that has not been resolved; an `MVar _ CEcoValue` is an unconstrained
one, which may survive monomorphization as a boxed value.

Each test looks for number variables inside the fully monomorphic
`MonoDefine` and `MonoTailFunc` specializations. Despite the names
(`findCEcoValueInFullyMonomorphicSpecs`, "has no CEcoValue"), a `CEcoValue`
variable is never reported. The check cannot fail: the substitution engine ends
with `Compiler.Monomorphize.Prune.pruneUnreachableSpecs`, which turns every
number variable in the kept nodes' types into `MInt` and crashes if one
remains. So each test passes exactly when `runToMono` returns `Ok`, and a
leftover number variable would show as a crash, not a test failure.

The fixtures are built with `makeModuleWithTypedDefs` as module `Test`, and
every top-level definition is annotated. The test pipeline adds a `main` that
uses `testValue`, which is what makes the definitions reachable.

  - `identityInRecordModule`: `testValue : Int` stores the unannotated lambda
    `\x -> x` in a let-bound record field and calls it through the field on
    `42`.
  - `makeAdderModule`: `makeAdder : Int -> Int -> ( Int, Int )` pairs its two
    arguments, and `testValue` is `makeAdder 5 3`.
  - `foldWithEmptyListModule`: `myFoldl`, a recursive left fold over a list
    with the type `(a -> b -> b) -> b -> List a -> b`, is called as
    `myFoldl (\entry acc -> acc + 1) 0 []` by `testValue : Int`. Nothing in
    the program fixes the element type `a`.

Each of the three tests runs its fixture through `runToMono`, fails with the
pipeline's message on `Err`, and otherwise fails if the walk reports a number
variable, which it cannot.

Among what is not tested: the solver engine; `CEcoValue` variables anywhere;
specializations whose own type holds a variable; the types of expressions
nested under anything other than a closure, a call or a let (case and if
branches, record fields, list and tuple elements); closure captures; and the
actual MonoTypes the specializations receive.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( accessExpr
        , binopsExpr
        , callExpr
        , caseExpr
        , define
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefs
        , pCons
        , pList
        , pVar
        , recordExpr
        , tLambda
        , tTuple
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.Data.Id as Id
import Dict
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The three tests, one per fixture, as the module docstring describes them.
-}
suite : Test
suite =
    Test.describe "Renaming substitution alignment & CEcoValue poisoning"
        [ Test.test "Bug 1: polymorphic identity in record field has no CEcoValue" <|
            \_ -> checkIdentityInRecordField
        , Test.test "Bug 1: makeAdder curried call has no CEcoValue" <|
            \_ -> checkMakeAdderCurried
        , Test.test "Bug 2: fold with empty list retains concrete types" <|
            \_ -> checkFoldWithEmptyList
        ]



-- ============================================================================
-- TEST 1: Identity function in a record field
-- ============================================================================


{-| A module whose only definition stores an identity lambda in a record field
and calls it through the field:

    testValue : Int
    testValue =
        let
            r =
                { fn = \x -> x }
        in
        r.fn 42

-}
identityInRecordModule : Src.Module
identityInRecordModule =
    let
        intType =
            tType "Int" []
    in
    makeModuleWithTypedDefs "Test"
        [ { name = "testValue"
          , args = []
          , tipe = intType
          , body =
                letExpr
                    [ define "r" [] (recordExpr [ ( "fn", lambdaExpr [ pVar "x" ] (varExpr "x") ) ])
                    ]
                    (callExpr (accessExpr (varExpr "r") "fn") [ intExpr 42 ])
          }
        ]


{-| The expectation that `identityInRecordModule` monomorphizes and that
`findCEcoValueInFullyMonomorphicSpecs` reports nothing in the graph.
-}
checkIdentityInRecordField : Expectation
checkIdentityInRecordField =
    case Pipeline.runToMono identityInRecordModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    findCEcoValueInFullyMonomorphicSpecs monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail
                    ("Found CEcoValue in fully monomorphic specs (Bug 1 - renaming disconnect):\n"
                        ++ String.join "\n" violations
                    )



-- ============================================================================
-- TEST 2: Two-argument function returning a tuple
-- ============================================================================


{-| A module with a two-argument function that pairs its arguments, called
with both:

    makeAdder : Int -> Int -> ( Int, Int )
    makeAdder n x =
        ( n, x )

    testValue : ( Int, Int )
    testValue =
        makeAdder 5 3

-}
makeAdderModule : Src.Module
makeAdderModule =
    let
        intType =
            tType "Int" []

        tupleType =
            tTuple intType intType

        funcType =
            tLambda intType (tLambda intType tupleType)
    in
    makeModuleWithTypedDefs "Test"
        [ { name = "makeAdder"
          , args = [ pVar "n", pVar "x" ]
          , tipe = funcType
          , body = tupleExpr (varExpr "n") (varExpr "x")
          }
        , { name = "testValue"
          , args = []
          , tipe = tupleType
          , body = callExpr (varExpr "makeAdder") [ intExpr 5, intExpr 3 ]
          }
        ]


{-| The expectation that `makeAdderModule` monomorphizes and that
`findCEcoValueInFullyMonomorphicSpecs` reports nothing in the graph.
-}
checkMakeAdderCurried : Expectation
checkMakeAdderCurried =
    case Pipeline.runToMono makeAdderModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    findCEcoValueInFullyMonomorphicSpecs monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail
                    ("Found CEcoValue in fully monomorphic specs (Bug 1 - curried renaming):\n"
                        ++ String.join "\n" violations
                    )



-- ============================================================================
-- TEST 3: Fold over an empty list
-- ============================================================================


{-| A module with a polymorphic, recursive left fold, called on an empty list
with a step function that ignores the element:

    myFoldl : (a -> b -> b) -> b -> List a -> b
    myFoldl step init entries =
        case entries of
            [] ->
                init

            x :: xs ->
                myFoldl step (step x init) xs

    testValue : Int
    testValue =
        myFoldl (\entry acc -> acc + 1) 0 []

The annotation on `testValue` fixes `b` to `Int`; nothing fixes `a`.

-}
foldWithEmptyListModule : Src.Module
foldWithEmptyListModule =
    let
        intType =
            tType "Int" []

        aVar =
            tVar "a"

        bVar =
            tVar "b"

        stepType =
            tLambda aVar (tLambda bVar bVar)

        listAType =
            tType "List" [ aVar ]

        foldlType =
            tLambda stepType (tLambda bVar (tLambda listAType bVar))
    in
    makeModuleWithTypedDefs "Test"
        [ { name = "myFoldl"
          , args = [ pVar "step", pVar "init", pVar "entries" ]
          , tipe = foldlType
          , body =
                caseExpr (varExpr "entries")
                    [ ( pList [], varExpr "init" )
                    , ( pCons (pVar "x") (pVar "xs")
                      , callExpr (varExpr "myFoldl")
                            [ varExpr "step"
                            , callExpr (varExpr "step") [ varExpr "x", varExpr "init" ]
                            , varExpr "xs"
                            ]
                      )
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = intType
          , body =
                callExpr (varExpr "myFoldl")
                    [ lambdaExpr [ pVar "entry", pVar "acc" ]
                        (binopsExpr [ ( varExpr "acc", "+" ) ] (intExpr 1))
                    , intExpr 0
                    , listExpr []
                    ]
          }
        ]


{-| The expectation that `foldWithEmptyListModule` monomorphizes and that
`findCEcoValueInFullyMonomorphicSpecs` reports nothing in the graph.
-}
checkFoldWithEmptyList : Expectation
checkFoldWithEmptyList =
    case Pipeline.runToMono foldWithEmptyListModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    findCEcoValueInFullyMonomorphicSpecs monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail
                    ("Found CEcoValue in fully monomorphic specs (Bug 2 - CEcoValue poisoning):\n"
                        ++ String.join "\n" violations
                    )



-- ============================================================================
-- HELPERS
-- ============================================================================


{-| Returns one message for each type in the graph's fully monomorphic
`MonoDefine` and `MonoTailFunc` nodes that holds a number variable
(`MVar _ CNumber`), as `findCEcoValueInNode` looks for them.

A node is fully monomorphic when its own type holds no `MVar` of either
constraint. Removed specializations (`Nothing` in `nodes`) are skipped, and
each message names its node by its index in `nodes`, which is its SpecId.

-}
findCEcoValueInFullyMonomorphicSpecs : Mono.MonoGraph -> List String
findCEcoValueInFullyMonomorphicSpecs (Mono.MonoGraph data) =
    Array.toList data.nodes
        |> List.indexedMap Tuple.pair
        |> List.concatMap
            (\( specId, maybeNode ) ->
                case maybeNode of
                    Just node ->
                        let
                            keyType =
                                nodeType node
                        in
                        if isFullyMonomorphic keyType then
                            findCEcoValueInNode specId node

                        else
                            []

                    Nothing ->
                        []
            )


{-| Returns whether `monoType` holds no type variable of either constraint.
-}
isFullyMonomorphic : Mono.MonoType -> Bool
isFullyMonomorphic monoType =
    not (containsAnyMVar monoType)


{-| Returns whether `monoType` holds an `MVar` of either constraint at any
depth.
-}
containsAnyMVar : Mono.MonoType -> Bool
containsAnyMVar monoType =
    case monoType of
        Mono.MVar _ _ ->
            True

        Mono.MList _ inner ->
            containsAnyMVar inner

        Mono.MFunction _ _ args ret ->
            List.any containsAnyMVar args || containsAnyMVar ret

        Mono.MRecord _ fields ->
            Dict.foldl (\_ fieldType acc -> acc || containsAnyMVar fieldType) False fields

        Mono.MCustom _ _ _ args ->
            List.any containsAnyMVar args

        Mono.MTuple _ elems ->
            List.any containsAnyMVar elems

        _ ->
            False


{-| Returns the number-variable messages for one node, labelled with
`specId`. A `MonoDefine` contributes its type and its body as
`findCEcoValueInExpr` walks it; a `MonoTailFunc` also contributes its
parameter types. Any other kind of node contributes nothing.
-}
findCEcoValueInNode : Int -> Mono.MonoNode -> List String
findCEcoValueInNode specId node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            collectCEcoValue ctx "node type" monoType
                ++ findCEcoValueInExpr ctx expr

        Mono.MonoTailFunc params expr monoType ->
            collectCEcoValue ctx "node type" monoType
                ++ List.concatMap (\( _, t ) -> collectCEcoValue ctx "param" t) params
                ++ findCEcoValueInExpr ctx expr

        _ ->
            []


{-| Returns the number-variable messages for `expr`, labelled with `ctx`.

A closure contributes its type, its parameter types and its body, but not its
captures. A call contributes its result type, the function and the arguments.
A let contributes its type, its definition and its body. Any other expression
contributes only its own type, so nothing nested inside it is examined.

-}
findCEcoValueInExpr : String -> Mono.MonoExpr -> List String
findCEcoValueInExpr ctx expr =
    case expr of
        Mono.MonoClosure info body closureType ->
            collectCEcoValue ctx "closure type" closureType
                ++ List.concatMap (\( _, t ) -> collectCEcoValue ctx "closure param" t) info.params
                ++ findCEcoValueInExpr ctx body

        Mono.MonoCall _ func args resultType _ ->
            collectCEcoValue ctx "call result" resultType
                ++ findCEcoValueInExpr ctx func
                ++ List.concatMap (findCEcoValueInExpr ctx) args

        Mono.MonoLet def body letType ->
            collectCEcoValue ctx "let type" letType
                ++ findCEcoValueInDefExpr ctx def
                ++ findCEcoValueInExpr ctx body

        _ ->
            collectCEcoValue ctx "expr" (Mono.typeOf expr)


{-| Returns the number-variable messages for a let definition: the bound
expression and, for a tail definition, its parameter types.
-}
findCEcoValueInDefExpr : String -> Mono.MonoDef -> List String
findCEcoValueInDefExpr ctx def =
    case def of
        Mono.MonoDef _ bound ->
            findCEcoValueInExpr ctx bound

        Mono.MonoTailDef _ params bound ->
            List.concatMap (\( _, t ) -> collectCEcoValue ctx "taildef param" t) params
                ++ findCEcoValueInExpr ctx bound


{-| Returns one message if `monoType` holds a number variable, naming `ctx`,
`location`, the variables' ids and the type, and no message otherwise. The
message calls them "CEcoValue vars", but they are the `CNumber` variables that
`collectCEcoValueVars` finds.
-}
collectCEcoValue : String -> String -> Mono.MonoType -> List String
collectCEcoValue ctx location monoType =
    let
        vars =
            collectCEcoValueVars monoType
    in
    if List.isEmpty vars then
        []

    else
        [ ctx ++ " " ++ location ++ ": CEcoValue vars " ++ String.join ", " vars ++ " in " ++ monoTypeToString monoType ]


{-| Returns the ids of the number variables (`MVar _ CNumber`) in `monoType`,
one per occurrence, with record fields taken in field-name order.

Despite the name, a `CEcoValue` variable gives nothing: it may survive
monomorphization as a boxed value, while a number variable should already have
been closed to `MInt` by `Compiler.Monomorphize.Prune`.

-}
collectCEcoValueVars : Mono.MonoType -> List String
collectCEcoValueVars monoType =
    case monoType of
        Mono.MVar _ Mono.CEcoValue ->
            []

        Mono.MVar mvarId Mono.CNumber ->
            [ String.fromInt (Id.toComparable mvarId) ]

        Mono.MList _ inner ->
            collectCEcoValueVars inner

        Mono.MFunction _ _ args ret ->
            List.concatMap collectCEcoValueVars args ++ collectCEcoValueVars ret

        Mono.MRecord _ fields ->
            Dict.foldl (\_ fieldType acc -> acc ++ collectCEcoValueVars fieldType) [] fields

        Mono.MCustom _ _ _ args ->
            List.concatMap collectCEcoValueVars args

        Mono.MTuple _ elems ->
            List.concatMap collectCEcoValueVars elems

        _ ->
            []


{-| Returns the MonoType stored on `node`, for every kind of node.
-}
nodeType : Mono.MonoNode -> Mono.MonoType
nodeType node =
    case node of
        Mono.MonoDefine _ t ->
            t

        Mono.MonoTailFunc _ _ t ->
            t

        Mono.MonoCtor _ t ->
            t

        Mono.MonoEnum _ t ->
            t

        Mono.MonoExtern t ->
            t

        Mono.MonoManagerLeaf _ t ->
            t

        Mono.MonoPortIncoming _ t ->
            t

        Mono.MonoPortOutgoing _ t ->
            t


{-| Renders `monoType` for a failure message, mostly in the form of the `Mono`
smart-constructor call that would build it. A record is shown without its
fields, and a variable by its id alone, without its constraint.
-}
monoTypeToString : Mono.MonoType -> String
monoTypeToString monoType =
    case monoType of
        Mono.MInt ->
            "MInt"

        Mono.MFloat ->
            "MFloat"

        Mono.MBool ->
            "MBool"

        Mono.MChar ->
            "MChar"

        Mono.MString ->
            "MString"

        Mono.MUnit ->
            "MUnit"

        Mono.MList _ inner ->
            "Mono.mList (" ++ monoTypeToString inner ++ ")"

        Mono.MFunction _ _ args ret ->
            "Mono.mFunction ["
                ++ String.join ", " (List.map monoTypeToString args)
                ++ "] "
                ++ monoTypeToString ret

        Mono.MCustom _ _ name args ->
            "Mono.mCustom " ++ name ++ " [" ++ String.join ", " (List.map monoTypeToString args) ++ "]"

        Mono.MRecord _ _ ->
            "Mono.mRecord {...}"

        Mono.MTuple _ elems ->
            "Mono.mTuple [" ++ String.join ", " (List.map monoTypeToString elems) ++ "]"

        Mono.MVar mvarId _ ->
            "MVar \"" ++ String.fromInt (Id.toComparable mvarId) ++ "\""
