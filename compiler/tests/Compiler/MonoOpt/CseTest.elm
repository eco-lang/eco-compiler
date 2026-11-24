module Compiler.MonoOpt.CseTest exposing (suite)

{-| Tests for `Compiler.MonoOpt.Cse.run`, chiefly its hash mode
(plans/seqdict-hash-once-per-function.md): repeated `FNV.hash` calls of one
value in a function body are bound once, seeing through the `let` aliases the
inliner introduces, and never merged when an alias would change which variable
is meant.

Each case runs the pass on a one-spec graph, `graphOf body`, built by hand so
that the test controls exactly which variables are aliases. The body is a
nullary `MonoDefine`; the variables it reads (`k`, `j`, `c`, `other`) are free,
which the pass does not mind. `hash v` is `FNV.hash v` with the kernel key the
pass looks for, `( "Eco", "FNV", "hash" )`. After the pass, `hashArgs` lists the
argument of every hash call left in the body, in tree order, so a merge shows
as one call fewer, and a merge bound with the root shows as the root's name.

The tests establish, in `HashOnly` mode unless said otherwise:

  - Two aliases of one root (`let a = k`, `let b = k`), or a chain
    (`let b = a`), hashed unconditionally, become one hash of the root `k`.
  - A hash bound by a `let` before an `if` and another in a branch (the
    get-then-insert shape) become one.
  - Hashes in two branches only are kept (no unconditional occurrence), as are
    hashes of two different roots, and a hash inside a closure body next to one
    outside it.
  - The same alias name bound to different roots in two list elements is
    resolved per scope, so the hashes are kept.
  - An alias whose name is rebound by a non-alias `let`, or whose root is
    rebound by a local tail function's parameter or by a closure's parameter,
    is not followed past the rebinding.
  - Inside a closure the alias map is empty: two hashes of a captured alias are
    merged as a hash of the alias, never of a root the closure does not see.
  - A body with one hash call is left as it was; a hash of a call, not of a
    variable, is not a candidate; a repeated pure call other than a hash is not
    merged in `HashOnly` mode but is in `General` mode, which also merges
    aliased hashes.
  - `hashGroups` counts the hash groups.

Among what is not tested: hash calls in `case` decision trees, destructuring
binders, tail-function bodies as spec nodes (`MonoTailFunc`), and the
`maxPerDef` cap.

-}

import Array
import Compiler.Core.Annotation as A
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Mono as Mono exposing (MonoExpr(..))
import Compiler.MonoOpt.Cse as Cse
import Data.BitSet as BitSet
import Dict
import Expect
import Test exposing (Test)


