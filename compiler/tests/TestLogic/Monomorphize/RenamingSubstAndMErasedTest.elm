module TestLogic.Monomorphize.RenamingSubstAndMErasedTest exposing (suite)

{-| Runs the substitution engine on three small programs and checks the types
it gives them: no residual number variable anywhere, and the concrete types
that the programs' annotations fix.

The programs are monomorphized with `TestLogic.TestPipeline.runToMono`, which
uses the substitution engine (`Compiler.Monomorphize.Monomorphize`), not the
solver engine the compiler uses by default. A _number variable_ is an
`MVar _ CNumber`, a type variable constrained to `number` that has not been
resolved; it must not reach code generation. An `MVar _ CEcoValue` is an
unconstrained one, which may survive monomorphization as a boxed value: the
let-bound record `r` of the first program and the element type `a` of the
third keep one, and that is not checked against.

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

Each test runs its fixture through `runToMono`, fails with the pipeline's
message on `Err`, and checks with
`TestLogic.Monomorphize.NoCEcoValueInUserFunctions` that no node type,
expression type or parameter type in the graph holds a number variable. It
then checks, ignoring lambda-set annotations:

  - the first program's call through `r.fn` has result type `Int`;
  - `makeAdder` has one specialization, of type `Int -> Int -> ( Int, Int )`;
  - `myFoldl` has one specialization, of type
    `(a -> Int -> Int) -> Int -> List a -> Int` with `a` a `CEcoValue`
    variable: `b` is fixed to `Int` even though `a` is not fixed.

Among what is not tested: the solver engine, and the types of anything other
than the positions listed.

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
import Compiler.AST.TypeIds as TypeIds
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.Monomorphize.NoCEcoValueInUserFunctions as NoNumberVars
import TestLogic.TestPipeline as Pipeline


{-| The three tests, one per fixture, as the module docstring describes them.
-}
suite : Test
suite =
    Test.describe "Renaming substitution alignment & number-variable closing"
        [ Test.test "Bug 1: polymorphic identity in record field: the call through it is Int" <|
            \_ -> checkIdentityInRecordField
        , Test.test "Bug 1: makeAdder curried call is specialized at Int -> Int -> ( Int, Int )" <|
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


{-| The expectation that `identityInRecordModule` monomorphizes with no residual
number variable and that every call in `testValue`'s body has result type
`Int`.
-}
checkIdentityInRecordField : Expectation
checkIdentityInRecordField =
    withGraph identityInRecordModule
        (\graph ->
            case List.concatMap (Maybe.map callResultTypes >> Maybe.withDefault []) (specBodies "testValue" graph) of
                [] ->
                    Expect.fail "no call in testValue — fixture broken"

                resultTypes ->
                    Expect.equal [] (List.filter (\t -> not (Mono.eqKeyLayout t Mono.MInt)) resultTypes)
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


{-| The expectation that `makeAdderModule` monomorphizes with no residual number
variable and that `makeAdder` has one specialization, of type
`Int -> Int -> ( Int, Int )`.
-}
checkMakeAdderCurried : Expectation
checkMakeAdderCurried =
    withGraph makeAdderModule
        (\graph ->
            expectOneSpecOfLayout "makeAdder"
                (Mono.mFunction Mono.topLegacy
                    [ Mono.MInt ]
                    (Mono.mFunction Mono.topLegacy [ Mono.MInt ] (Mono.mTuple [ Mono.MInt, Mono.MInt ]))
                )
                graph
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


{-| The expectation that `foldWithEmptyListModule` monomorphizes with no residual
number variable and that `myFoldl` has one specialization, of type
`(a -> Int -> Int) -> Int -> List a -> Int` with one `CEcoValue` variable `a`.
-}
checkFoldWithEmptyList : Expectation
checkFoldWithEmptyList =
    withGraph foldWithEmptyListModule
        (\graph ->
            case specTypes "myFoldl" graph of
                [ t ] ->
                    case List.filterMap ecoVarOf (elementTypes t) of
                        [ v ] ->
                            let
                                a =
                                    Mono.MVar v Mono.CEcoValue
                            in
                            if Mono.eqKeyLayout t (expectedFoldl a) then
                                Expect.pass

                            else
                                Expect.fail ("myFoldl specialized at " ++ Debug.toString t)

                        _ ->
                            Expect.fail ("expected one CEcoValue list element type in " ++ Debug.toString t)

                types ->
                    Expect.fail ("expected one myFoldl specialization, got " ++ Debug.toString types)
        )


{-| The type `(a -> Int -> Int) -> Int -> List a -> Int`, curried, with
unknown lambda sets.
-}
expectedFoldl : Mono.MonoType -> Mono.MonoType
expectedFoldl a =
    let
        fn arg res =
            Mono.mFunction Mono.topLegacy [ arg ] res
    in
    fn (fn a (fn Mono.MInt Mono.MInt)) (fn Mono.MInt (fn (Mono.mList a) Mono.MInt))



-- ============================================================================
-- HELPERS
-- ============================================================================


{-| Monomorphizes `srcModule` with `runToMono` and passes when the graph holds no
residual number variable and `check` passes on it. Fails with the pipeline's
message if `runToMono` fails.
-}
withGraph : Src.Module -> (Mono.MonoGraph -> Expectation) -> Expectation
withGraph srcModule check =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { monoGraph } ->
            Expect.all
                [ \_ -> NoNumberVars.expectNoResidualNumberVars srcModule
                , \_ -> check monoGraph
                ]
                ()


{-| Returns the registry type of every specialization of the global named
`name`.
-}
specTypes : String -> Mono.MonoGraph -> List Mono.MonoType
specTypes name (Mono.MonoGraph data) =
    List.filterMap
        (\entry ->
            case entry of
                Just ( Mono.Global _ n, t ) ->
                    if n == name then
                        Just t

                    else
                        Nothing

                _ ->
                    Nothing
        )
        (Array.toList data.registry.reverseMapping)


{-| Returns, for every specialization of the global named `name`, the body of
its node when the node is a `MonoDefine` or `MonoTailFunc`.
-}
specBodies : String -> Mono.MonoGraph -> List (Maybe Mono.MonoExpr)
specBodies name (Mono.MonoGraph data) =
    List.filterMap
        (\( specId, entry ) ->
            case entry of
                Just ( Mono.Global _ n, _ ) ->
                    if n == name then
                        case Array.get specId data.nodes of
                            Just (Just (Mono.MonoDefine body _)) ->
                                Just (Just body)

                            Just (Just (Mono.MonoTailFunc _ body _)) ->
                                Just (Just body)

                            _ ->
                                Just Nothing

                    else
                        Nothing

                _ ->
                    Nothing
        )
        (Array.toIndexedList data.registry.reverseMapping)


{-| Returns the result type of every call in `expr`, at any depth.
-}
callResultTypes : Mono.MonoExpr -> List Mono.MonoType
callResultTypes expr =
    MonoTraverse.foldExpr
        (\e acc ->
            case e of
                Mono.MonoCall _ _ _ t _ ->
                    t :: acc

                _ ->
                    acc
        )
        []
        expr


{-| Passes when the global named `name` has exactly one specialization and its
type equals `expected`, ignoring lambda-set annotations.
-}
expectOneSpecOfLayout : String -> Mono.MonoType -> Mono.MonoGraph -> Expectation
expectOneSpecOfLayout name expected graph =
    case specTypes name graph of
        [ t ] ->
            if Mono.eqKeyLayout t expected then
                Expect.pass

            else
                Expect.fail (name ++ " specialized at " ++ Debug.toString t)

        types ->
            Expect.fail ("expected one " ++ name ++ " specialization, got " ++ Debug.toString types)


{-| Returns the element types of every list type in `t`, at any depth.
-}
elementTypes : Mono.MonoType -> List Mono.MonoType
elementTypes t =
    case t of
        Mono.MList _ inner ->
            inner :: elementTypes inner

        Mono.MFunction _ _ args ret ->
            List.concatMap elementTypes args ++ elementTypes ret

        _ ->
            []


{-| Returns the id of `t` when it is a `CEcoValue` variable.
-}
ecoVarOf : Mono.MonoType -> Maybe TypeIds.MVarId
ecoVarOf t =
    case t of
        Mono.MVar v Mono.CEcoValue ->
            Just v

        _ ->
            Nothing
