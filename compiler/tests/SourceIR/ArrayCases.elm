module SourceIR.ArrayCases exposing (expectSuite)

{-| Source programs rebuilt from six functions of elm/core's `Array` module, so
that the compiler is run on real library code in which the type variable `a` of
a function's annotation is also at work in constructor patterns, lambdas and
unannotated `let`-bound helpers. The test is named for this: type variable
scoping, meaning how the `a` of an annotation relates to the types found for
the code beneath it.

This module only builds the programs. `expectSuite` hands them, in order, to
the expectation function its caller supplies, stopping at the first that
fails; that function decides what stage the program is run through and what
counts as passing. `SourceIR.Suite.StandardTestSuites` describes how the case
modules are used.

Every program is a module named `Array`, built with
`makeModuleWithTypedDefsUnionsAliases` and so importing that builder's standard
set, `Elm.JsArray as JsArray` among them. It declares the same fixture:

  - the custom type `Array a`, whose one constructor is
    `Array_elm_builtin Int Int (JsArray (Node a)) (JsArray a)`;
  - the custom type `Node a`, with `SubTree (JsArray (Node a))` and
    `Leaf (JsArray a)`;
  - the aliases `Tree a` (for `JsArray (Node a)`) and `Builder a` (a record of
    `tail`, `nodeList` and `nodeListSize`);
  - stubs of `Array` helpers (`helperStubs`), annotated with elm/core's types
    but with trivial bodies;
  - the function under test, rebuilt with the same expression structure as
    the elm/core definition printed in the comment above its test (condensed
    there in places), though without the `Parens` nodes the parser would add,
    replacing the stub of the same name where there is one;
  - `testValue : Array Int`, one application of the function under test.

The tests, each labelled with the function it builds:

  - `repeat function`: `repeat`, which passes a lambda ignoring its argument to
    `initialize`. `testValue` is `repeat 3 42`.
  - `push function`: `push`, whose second argument is an `as` pattern around an
    `Array_elm_builtin` pattern. `testValue` is `push 42 empty`.
  - `slice function`: `slice`, a `let` of two values and an `if` whose `else`
    pipes the array through the `sliceRight` and `sliceLeft` stubs.
    `testValue` is `slice 0 1 empty`.
  - `fromListHelp function`: the recursive `fromListHelp`, which destructures a
    pair in a `let` and conses a `Leaf` onto its list. `testValue` is
    `fromListHelp [] [] 0`.
  - `append function`: `append`, which matches `Array_elm_builtin` in both
    arguments and, in each branch of an `if`, defines a recursive `foldHelper`
    without an annotation, once over an `Array a` accumulator and once over a
    `Builder a`. `testValue` is `append empty empty`.
  - `sliceLeft function`: `sliceLeft`, a nested `if` whose last branch defines
    a recursive `helper` in a `let`, cases on a list, and builds a `Builder`
    record in an inner `let`. `testValue` is `sliceLeft 0 empty`.

Among what is not tested: the rest of the `Array` module, and anything that
depends on the stubbed helpers doing real work.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( AliasDef
        , TypedDef
        , UnionDef
        , binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pAlias
        , pAnything
        , pCons
        , pCtor
        , pList
        , pTuple
        , pVar
        , recordExpr
        , tLambda
        , tRecord
        , tType
        , tVar
        , varExpr
        )
import Compiler.BulkCheck exposing (TestCase, bulkCheck)
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named `"Array type variable scoping "` followed by
`condStr`, that runs the six cases in order through
`Compiler.BulkCheck.bulkCheck`, handing each program to `expectFn`. When a
case returns a failing expectation, the test fails with that case's label and
the cases after it are not run.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Array type variable scoping " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


{-| Returns the cases of this module, each passing its program to `expectFn`.
-}
testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    arrayCases expectFn



-- ============================================================================
-- ARRAY CASES
-- ============================================================================


{-| Returns the six labelled cases, one per rebuilt `Array` function, each
passing its program to `expectFn`.
-}
arrayCases : (Src.Module -> Expectation) -> List TestCase
arrayCases expectFn =
    [ { label = "repeat function", run = repeatTest expectFn }
    , { label = "push function", run = pushTest expectFn }
    , { label = "slice function", run = sliceTest expectFn }
    , { label = "fromListHelp function", run = fromListHelpTest expectFn }
    , { label = "append function", run = appendTest expectFn }
    , { label = "sliceLeft function", run = sliceLeftTest expectFn }
    ]



-- ============================================================================
-- HELPER FUNCTIONS FOR BUILDING SOURCE AST
-- ============================================================================


{-| An empty list of formatting comments, used by `c1`.
-}
noComments : Src.FComments
noComments =
    []


{-| Pairs `a` with an empty list of comments.
-}
c1 : a -> Src.C1 a
c1 a =
    ( noComments, a )


{-| Builds `left |> right`.

Feeding one result into another gives a `Binops` nested inside a `Binops`,
where the parser makes one flat chain; `|>` groups to the left, so the meaning
is the same.

-}
pipeExpr : Src.Expr -> Src.Expr -> Src.Expr
pipeExpr left right =
    binopsExpr [ ( left, "|>" ) ] right


{-| Builds a reference to the lower-case `name` qualified with `moduleName`,
such as `JsArray.foldl`.
-}
qualVarExpr : String -> Name -> Src.Expr
qualVarExpr moduleName name =
    A.At A.zero (Src.VarQual Src.LowVar moduleName name)


{-| Builds an unqualified reference to the constructor `name`, such as
`Array_elm_builtin`.
-}
qualCtorExpr : Name -> Src.Expr
qualCtorExpr name =
    A.At A.zero (Src.Var Src.CapVar name)


{-| Builds a pattern matching the unqualified constructor `name` applied to
`args`.
-}
pCtorQual : Name -> List Src.Pattern -> Src.Pattern
pCtorQual name args =
    A.At A.zero (Src.PCtor A.zero name (List.map c1 args))



-- ============================================================================
-- TYPE HELPERS
-- ============================================================================


{-| Builds the type `Array a`, with `a` the given element type.
-}
tArray : Src.Type -> Src.Type
tArray a =
    tType "Array" [ a ]


{-| Builds the type `JsArray a`, with `a` the given element type.
-}
tJsArray : Src.Type -> Src.Type
tJsArray a =
    tType "JsArray" [ a ]


{-| Builds the type `Node a`, with `a` the given element type.
-}
tNode : Src.Type -> Src.Type
tNode a =
    tType "Node" [ a ]


{-| Builds `JsArray (Node a)`, the type the alias `Tree a` stands for, written
out rather than as a reference to `Tree`.
-}
tTree : Src.Type -> Src.Type
tTree a =
    tJsArray (tNode a)


{-| Builds the type `Builder a`, with `a` the given element type.
-}
tBuilder : Src.Type -> Src.Type
tBuilder a =
    tType "Builder" [ a ]


{-| The type `Int`.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| The type `Bool`.
-}
tBool : Src.Type
tBool =
    tType "Bool" []


{-| Builds the type `List a`, with `a` the given element type.
-}
tList : Src.Type -> Src.Type
tList a =
    tType "List" [ a ]



-- ============================================================================
-- ARRAY MODULE TYPE DEFINITIONS
-- ============================================================================


{-| The declaration of `Array a`, with the one constructor
`Array_elm_builtin Int Int (JsArray (Node a)) (JsArray a)`.

elm/core gives the third argument as `Tree a`; here it is the type that alias
stands for.

-}
arrayUnion : UnionDef
arrayUnion =
    { name = "Array"
    , args = [ "a" ]
    , ctors =
        [ { name = "Array_elm_builtin"
          , args = [ tInt, tInt, tTree (tVar "a"), tJsArray (tVar "a") ]
          }
        ]
    }


{-| The declaration of `Node a`, whose constructors are
`SubTree (JsArray (Node a))` and `Leaf (JsArray a)`.
-}
nodeUnion : UnionDef
nodeUnion =
    { name = "Node"
    , args = [ "a" ]
    , ctors =
        [ { name = "SubTree", args = [ tTree (tVar "a") ] }
        , { name = "Leaf", args = [ tJsArray (tVar "a") ] }
        ]
    }


{-| The declaration `type alias Tree a = JsArray (Node a)`.

Nothing in the built modules refers to `Tree` by name, since `tTree` writes the
type out in full.

-}
treeAlias : AliasDef
treeAlias =
    { name = "Tree"
    , args = [ "a" ]
    , tipe = tJsArray (tNode (tVar "a"))
    }


{-| The declaration of `Builder a`, a record of `tail : JsArray a`,
`nodeList : List (Node a)` and `nodeListSize : Int`.
-}
builderAlias : AliasDef
builderAlias =
    { name = "Builder"
    , args = [ "a" ]
    , tipe =
        tRecord
            [ ( "tail", tJsArray (tVar "a") )
            , ( "nodeList", tList (tNode (tVar "a")) )
            , ( "nodeListSize", tInt )
            ]
    }


{-| The custom types every built module declares: `Array` and `Node`.
-}
arrayUnions : List UnionDef
arrayUnions =
    [ arrayUnion, nodeUnion ]


{-| The aliases every built module declares: `Tree` and `Builder`.
-}
arrayAliases : List AliasDef
arrayAliases =
    [ treeAlias, builderAlias ]



-- ============================================================================
-- HELPER FUNCTION STUBS
-- ============================================================================


{-| Annotated stand-ins for `Array` helpers, each with its elm/core type and a
trivial body.

A stub returning an `Array` returns an empty `Array_elm_builtin` or one of its
arguments unchanged, `builderFromArray` returns an empty `Builder`, and
`shiftStep` and `branchFactor` are the literals 5 and 32. `sliceLeft` and
`fromListHelp` are among them, and their tests leave them out.

-}
helperStubs : List TypedDef
helperStubs =
    [ -- initialize : Int -> (Int -> a) -> Array a
      { name = "initialize"
      , args = [ pVar "n", pVar "f" ]
      , tipe = tLambda tInt (tLambda (tLambda tInt (tVar "a")) (tArray (tVar "a")))
      , body = callExpr (qualCtorExpr "Array_elm_builtin") [ intExpr 0, intExpr 0, qualVarExpr "JsArray" "empty", qualVarExpr "JsArray" "empty" ]
      }
    , -- unsafeReplaceTail : JsArray a -> Array a -> Array a
      { name = "unsafeReplaceTail"
      , args = [ pVar "newTail", pVar "array" ]
      , tipe = tLambda (tJsArray (tVar "a")) (tLambda (tArray (tVar "a")) (tArray (tVar "a")))
      , body = varExpr "array"
      }
    , -- translateIndex : Int -> Array a -> Int
      { name = "translateIndex"
      , args = [ pVar "idx", pVar "array" ]
      , tipe = tLambda tInt (tLambda (tArray (tVar "a")) tInt)
      , body = varExpr "idx"
      }
    , -- sliceRight : Int -> Array a -> Array a
      { name = "sliceRight"
      , args = [ pVar "end", pVar "array" ]
      , tipe = tLambda tInt (tLambda (tArray (tVar "a")) (tArray (tVar "a")))
      , body = varExpr "array"
      }
    , -- sliceLeft : Int -> Array a -> Array a
      { name = "sliceLeft"
      , args = [ pVar "start", pVar "array" ]
      , tipe = tLambda tInt (tLambda (tArray (tVar "a")) (tArray (tVar "a")))
      , body = varExpr "array"
      }
    , -- empty : Array a
      { name = "empty"
      , args = []
      , tipe = tArray (tVar "a")
      , body = callExpr (qualCtorExpr "Array_elm_builtin") [ intExpr 0, intExpr 0, qualVarExpr "JsArray" "empty", qualVarExpr "JsArray" "empty" ]
      }
    , -- builderToArray : Bool -> Builder a -> Array a
      { name = "builderToArray"
      , args = [ pVar "reverseNodeList", pVar "builder" ]
      , tipe = tLambda tBool (tLambda (tBuilder (tVar "a")) (tArray (tVar "a")))
      , body = callExpr (qualCtorExpr "Array_elm_builtin") [ intExpr 0, intExpr 0, qualVarExpr "JsArray" "empty", qualVarExpr "JsArray" "empty" ]
      }
    , -- builderFromArray : Array a -> Builder a
      { name = "builderFromArray"
      , args = [ pVar "array" ]
      , tipe = tLambda (tArray (tVar "a")) (tBuilder (tVar "a"))
      , body = recordExpr [ ( "tail", qualVarExpr "JsArray" "empty" ), ( "nodeList", listExpr [] ), ( "nodeListSize", intExpr 0 ) ]
      }
    , -- appendHelpTree : JsArray a -> Array a -> Array a
      { name = "appendHelpTree"
      , args = [ pVar "toAppend", pVar "array" ]
      , tipe = tLambda (tJsArray (tVar "a")) (tLambda (tArray (tVar "a")) (tArray (tVar "a")))
      , body = varExpr "array"
      }
    , -- appendHelpBuilder : JsArray a -> Builder a -> Builder a
      { name = "appendHelpBuilder"
      , args = [ pVar "toAppend", pVar "builder" ]
      , tipe = tLambda (tJsArray (tVar "a")) (tLambda (tBuilder (tVar "a")) (tBuilder (tVar "a")))
      , body = varExpr "builder"
      }
    , -- tailIndex : Int -> Int
      { name = "tailIndex"
      , args = [ pVar "len" ]
      , tipe = tLambda tInt tInt
      , body = varExpr "len"
      }
    , -- shiftStep : Int
      { name = "shiftStep"
      , args = []
      , tipe = tInt
      , body = intExpr 5
      }
    , -- branchFactor : Int
      { name = "branchFactor"
      , args = []
      , tipe = tInt
      , body = intExpr 32
      }
    , -- fromListHelp : List a -> List (Node a) -> Int -> Array a
      { name = "fromListHelp"
      , args = [ pVar "list", pVar "nodeList", pVar "nodeListSize" ]
      , tipe = tLambda (tList (tVar "a")) (tLambda (tList (tNode (tVar "a"))) (tLambda tInt (tArray (tVar "a"))))
      , body = callExpr (qualCtorExpr "Array_elm_builtin") [ intExpr 0, intExpr 0, qualVarExpr "JsArray" "empty", qualVarExpr "JsArray" "empty" ]
      }
    ]


{-| The stubs without `fromListHelp`, so that `fromListHelpTest` can add its
own.
-}
helperStubsExcludingFromListHelp : List TypedDef
helperStubsExcludingFromListHelp =
    List.filter (\def -> def.name /= "fromListHelp") helperStubs


{-| The stubs without `sliceLeft`, so that `sliceLeftTest` can add its own.
-}
helperStubsExcludingSliceLeft : List TypedDef
helperStubsExcludingSliceLeft =
    List.filter (\def -> def.name /= "sliceLeft") helperStubs



-- ============================================================================
-- TEST: repeat
-- ============================================================================
-- repeat : Int -> a -> Array a
-- repeat n e =
--     initialize n (\_ -> e)


{-| Builds the fixture module with `repeat` and returns what `expectFn` gives
for it.
-}
repeatTest : (Src.Module -> Expectation) -> (() -> Expectation)
repeatTest expectFn _ =
    let
        -- Type: Int -> a -> Array a
        repeatType =
            tLambda tInt (tLambda (tVar "a") (tArray (tVar "a")))

        -- Body: initialize n (\_ -> e)
        repeatBody =
            callExpr
                (varExpr "initialize")
                [ varExpr "n"
                , lambdaExpr [ pAnything ] (varExpr "e")
                ]

        repeatDef =
            { name = "repeat"
            , args = [ pVar "n", pVar "e" ]
            , tipe = repeatType
            , body = repeatBody
            }

        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tArray tInt
            , body = callExpr (varExpr "repeat") [ intExpr 3, intExpr 42 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Array" (helperStubs ++ [ repeatDef, testValueDef ]) arrayUnions arrayAliases
    in
    expectFn modul



-- ============================================================================
-- TEST: push
-- ============================================================================
-- push : a -> Array a -> Array a
-- push a ((Array_elm_builtin _ _ _ tail) as array) =
--     unsafeReplaceTail (JsArray.push a tail) array


{-| Builds the fixture module with `push` and returns what `expectFn` gives
for it.
-}
pushTest : (Src.Module -> Expectation) -> (() -> Expectation)
pushTest expectFn _ =
    let
        -- Type: a -> Array a -> Array a
        pushType =
            tLambda (tVar "a") (tLambda (tArray (tVar "a")) (tArray (tVar "a")))

        -- Pattern: ((Array_elm_builtin _ _ _ tail) as array)
        innerPattern =
            pCtorQual "Array_elm_builtin" [ pAnything, pAnything, pAnything, pVar "tail" ]

        arrayPattern =
            pAlias innerPattern "array"

        -- Body: unsafeReplaceTail (JsArray.push a tail) array
        pushBody =
            callExpr
                (varExpr "unsafeReplaceTail")
                [ callExpr (qualVarExpr "JsArray" "push") [ varExpr "a", varExpr "tail" ]
                , varExpr "array"
                ]

        pushDef =
            { name = "push"
            , args = [ pVar "a", arrayPattern ]
            , tipe = pushType
            , body = pushBody
            }

        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tArray tInt
            , body = callExpr (varExpr "push") [ intExpr 42, varExpr "empty" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Array" (helperStubs ++ [ pushDef, testValueDef ]) arrayUnions arrayAliases
    in
    expectFn modul



-- ============================================================================
-- TEST: slice
-- ============================================================================
-- slice : Int -> Int -> Array a -> Array a
-- slice from to array =
--     let
--         correctFrom = translateIndex from array
--         correctTo = translateIndex to array
--     in
--         if correctFrom > correctTo then
--             empty
--         else
--             array
--                 |> sliceRight correctTo
--                 |> sliceLeft correctFrom


{-| Builds the fixture module with `slice` and returns what `expectFn` gives
for it.
-}
sliceTest : (Src.Module -> Expectation) -> (() -> Expectation)
sliceTest expectFn _ =
    let
        -- Type: Int -> Int -> Array a -> Array a
        sliceType =
            tLambda tInt (tLambda tInt (tLambda (tArray (tVar "a")) (tArray (tVar "a"))))

        -- let correctFrom = translateIndex from array
        correctFromDef =
            define "correctFrom" [] (callExpr (varExpr "translateIndex") [ varExpr "from", varExpr "array" ])

        -- let correctTo = translateIndex to array
        correctToDef =
            define "correctTo" [] (callExpr (varExpr "translateIndex") [ varExpr "to", varExpr "array" ])

        -- if correctFrom > correctTo then empty else ...
        elseExpr =
            pipeExpr
                (pipeExpr
                    (varExpr "array")
                    (callExpr (varExpr "sliceRight") [ varExpr "correctTo" ])
                )
                (callExpr (varExpr "sliceLeft") [ varExpr "correctFrom" ])

        ifBody =
            ifExpr
                (binopsExpr [ ( varExpr "correctFrom", ">" ) ] (varExpr "correctTo"))
                (varExpr "empty")
                elseExpr

        sliceBody =
            letExpr [ correctFromDef, correctToDef ] ifBody

        sliceDef =
            { name = "slice"
            , args = [ pVar "from", pVar "to", pVar "array" ]
            , tipe = sliceType
            , body = sliceBody
            }

        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tArray tInt
            , body = callExpr (varExpr "slice") [ intExpr 0, intExpr 1, varExpr "empty" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Array" (helperStubs ++ [ sliceDef, testValueDef ]) arrayUnions arrayAliases
    in
    expectFn modul



-- ============================================================================
-- TEST: fromListHelp
-- ============================================================================
-- fromListHelp : List a -> List (Node a) -> Int -> Array a
-- fromListHelp list nodeList nodeListSize =
--     let
--         ( jsArray, remainingItems ) =
--             JsArray.initializeFromList branchFactor list
--     in
--         if JsArray.length jsArray < branchFactor then
--             builderToArray True
--                 { tail = jsArray
--                 , nodeList = nodeList
--                 , nodeListSize = nodeListSize
--                 }
--         else
--             fromListHelp
--                 remainingItems
--                 (Leaf jsArray :: nodeList)
--                 (nodeListSize + 1)


{-| Builds the fixture module with `fromListHelp` and returns what `expectFn`
gives for it.
-}
fromListHelpTest : (Src.Module -> Expectation) -> (() -> Expectation)
fromListHelpTest expectFn _ =
    let
        -- Type: List a -> List (Node a) -> Int -> Array a
        fromListHelpType =
            tLambda (tList (tVar "a"))
                (tLambda (tList (tNode (tVar "a")))
                    (tLambda tInt (tArray (tVar "a")))
                )

        -- let ( jsArray, remainingItems ) = JsArray.initializeFromList branchFactor list
        destructDef =
            Src.Destruct
                (pTuple (pVar "jsArray") (pVar "remainingItems"))
                (c1 (callExpr (qualVarExpr "JsArray" "initializeFromList") [ varExpr "branchFactor", varExpr "list" ]))

        -- if JsArray.length jsArray < branchFactor then ... else ...
        thenExpr =
            callExpr
                (varExpr "builderToArray")
                [ boolExpr True
                , recordExpr
                    [ ( "tail", varExpr "jsArray" )
                    , ( "nodeList", varExpr "nodeList" )
                    , ( "nodeListSize", varExpr "nodeListSize" )
                    ]
                ]

        -- (Leaf jsArray :: nodeList)
        consExpr =
            binopsExpr
                [ ( callExpr (qualCtorExpr "Leaf") [ varExpr "jsArray" ], "::" ) ]
                (varExpr "nodeList")

        -- (nodeListSize + 1)
        plusOneExpr =
            binopsExpr [ ( varExpr "nodeListSize", "+" ) ] (intExpr 1)

        elseExpr =
            callExpr
                (varExpr "fromListHelp")
                [ varExpr "remainingItems"
                , consExpr
                , plusOneExpr
                ]

        ifBody =
            ifExpr
                (binopsExpr
                    [ ( callExpr (qualVarExpr "JsArray" "length") [ varExpr "jsArray" ], "<" ) ]
                    (varExpr "branchFactor")
                )
                thenExpr
                elseExpr

        fromListHelpBody =
            letExpr [ destructDef ] ifBody

        fromListHelpDef =
            { name = "fromListHelp"
            , args = [ pVar "list", pVar "nodeList", pVar "nodeListSize" ]
            , tipe = fromListHelpType
            , body = fromListHelpBody
            }

        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tArray tInt
            , body = callExpr (varExpr "fromListHelp") [ listExpr [], listExpr [], intExpr 0 ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Array" (helperStubsExcludingFromListHelp ++ [ fromListHelpDef, testValueDef ]) arrayUnions arrayAliases
    in
    expectFn modul



-- ============================================================================
-- TEST: append
-- ============================================================================
-- append : Array a -> Array a -> Array a
-- append ((Array_elm_builtin _ _ _ aTail) as a) (Array_elm_builtin bLen _ bTree bTail) =
--     if bLen <= (branchFactor * 4) then
--         let
--             foldHelper node array =
--                 case node of
--                     SubTree tree ->
--                         JsArray.foldl foldHelper array tree
--                     Leaf leaf ->
--                         appendHelpTree leaf array
--         in
--             JsArray.foldl foldHelper a bTree
--                 |> appendHelpTree bTail
--     else
--         let
--             foldHelper node builder =
--                 case node of
--                     SubTree tree ->
--                         JsArray.foldl foldHelper builder tree
--                     Leaf leaf ->
--                         appendHelpBuilder leaf builder
--         in
--             JsArray.foldl foldHelper (builderFromArray a) bTree
--                 |> appendHelpBuilder bTail
--                 |> builderToArray True


{-| Builds the fixture module with `append` and returns what `expectFn` gives
for it.
-}
appendTest : (Src.Module -> Expectation) -> (() -> Expectation)
appendTest expectFn _ =
    let
        -- Type: Array a -> Array a -> Array a
        appendType =
            tLambda (tArray (tVar "a")) (tLambda (tArray (tVar "a")) (tArray (tVar "a")))

        -- Pattern for first arg: ((Array_elm_builtin _ _ _ aTail) as a)
        firstArgInner =
            pCtorQual "Array_elm_builtin" [ pAnything, pAnything, pAnything, pVar "aTail" ]

        firstArg =
            pAlias firstArgInner "a"

        -- Pattern for second arg: (Array_elm_builtin bLen _ bTree bTail)
        secondArg =
            pCtorQual "Array_elm_builtin" [ pVar "bLen", pAnything, pVar "bTree", pVar "bTail" ]

        -- First branch foldHelper:
        -- foldHelper node array =
        --     case node of
        --         SubTree tree -> JsArray.foldl foldHelper array tree
        --         Leaf leaf -> appendHelpTree leaf array
        foldHelper1Body =
            caseExpr (varExpr "node")
                [ ( pCtor "SubTree" [ pVar "tree" ]
                  , callExpr (qualVarExpr "JsArray" "foldl")
                        [ varExpr "foldHelper", varExpr "array", varExpr "tree" ]
                  )
                , ( pCtor "Leaf" [ pVar "leaf" ]
                  , callExpr (varExpr "appendHelpTree") [ varExpr "leaf", varExpr "array" ]
                  )
                ]

        foldHelper1Def =
            define "foldHelper" [ pVar "node", pVar "array" ] foldHelper1Body

        -- JsArray.foldl foldHelper a bTree |> appendHelpTree bTail
        thenBranch =
            pipeExpr
                (callExpr (qualVarExpr "JsArray" "foldl")
                    [ varExpr "foldHelper", varExpr "a", varExpr "bTree" ]
                )
                (callExpr (varExpr "appendHelpTree") [ varExpr "bTail" ])

        thenExpr =
            letExpr [ foldHelper1Def ] thenBranch

        -- Second branch foldHelper:
        -- foldHelper node builder =
        --     case node of
        --         SubTree tree -> JsArray.foldl foldHelper builder tree
        --         Leaf leaf -> appendHelpBuilder leaf builder
        foldHelper2Body =
            caseExpr (varExpr "node")
                [ ( pCtor "SubTree" [ pVar "tree" ]
                  , callExpr (qualVarExpr "JsArray" "foldl")
                        [ varExpr "foldHelper", varExpr "builder", varExpr "tree" ]
                  )
                , ( pCtor "Leaf" [ pVar "leaf" ]
                  , callExpr (varExpr "appendHelpBuilder") [ varExpr "leaf", varExpr "builder" ]
                  )
                ]

        foldHelper2Def =
            define "foldHelper" [ pVar "node", pVar "builder" ] foldHelper2Body

        -- JsArray.foldl foldHelper (builderFromArray a) bTree
        --     |> appendHelpBuilder bTail
        --     |> builderToArray True
        elseBranch =
            pipeExpr
                (pipeExpr
                    (callExpr (qualVarExpr "JsArray" "foldl")
                        [ varExpr "foldHelper"
                        , callExpr (varExpr "builderFromArray") [ varExpr "a" ]
                        , varExpr "bTree"
                        ]
                    )
                    (callExpr (varExpr "appendHelpBuilder") [ varExpr "bTail" ])
                )
                (callExpr (varExpr "builderToArray") [ boolExpr True ])

        elseExpr =
            letExpr [ foldHelper2Def ] elseBranch

        -- if bLen <= (branchFactor * 4) then ... else ...
        condExpr =
            binopsExpr
                [ ( varExpr "bLen", "<=" ) ]
                (binopsExpr [ ( varExpr "branchFactor", "*" ) ] (intExpr 4))

        appendBody =
            ifExpr condExpr thenExpr elseExpr

        appendDef =
            { name = "append"
            , args = [ firstArg, secondArg ]
            , tipe = appendType
            , body = appendBody
            }

        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tArray tInt
            , body = callExpr (varExpr "append") [ varExpr "empty", varExpr "empty" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Array" (helperStubs ++ [ appendDef, testValueDef ]) arrayUnions arrayAliases
    in
    expectFn modul



-- ============================================================================
-- TEST: sliceLeft
-- ============================================================================
-- sliceLeft : Int -> Array a -> Array a
-- sliceLeft from ((Array_elm_builtin len _ tree tail) as array) =
--     if from == 0 then
--         array
--     else if from >= tailIndex len then
--         Array_elm_builtin (len - from) shiftStep JsArray.empty <|
--             JsArray.slice (from - tailIndex len) (JsArray.length tail) tail
--     else
--         let
--             helper node acc =
--                 case node of
--                     SubTree subTree ->
--                         JsArray.foldr helper acc subTree
--                     Leaf leaf ->
--                         leaf :: acc
--
--             leafNodes = JsArray.foldr helper [ tail ] tree
--             skipNodes = from // branchFactor
--             nodesToInsert = List.drop skipNodes leafNodes
--         in
--             case nodesToInsert of
--                 [] -> empty
--                 head :: rest ->
--                     let
--                         firstSlice = from - (skipNodes * branchFactor)
--                         initialBuilder =
--                             { tail = JsArray.slice firstSlice (JsArray.length head) head
--                             , nodeList = []
--                             , nodeListSize = 0
--                             }
--                     in
--                         List.foldl appendHelpBuilder initialBuilder rest
--                             |> builderToArray True


{-| Builds the fixture module with `sliceLeft` and returns what `expectFn` gives
for it.
-}
sliceLeftTest : (Src.Module -> Expectation) -> (() -> Expectation)
sliceLeftTest expectFn _ =
    let
        -- Type: Int -> Array a -> Array a
        sliceLeftType =
            tLambda tInt (tLambda (tArray (tVar "a")) (tArray (tVar "a")))

        -- Pattern: ((Array_elm_builtin len _ tree tail) as array)
        innerPattern =
            pCtorQual "Array_elm_builtin" [ pVar "len", pAnything, pVar "tree", pVar "tail" ]

        arrayPattern =
            pAlias innerPattern "array"

        -- helper node acc = case node of ...
        helperBody =
            caseExpr (varExpr "node")
                [ ( pCtor "SubTree" [ pVar "subTree" ]
                  , callExpr (qualVarExpr "JsArray" "foldr")
                        [ varExpr "helper", varExpr "acc", varExpr "subTree" ]
                  )
                , ( pCtor "Leaf" [ pVar "leaf" ]
                  , binopsExpr [ ( varExpr "leaf", "::" ) ] (varExpr "acc")
                  )
                ]

        helperDef =
            define "helper" [ pVar "node", pVar "acc" ] helperBody

        -- leafNodes = JsArray.foldr helper [ tail ] tree
        leafNodesDef =
            define "leafNodes"
                []
                (callExpr (qualVarExpr "JsArray" "foldr")
                    [ varExpr "helper"
                    , listExpr [ varExpr "tail" ]
                    , varExpr "tree"
                    ]
                )

        -- skipNodes = from // branchFactor
        skipNodesDef =
            define "skipNodes"
                []
                (binopsExpr [ ( varExpr "from", "//" ) ] (varExpr "branchFactor"))

        -- nodesToInsert = List.drop skipNodes leafNodes
        nodesToInsertDef =
            define "nodesToInsert"
                []
                (callExpr (qualVarExpr "List" "drop") [ varExpr "skipNodes", varExpr "leafNodes" ])

        -- firstSlice = from - (skipNodes * branchFactor)
        firstSliceDef =
            define "firstSlice"
                []
                (binopsExpr
                    [ ( varExpr "from", "-" ) ]
                    (binopsExpr [ ( varExpr "skipNodes", "*" ) ] (varExpr "branchFactor"))
                )

        -- initialBuilder = { tail = ..., nodeList = [], nodeListSize = 0 }
        initialBuilderDef =
            define "initialBuilder"
                []
                (recordExpr
                    [ ( "tail"
                      , callExpr (qualVarExpr "JsArray" "slice")
                            [ varExpr "firstSlice"
                            , callExpr (qualVarExpr "JsArray" "length") [ varExpr "head" ]
                            , varExpr "head"
                            ]
                      )
                    , ( "nodeList", listExpr [] )
                    , ( "nodeListSize", intExpr 0 )
                    ]
                )

        -- List.foldl appendHelpBuilder initialBuilder rest |> builderToArray True
        innerLetBody =
            pipeExpr
                (callExpr (qualVarExpr "List" "foldl")
                    [ varExpr "appendHelpBuilder", varExpr "initialBuilder", varExpr "rest" ]
                )
                (callExpr (varExpr "builderToArray") [ boolExpr True ])

        headRestBranch =
            letExpr [ firstSliceDef, initialBuilderDef ] innerLetBody

        -- case nodesToInsert of [] -> empty; head :: rest -> ...
        caseBody =
            caseExpr (varExpr "nodesToInsert")
                [ ( pList [], varExpr "empty" )
                , ( pCons (pVar "head") (pVar "rest"), headRestBranch )
                ]

        elseBranch2 =
            letExpr [ helperDef, leafNodesDef, skipNodesDef, nodesToInsertDef ] caseBody

        -- else if from >= tailIndex len then ...
        elseBranch1Cond =
            binopsExpr
                [ ( varExpr "from", ">=" ) ]
                (callExpr (varExpr "tailIndex") [ varExpr "len" ])

        -- Array_elm_builtin (len - from) shiftStep JsArray.empty <| JsArray.slice ...
        elseBranch1Body =
            binopsExpr
                [ ( callExpr (qualCtorExpr "Array_elm_builtin")
                        [ binopsExpr [ ( varExpr "len", "-" ) ] (varExpr "from")
                        , varExpr "shiftStep"
                        , qualVarExpr "JsArray" "empty"
                        ]
                  , "<|"
                  )
                ]
                (callExpr (qualVarExpr "JsArray" "slice")
                    [ binopsExpr
                        [ ( varExpr "from", "-" ) ]
                        (callExpr (varExpr "tailIndex") [ varExpr "len" ])
                    , callExpr (qualVarExpr "JsArray" "length") [ varExpr "tail" ]
                    , varExpr "tail"
                    ]
                )

        -- if from == 0 then array else if ... then ... else ...
        sliceLeftBody =
            ifExpr
                (binopsExpr [ ( varExpr "from", "==" ) ] (intExpr 0))
                (varExpr "array")
                (ifExpr elseBranch1Cond elseBranch1Body elseBranch2)

        sliceLeftDef =
            { name = "sliceLeft"
            , args = [ pVar "from", arrayPattern ]
            , tipe = sliceLeftType
            , body = sliceLeftBody
            }

        testValueDef =
            { name = "testValue"
            , args = []
            , tipe = tArray tInt
            , body = callExpr (varExpr "sliceLeft") [ intExpr 0, varExpr "empty" ]
            }

        modul =
            makeModuleWithTypedDefsUnionsAliases "Array" (helperStubsExcludingSliceLeft ++ [ sliceLeftDef, testValueDef ]) arrayUnions arrayAliases
    in
    expectFn modul
