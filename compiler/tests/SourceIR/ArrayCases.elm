module SourceIR.ArrayCases exposing (expectSuite, testCases)

{-| Tests for Array functions that expose type variable scoping issues.

These are EXACT copies of functions from elm/core Array.elm that fail type checking.

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


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Array type variable scoping " ++ condStr) <|
        \_ -> bulkCheck (testCases expectFn)


testCases : (Src.Module -> Expectation) -> List TestCase
testCases expectFn =
    arrayCases expectFn



-- ============================================================================
-- ARRAY CASES
-- ============================================================================


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


noComments : Src.FComments
noComments =
    []


c1 : a -> Src.C1 a
c1 a =
    ( noComments, a )


{-| Pipe operator expression: left |> right
-}
pipeExpr : Src.Expr -> Src.Expr -> Src.Expr
pipeExpr left right =
    binopsExpr [ ( left, "|>" ) ] right


{-| Create a qualified variable (e.g., JsArray.foldl)
-}
qualVarExpr : String -> Name -> Src.Expr
qualVarExpr moduleName name =
    A.At A.zero (Src.VarQual Src.LowVar moduleName name)


{-| Create a qualified constructor (e.g., Array\_elm\_builtin)
-}
qualCtorExpr : Name -> Src.Expr
qualCtorExpr name =
    A.At A.zero (Src.Var Src.CapVar name)


{-| Create a constructor pattern
-}
pCtorQual : Name -> List Src.Pattern -> Src.Pattern
pCtorQual name args =
    A.At A.zero (Src.PCtor A.zero name (List.map c1 args))



-- ============================================================================
-- TYPE HELPERS
-- ============================================================================


{-| Array a type
-}
tArray : Src.Type -> Src.Type
tArray a =
    tType "Array" [ a ]


{-| JsArray a type
-}
tJsArray : Src.Type -> Src.Type
tJsArray a =
    tType "JsArray" [ a ]


{-| Node a type
-}
tNode : Src.Type -> Src.Type
tNode a =
    tType "Node" [ a ]


{-| Tree a type (alias for JsArray (Node a))
-}
tTree : Src.Type -> Src.Type
tTree a =
    tJsArray (tNode a)


{-| Builder a type
-}
tBuilder : Src.Type -> Src.Type
tBuilder a =
    tType "Builder" [ a ]


{-| Int type
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| Bool type
-}
tBool : Src.Type
tBool =
    tType "Bool" []


{-| List a type
-}
tList : Src.Type -> Src.Type
tList a =
    tType "List" [ a ]



-- ============================================================================
-- ARRAY MODULE TYPE DEFINITIONS
-- ============================================================================


{-| Array union type definition:
type Array a = Array\_elm\_builtin Int Int (Tree a) (JsArray a)
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


{-| Node union type definition:
type Node a = SubTree (Tree a) | Leaf (JsArray a)
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


{-| Tree type alias:
type alias Tree a = JsArray (Node a)
-}
treeAlias : AliasDef
treeAlias =
    { name = "Tree"
    , args = [ "a" ]
    , tipe = tJsArray (tNode (tVar "a"))
    }


{-| Builder type alias:
type alias Builder a = { tail : JsArray a, nodeList : List (Node a), nodeListSize : Int }
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


{-| All unions for the Array module.
-}
arrayUnions : List UnionDef
arrayUnions =
    [ arrayUnion, nodeUnion ]


{-| All aliases for the Array module.
-}
arrayAliases : List AliasDef
arrayAliases =
    [ treeAlias, builderAlias ]



-- ============================================================================
-- HELPER FUNCTION STUBS
-- ============================================================================
-- These are stub definitions for helper functions that the tested functions
-- depend on. They have correct type signatures but trivial implementations.


{-| Stub helper functions needed by the Array tests.
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
    , -- sliceLeft : Int -> Array a -> Array a (stub - the real one is tested separately)
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


{-| Helper stubs excluding fromListHelp (for fromListHelpTest).
-}
helperStubsExcludingFromListHelp : List TypedDef
helperStubsExcludingFromListHelp =
    List.filter (\def -> def.name /= "fromListHelp") helperStubs


{-| Helper stubs excluding sliceLeft (for sliceLeftTest).
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

        modul =
            makeModuleWithTypedDefsUnionsAliases "Array" (helperStubs ++ [ repeatDef ]) arrayUnions arrayAliases
    in
    expectFn modul



-- ============================================================================
-- TEST: push
-- ============================================================================
-- push : a -> Array a -> Array a
-- push a ((Array_elm_builtin _ _ _ tail) as array) =
--     unsafeReplaceTail (JsArray.push a tail) array


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

        modul =
            makeModuleWithTypedDefsUnionsAliases "Array" (helperStubs ++ [ pushDef ]) arrayUnions arrayAliases
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

        modul =
            makeModuleWithTypedDefsUnionsAliases "Array" (helperStubs ++ [ sliceDef ]) arrayUnions arrayAliases
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

        modul =
            makeModuleWithTypedDefsUnionsAliases "Array" (helperStubsExcludingFromListHelp ++ [ fromListHelpDef ]) arrayUnions arrayAliases
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

        modul =
            makeModuleWithTypedDefsUnionsAliases "Array" (helperStubs ++ [ appendDef ]) arrayUnions arrayAliases
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

        modul =
            makeModuleWithTypedDefsUnionsAliases "Array" (helperStubsExcludingSliceLeft ++ [ sliceLeftDef ]) arrayUnions arrayAliases
    in
    expectFn modul