{-| The `Cse` tests, as the module docstring lists them.
-}
suite : Test
suite =
    Test.describe "Cse"
        [ Test.describe "hash mode"
            [ argsAfter "two aliases of one root merge into a hash of the root"
                (alias "a" "k" (alias "b" "k" (list [ hash "a", hash "b" ])))
                [ "k" ]
            , argsAfter "an alias chain resolves to its root"
                (alias "a" "k" (alias "b" "a" (list [ hash "a", hash "b" ])))
                [ "k" ]
            , argsAfter "get-then-insert: a let-bound hash and one in a branch merge"
                (alias "a" "k" (letIn "x" (hash "a") (ifThen (local "x") (hash "a"))))
                [ "k" ]
            , argsAfter "hashes only in sibling branches are kept"
                (alias "a" "k" (ifThen (hash "a") (hash "a")))
                [ "a", "a" ]
            , argsAfter "hashes of different roots are kept"
                (alias "a" "k" (alias "b" "j" (list [ hash "a", hash "b" ])))
                [ "a", "b" ]
            , argsAfter "a hash in a closure body and one outside are kept"
                (alias "a" "k" (list [ hash "a", closure "v" (hash "a") ]))
                [ "a", "a" ]
            , argsAfter "one alias name bound to two roots resolves per scope"
                (list [ alias "a" "k" (hash "a"), alias "a" "j" (hash "a") ])
                [ "a", "a" ]
            , argsAfter "an alias name rebound by a non-alias let is not followed"
                (alias "a" "k" (list [ hash "a", letIn "a" (call "other") (hash "a") ]))
                [ "a", "a" ]
            , argsAfter "a root rebound by a tail-function parameter is not followed"
                (alias "a" "k" (tailDef "go" "k" (list [ hash "a", hash "k" ])))
                [ "a", "k" ]
            , argsAfter "a root rebound by a closure parameter is not followed"
                (alias "a" "k" (closure "k" (list [ hash "a", hash "k" ])))
                [ "a", "k" ]
            , argsAfter "inside a closure two hashes of an alias merge as the alias"
                (alias "a" "k" (closure "v" (list [ hash "a", hash "a" ])))
                [ "a" ]
            , argsAfter "a body with one hash is unchanged"
                (alias "a" "k" (list [ hash "a", local "a" ]))
                [ "a" ]
            , Test.test "a hash of a call is not a candidate" <|
                \_ ->
                    let
                        hashOfCall =
                            MonoCall A.zero hashKernel [ call "f" ] Mono.MInt Mono.defaultCallInfo
                    in
                    Expect.equal 2 (hashCalls (bodyAfter Cse.HashOnly (list [ hashOfCall, hashOfCall ])))
            , Test.test "a repeated pure non-hash call is not merged" <|
                \_ ->
                    Expect.equal 2 (compareCalls (bodyAfter Cse.HashOnly (list [ compareAB, compareAB ])))
            , Test.test "hashGroups counts the hash groups" <|
                \_ ->
                    let
                        ( _, stats ) =
                            Cse.run (config Cse.HashOnly) (graphOf (alias "a" "k" (alias "b" "k" (list [ hash "a", hash "b" ]))))
                    in
                    Expect.equal ( 1, 1 ) ( stats.hashGroups, stats.hashMerged )
            ]
        , Test.describe "general mode"
            [ Test.test "a repeated pure call is merged" <|
                \_ ->
                    Expect.equal 1 (compareCalls (bodyAfter Cse.General (list [ compareAB, compareAB ])))
            , Test.test "aliased hashes are merged as a hash of the root" <|
                \_ ->
                    Expect.equal [ "k" ]
                        (hashArgsAfter Cse.General (alias "a" "k" (alias "b" "k" (list [ hash "a", hash "b" ]))))
            ]
        ]


{-| A test that runs the hash mode on `body` and expects the hash arguments
`expected` to be left, in tree order.
-}
argsAfter : String -> MonoExpr -> List String -> Test
argsAfter name body expected =
    Test.test name <|
        \_ -> Expect.equal expected (hashArgsAfter Cse.HashOnly body)


config : Cse.Mode -> Cse.Config
config mode =
    { minCost = 0, maxPerDef = 64, mode = mode }


bodyAfter : Cse.Mode -> MonoExpr -> MonoExpr
bodyAfter mode body =
    case Cse.run (config mode) (graphOf body) of
        ( Mono.MonoGraph g, _ ) ->
            case Array.get 0 g.nodes of
                Just (Just (Mono.MonoDefine b _)) ->
                    b

                _ ->
                    MonoUnit


hashArgsAfter : Cse.Mode -> MonoExpr -> List String
hashArgsAfter mode body =
    hashArgs (bodyAfter mode body)



-- FIXTURE


home : ModuleName.Canonical
home =
    ModuleName.Canonical ( "author", "proj" ) "M"


valTy : Mono.MonoType
valTy =
    Mono.MString


bodyTy : Mono.MonoType
bodyTy =
    Mono.mList Mono.MInt


hashKernel : MonoExpr
hashKernel =
    MonoVarKernel A.zero "Eco" "FNV" "hash" (Mono.mFunction Mono.topLegacy [ valTy ] Mono.MInt)


hash : String -> MonoExpr
hash v =
    MonoCall A.zero hashKernel [ local v ] Mono.MInt Mono.defaultCallInfo


local : String -> MonoExpr
local v =
    MonoVarLocal v valTy


{-| A call of the global `name` with no arguments' worth of meaning: a call the
pass will not treat as a hash, standing for "some other value".
-}
call : String -> MonoExpr
call name =
    MonoCall A.zero (MonoVarGlobal A.zero 0 (Mono.mFunction Mono.topLegacy [ valTy ] valTy)) [ local name ] valTy Mono.defaultCallInfo


{-| `Basics.compare a b` through the `Utils.compare` kernel, a pure call with a
`KernelFacts` row, for the non-hash cases.
-}
compareAB : MonoExpr
compareAB =
    MonoCall A.zero
        (MonoVarKernel A.zero "Elm" "Utils" "compare" (Mono.mFunction Mono.topLegacy [ valTy, valTy ] valTy))
        [ local "a", local "b" ]
        valTy
        Mono.defaultCallInfo


alias : String -> String -> MonoExpr -> MonoExpr
alias n m body =
    MonoLet (Mono.MonoDef n (local m)) body bodyTy


letIn : String -> MonoExpr -> MonoExpr -> MonoExpr
letIn n bound body =
    MonoLet (Mono.MonoDef n bound) body bodyTy


tailDef : String -> String -> MonoExpr -> MonoExpr
tailDef name param bound =
    MonoLet (Mono.MonoTailDef name [ ( param, valTy ) ] bound) (local "k") bodyTy


list : List MonoExpr -> MonoExpr
list items =
    MonoList A.zero items bodyTy


ifThen : MonoExpr -> MonoExpr -> MonoExpr
ifThen yes no =
    MonoIf [ ( MonoVarLocal "c" Mono.MBool, yes ) ] no bodyTy


closure : String -> MonoExpr -> MonoExpr
closure param body =
    MonoClosure
        { lambdaId = Mono.AnonymousLambda home 0
        , srcLambda = Nothing
        , lssMember = Nothing
        , captures = []
        , params = [ ( param, valTy ) ]
        , closureKind = Nothing
        , captureAbi = Nothing
        }
        body
        (Mono.mFunction Mono.topLegacy [ valTy ] bodyTy)


{-| A one-spec graph whose spec 0 is a nullary `MonoDefine` of `body`.
-}
graphOf : MonoExpr -> Mono.MonoGraph
graphOf body =
    Mono.MonoGraph
        { nodes = Array.fromList [ Just (Mono.MonoDefine body bodyTy) ]
        , main = Mono.StaticMain 0
        , registry =
            { nextId = 1
            , mapping = Mono.specKeyMapEmpty
            , reverseMapping = Array.fromList [ Just ( Mono.Global home "f", bodyTy ) ]
            , countByGlobal = Dict.empty
            }
        , ctorShapes = Mono.layoutMapEmpty
        , nextLambdaIndex = 1
        , callEdges = Array.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , ports = []
        , flagsDecoder = Nothing
        , flagsSchema = ""
        , lssMemberOrigins = Dict.empty
        , lssMemberKinds = Dict.empty
        , lssBlockedMembers = Dict.empty
        , repr = Mono.emptyReprInfo
        }



-- INSPECTION


{-| The argument names of the hash calls in `e`, in tree order (bound
expression before body, elements left to right).
-}
hashArgs : MonoExpr -> List String
hashArgs e =
    case e of
        MonoCall _ (MonoVarKernel _ "Eco" "FNV" "hash" _) [ MonoVarLocal v _ ] _ _ ->
            [ v ]

        _ ->
            List.concatMap hashArgs (children e)


{-| The number of hash calls in `e`, whatever their argument.
-}
hashCalls : MonoExpr -> Int
hashCalls e =
    case e of
        MonoCall _ (MonoVarKernel _ "Eco" "FNV" "hash" _) args _ _ ->
            1 + List.sum (List.map hashCalls args)

        _ ->
            List.sum (List.map hashCalls (children e))


compareCalls : MonoExpr -> Int
compareCalls e =
    case e of
        MonoCall _ (MonoVarKernel _ "Elm" "Utils" "compare" _) _ _ _ ->
            1

        _ ->
            List.sum (List.map compareCalls (children e))


children : MonoExpr -> List MonoExpr
children e =
    case e of
        MonoList _ items _ ->
            items

        MonoCall _ f args _ _ ->
            f :: args

        MonoLet (Mono.MonoDef _ bound) body _ ->
            [ bound, body ]

        MonoLet (Mono.MonoTailDef _ _ bound) body _ ->
            [ bound, body ]

        MonoIf branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        MonoClosure _ body _ ->
            [ body ]

        _ ->
            []
