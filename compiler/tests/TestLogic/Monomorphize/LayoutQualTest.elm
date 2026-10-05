module TestLogic.Monomorphize.LayoutQualTest exposing (suite)

{-| Checks how the solver engine names the lambdas it meets while translating
a specialization, because a wrong name either multiplies specializations or
merges values that must stay apart, and neither is a compile error.

Under lambda-set specialization every function arrow in a `MonoType` carries
an annotation saying which function values can flow through it. Each such
value is a _member_, named by an interned integer id. A _specialization_
(spec) is one instantiation of a definition at a `MonoType`, numbered by a
`SpecId`. When a spec's body is translated, each lambda in it, other than the
definition's own root lambda, is keyed by a _layout-qualified key_, which
`Engine.layoutQualKey` builds as `l|<raw lambda id>|<widened key>`. The
_widened key_ is the `toComparableMonoType` string of the spec's type with
every arrow annotation replaced by top (`LTop`), the widened annotation that
does not restrict which function values flow, as `Mono.widenSets` does,
recorded when the spec is created. Two specs whose types differ only in
annotations therefore have equal widened keys, and the same lambda minted in
either is keyed alike, while specs whose types differ in layout key it
differently. The exception is a spec whose demand already carries a different
id for that lambda: that id is reused and recorded as tied, which blocks it.
A spec with no recorded widened key has its `SpecId` in that position
instead, which the solver counts as a _fallback_. A non-zero _instance tag_,
which distinguishes the instances of a let-bound function translated more
than once, adds `|#<tag>` to the end of the key.

Two pipeline fixtures run the solver engine with its lambda-set report on,
through `TestLogic.TestPipeline.runSolverMonoWithReport`, and read three
counters from the report's `layoutQual` line: `shared`, mints whose id was
first minted under a different spec; `fallback`, mints keyed by a `SpecId`;
and `tieBypass`, mints where the id carried in by the spec's demand equals
the id the mint interns, so that nothing is recorded as tied. The tests
read `shared` only as at least one; since folded root-lambda mints also bump
it, they also read the closure member ids in each spec's body directly.

The _spiral_ fixture is `loop n f`, which calls itself, outside tail
position, with a new lambda wrapping `f`, and `testValue`, which calls
`loop 3` with an identity lambda. Each recursive call demands `loop` at a
type whose callback annotation names the lambda minted by the caller's spec.
Because those specs differ only in annotations, they mint that lambda under
one key; had they minted different ids, the solver would close the spiral by
recording the member as tied, which blocks it.
`TestLogic.Monomorphize.MuTieTest` builds the same `loop`.

The _split_ fixture is `mid f x = applyHof (\v -> f (v + x)) x` with
`applyHof g y = g y`, and `testValue` calls `mid inc 1` and `mid dec 2`.
The two calls give `mid` types that differ only in the annotation on `f`,
so `mid` has two specs, and each mints its own copy of the inner lambda and
passes it to `applyHof`.

The tests establish:

  - Widening gives equal keys for two arrows whose callback slots carry
    different member sets, and for a callback slot carrying top and one
    carrying a set variable, but different keys when the callback's argument
    type differs (`Int` against `Float`).
  - No widened key, for a type of each `MonoType` constructor and each arrow
    annotation, starts with a digit, so none can equal a `SpecId` written in
    the same position.
  - `layoutQualKey` gives `l|42|A(I->I)` and `False` when spec 7's widened
    key is recorded (instance tag 0, which adds nothing), and `l|42|8` and
    `True` for spec 8, which has none.
  - With instance tag 513 the key ends in `|#513`, and tags 0, 1, 2 and 513
    give four different keys.
  - `Engine.mixTag 0 1` differs from `mixTag (mixTag 0 1) 1`: ordinal 1
    under the tags the engine gives enclosing instances 0 and 1 (ordinal 0
    keeps the enclosing tag, 0 at top level) gives two tags. `mixTag 0 0`
    is not 0, the tag that means no instance.
  - Interning one key twice with `Engine.internMemberKey` gives the same id
    and leaves the next free id unchanged.
  - The spiral fixture finishes with no blocked members, at most three specs
    of `loop`, `tieBypass` and `shared` at least one, `fallback` zero, and
    every `loop` spec carrying the same two closure member ids (its root
    lambda and the inner lambda).
  - The split fixture gives two specs of `mid` and one of `applyHof`, with
    `shared` at least one, `fallback` zero, and both `mid` specs carrying
    the same two closure member ids.
  - The split fixture with a budget of one spec per global
    (`maxSpecsPerGlobal = 1`), past which a global's new specs are keyed by
    their widened type, gives `shared` at least one, `fallback` zero, both
    `mid` specs carrying the same two closure member ids, and two specs of
    `applyHof`.

Among what is not tested: a tie to a different id, which records the member
as blocked; the folding of a definition's own root lambda into its global's
`g|` key; instance tags produced by translating a real let-bound function;
the values of the ids the fixtures' lambdas get; and the generated code.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Data.Id as Id
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.MonoSolver.Engine as Engine
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The tests of layout-qualified member keys: the pure key functions, the
spiral fixture and the split fixture.
-}
suite : Test
suite =
    Test.describe "LSS_024 layout-qualified members"
        [ Test.describe "pure key machinery" purePins
        , Test.describe "qualification spiral under C" spiralPins
        , Test.describe "annotation-split collapse" splitPins
        ]



-- ====== 1. PURE PINS ======


{-| Builds the type `(Int -> Int) -> Int` with `anno` on the callback's
arrow and top on the outer arrow.
-}
arrowWith : Mono.LambdaSetAnno -> Mono.MonoType
arrowWith anno =
    Mono.mFunction Mono.topLegacy [ Mono.mFunction anno [ Mono.MInt ] Mono.MInt ] Mono.MInt


{-| Returns the widened key of `t`: its comparable string after every arrow
annotation has been replaced by top.
-}
widenedKey : Mono.MonoType -> String
widenedKey t =
    Mono.toComparableMonoType (Mono.widenSets t)


{-| One type of every `MonoType` constructor, both `MVar` constraints and every
arrow annotation, the shapes whose widened keys the leading-character test
reads.
-}
everyTypeShape : List Mono.MonoType
everyTypeShape =
    [ Mono.MInt
    , Mono.MFloat
    , Mono.MBool
    , Mono.MChar
    , Mono.MString
    , Mono.MUnit
    , Mono.MVar Id.first Mono.CEcoValue
    , Mono.MVar Id.first Mono.CNumber
    , Mono.mList Mono.MInt
    , Mono.mTuple [ Mono.MInt, Mono.MString ]
    , Mono.mRecord (Dict.fromList [ ( "a", Mono.MInt ) ])
    , Mono.mCustom ModuleName.maybe "Maybe" [ Mono.MInt ]
    , arrowWith Mono.topLegacy
    , arrowWith (Mono.LVar 0)
    , arrowWith (Mono.LSet [ 101 ])
    , arrowWith (Mono.LPartial [ 101 ])
    ]


{-| The tests of widened keys, `Engine.layoutQualKey`, `Engine.mixTag` and
`Engine.internMemberKey`, which run no pipeline.
-}
purePins : List Test
purePins =
    [ Test.test "annotation-only differences erase: equal widened keys" <|
        \() ->
            Expect.equal
                (widenedKey (arrowWith (Mono.LSet [ 101 ])))
                (widenedKey (arrowWith (Mono.LSet [ 202, 303 ])))
    , Test.test "Phase 1a/3: a set VARIABLE widens to the SAME key as LTop (1a-T7 direct pin)" <|
        \() ->
            Expect.equal
                (widenedKey (arrowWith Mono.topLegacy))
                (widenedKey (arrowWith (Mono.LVar 0)))
    , Test.test "layout differences survive widening: distinct keys" <|
        \() ->
            Expect.notEqual
                (widenedKey (arrowWith (Mono.LSet [ 101 ])))
                (widenedKey (Mono.mFunction Mono.topLegacy [ Mono.mFunction Mono.topLegacy [ Mono.MFloat ] Mono.MInt ] Mono.MInt))
    , Test.test "layoutQualKey: captured key qualifies by the widened key" <|
        \() ->
            Expect.equal ( "l|42|A(I->I)", False )
                (Engine.layoutQualKey (Dict.fromList [ ( 7, "A(I->I)" ) ]) 42 0 7)
    , Test.test "layoutQualKey: missing capture falls back to SpecId qualification" <|
        \() ->
            Expect.equal ( "l|42|8", True )
                (Engine.layoutQualKey (Dict.fromList [ ( 7, "A(I->I)" ) ]) 42 0 8)
    , Test.test "layoutQualKey: a non-zero instance tag appends an unambiguous #-marked component" <|
        \() ->
            Expect.equal ( "l|42|A(I->I)|#513", False )
                (Engine.layoutQualKey (Dict.fromList [ ( 7, "A(I->I)" ) ]) 42 513 7)
    , Test.test "layoutQualKey: distinct instance tags never collide with each other or with the untagged key" <|
        \() ->
            let
                keys =
                    List.map (\t -> Tuple.first (Engine.layoutQualKey (Dict.fromList [ ( 7, "A(I->I)" ) ]) 42 t 7)) [ 0, 1, 2, 513 ]
            in
            Expect.equal 4
                (List.length
                    (List.foldl
                        (\k acc ->
                            if List.member k acc then
                                acc

                            else
                                k :: acc
                        )
                        []
                        keys
                    )
                )
    , Test.test "mixTag: composition, not overwrite — the same ordinal under different outer tags differs" <|
        \() ->
            -- Ordinal 0 keeps the enclosing tag, so the engine's outer tags
            -- for instances 0 and 1 are 0 and `mixTag 0 1`.
            Expect.notEqual (Engine.mixTag 0 1) (Engine.mixTag (Engine.mixTag 0 1) 1)
    , Test.test "mixTag: a leading ordinal 0 is not absorbed into the no-instance sentinel" <|
        \() ->
            Expect.notEqual 0 (Engine.mixTag 0 0)
    , Test.test "fallback-vs-widened collisions impossible: widened keys never start with a digit" <|
        \() ->
            let
                badKeys =
                    List.filter
                        (\k ->
                            case String.uncons k of
                                Just ( c, _ ) ->
                                    Char.isDigit c

                                Nothing ->
                                    True
                        )
                        (List.map widenedKey everyTypeShape)
            in
            Expect.equal [] badKeys
    , Test.test "internMemberKey: re-mint of one key is idempotent (same id, no growth)" <|
        \() ->
            let
                ( id1, t1, n1 ) =
                    Engine.internMemberKey "l|42|A(I->I)" Engine.emptyMemberTable 5000

                ( id2, _, n2 ) =
                    Engine.internMemberKey "l|42|A(I->I)" t1 n1
            in
            Expect.equal ( id1, n1 ) ( id2, n2 )
    ]


{-| Returns, for each spec of the global named `name` that has a node, the
member ids carried by the closures in its body, nested closures included, in
no particular order. A closure with no member id is left out.
-}
closureMembersPerSpec : String -> { r | registry : Mono.SpecializationRegistry, nodes : Array.Array (Maybe Mono.MonoNode) } -> List (List Int)
closureMembersPerSpec name g =
    List.filterMap
        (\( specId, entry ) ->
            case ( entry, Array.get specId g.nodes ) of
                ( Just ( Mono.Global _ n, _ ), Just (Just (Mono.MonoDefine body _)) ) ->
                    if n == name then
                        Just (closureMembersIn body)

                    else
                        Nothing

                ( Just ( Mono.Global _ n, _ ), Just (Just (Mono.MonoTailFunc _ body _)) ) ->
                    if n == name then
                        Just (closureMembersIn body)

                    else
                        Nothing

                _ ->
                    Nothing
        )
        (Array.toIndexedList g.registry.reverseMapping)


{-| Returns the member id of every closure in `expr` that carries one.
-}
closureMembersIn : Mono.MonoExpr -> List Int
closureMembersIn expr =
    MonoTraverse.foldExpr
        (\e acc ->
            case e of
                Mono.MonoClosure info _ _ ->
                    case info.lssMember of
                        Just m ->
                            m :: acc

                        Nothing ->
                            acc

                _ ->
                    acc
        )
        []
        expr


{-| Passes when there are `count` lists in `perSpec`, each holding two
distinct member ids, and all of them are equal as sets. Each spec of the
fixtures here holds two closures with member ids, the definition's own root
lambda and the inner lambda, so this says that every spec minted both under
the same ids.
-}
expectSameMembers : Int -> List (List Int) -> Expect.Expectation
expectSameMembers count perSpec =
    let
        sorted =
            List.map List.sort perSpec
    in
    case sorted of
        [ a, b ] :: rest ->
            if a /= b && List.length sorted == count && List.all (\ms -> ms == [ a, b ]) rest then
                Expect.pass

            else
                Expect.fail ("expected " ++ String.fromInt count ++ " specs carrying the same two closure members, got " ++ Debug.toString perSpec)

        _ ->
            Expect.fail ("expected " ++ String.fromInt count ++ " specs carrying two closure members each, got " ++ Debug.toString perSpec)



-- ====== 2. SPIRAL PINS (MuTieTest fixture) ======


{-| What the spiral test reads from one run of the spiral fixture: how many
members the solver recorded as blocked, how many specs `loop` has, and the
text of the lambda-set report, empty when the solver returned none.
-}
type alias Facts =
    { blockedCount : Int
    , loopSpecs : Int
    , loopInner : List (List Int)
    , report : String
    }


{-| The facts of the spiral fixture monomorphized by the solver engine with
the default lambda-set settings and the report on, or the pipeline's error.
The default limits apply, and the default allows any number of specs per
global.
-}
runSpiral : Result String Facts
runSpiral =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithReport
        Config.defaultLimits
        { defaults | enabled = True }
        spiralModule
        |> Result.map
            (\( graph, maybeReport ) ->
                let
                    base =
                        factsOf graph
                in
                { base | report = Maybe.withDefault "" maybeReport }
            )


{-| Reads the blocked-member count, the number of `loop` specs and the
closure member ids of each `loop` spec from a monomorphized graph, leaving
`report` empty.
-}
factsOf : Mono.MonoGraph -> Facts
factsOf (Mono.MonoGraph g) =
    { blockedCount = Dict.size g.lssBlockedMembers
    , loopSpecs = specCount "loop" g
    , loopInner = closureMembersPerSpec "loop" g
    , report = ""
    }


{-| Counts the specs in the registry whose global is named `name`, in any
module.
-}
specCount : String -> { r | registry : Mono.SpecializationRegistry } -> Int
specCount name g =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ n, _ ) ->
                    if n == name then
                        acc + 1

                    else
                        acc

                _ ->
                    acc
        )
        0
        g.registry.reverseMapping


{-| Returns the number written straight after the first occurrence of
`label` in `report`, where `label` includes the `=`, as in `"tieBypass="`.
Gives -1 when `label` does not occur or is not followed by a digit.
-}
counterOf : String -> String -> Int
counterOf label report =
    case String.split label report |> List.drop 1 |> List.head of
        Just rest ->
            Maybe.withDefault -1 (String.toInt (leadingDigits rest))

        Nothing ->
            -1


{-| Returns the run of decimal digits at the start of `s`, empty if `s` does
not start with one.
-}
leadingDigits : String -> String
leadingDigits s =
    case String.uncons s of
        Just ( c, rest ) ->
            if Char.isDigit c then
                String.cons c (leadingDigits rest)

            else
                ""

        Nothing ->
            ""


{-| The test of the spiral fixture.
-}
spiralPins : List Test
spiralPins =
    [ Test.test "equal-id bypass — the spiral closes, nothing recorded, tieBypass counts" <|
        \() ->
            case runSpiral of
                Err msg ->
                    Expect.fail msg

                Ok f ->
                    Expect.all
                        [ \x -> Expect.equal 0 x.blockedCount
                        , \x ->
                            if x.loopSpecs <= 3 then
                                Expect.pass

                            else
                                Expect.fail ("spiral did not close: loopSpecs=" ++ String.fromInt x.loopSpecs)
                        , \x ->
                            if counterOf "tieBypass=" x.report >= 1 then
                                Expect.pass

                            else
                                Expect.fail ("expected tieBypass >= 1 in: " ++ x.report)
                        , \x ->
                            if counterOf "shared=" x.report >= 1 then
                                Expect.pass

                            else
                                Expect.fail ("expected shared >= 1 in: " ++ x.report)
                        , \x -> Expect.equal 0 (counterOf "fallback=" x.report)

                        -- What `shared` shows only in part: every spec of
                        -- `loop` minted its inner lambda under one id.
                        , \x -> expectSameMembers x.loopSpecs x.loopInner
                        ]
                        f
    ]



-- ====== 3. SPLIT-COLLAPSE PINS ======


{-| What the split tests read from one run of the split fixture: the spec
counts of `mid` and `applyHof`, the closure member ids of each `mid` spec,
and the report text, empty when the solver returned none.
-}
type alias SplitFacts =
    { midSpecs : Int
    , hofSpecs : Int
    , midInner : List (List Int)
    , report : String
    }


{-| The spec counts of `mid` and `applyHof` and the report text for the
split fixture under the default spec budget, which is unlimited, or the
pipeline's error.
-}
runSplit : Result String SplitFacts
runSplit =
    runSplitWithBudget Config.defaultLss.maxSpecsPerGlobal


{-| Monomorphizes the split fixture with the solver engine and the report on,
allowing `budget` specs per global, and returns the spec counts of `mid` and
`applyHof` with the report text, or the pipeline's error.

A `budget` of 0 or less is unlimited. Past the budget, a new spec of a global
is keyed by its widened type, but it records the same widened key as a spec
created under the budget, so with a budget of 1 the two specs of `mid` still
mint the inner lambda under one key.

-}
runSplitWithBudget : Int -> Result String SplitFacts
runSplitWithBudget budget =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithReport
        Config.defaultLimits
        { defaults | enabled = True, maxSpecsPerGlobal = budget }
        splitModule
        |> Result.map
            (\( Mono.MonoGraph g, maybeReport ) ->
                { midSpecs = specCount "mid" g
                , hofSpecs = specCount "applyHof" g
                , midInner = closureMembersPerSpec "mid" g
                , report = Maybe.withDefault "" maybeReport
                }
            )


{-| The tests of the split fixture, with an unlimited budget and with a
budget of one spec per global.
-}
splitPins : List Test
splitPins =
    [ Test.test "mid's root split persists, the PROPAGATED applyHof split collapses to 1" <|
        \() ->
            case runSplit of
                Err msg ->
                    Expect.fail msg

                Ok f ->
                    Expect.all
                        [ \x -> Expect.equal 2 x.midSpecs
                        , \x -> Expect.equal 1 x.hofSpecs
                        , \x ->
                            if counterOf "shared=" x.report >= 1 then
                                Expect.pass

                            else
                                Expect.fail ("expected shared >= 1 in: " ++ x.report)
                        , \x -> Expect.equal 0 (counterOf "fallback=" x.report)

                        -- `shared` is also bumped by root-lambda folds, so
                        -- read the inner lambda's ids directly.
                        , \x -> expectSameMembers 2 x.midInner
                        ]
                        f
    , Test.test "budget twins share: annotation-created + budget-widened specs of one global mint ONE id" <|
        \() ->
            case runSplitWithBudget 1 of
                Err msg ->
                    Expect.fail msg

                Ok f ->
                    Expect.all
                        [ \x ->
                            if counterOf "shared=" x.report >= 1 then
                                Expect.pass

                            else
                                Expect.fail ("expected shared >= 1 in: " ++ x.report)
                        , \x -> Expect.equal 0 (counterOf "fallback=" x.report)
                        , \x -> expectSameMembers 2 x.midInner

                        -- Two, not one: past its budget of one spec,
                        -- `applyHof`'s next demand is keyed by its widened
                        -- type, which gives a second spec.
                        , \x -> Expect.equal 2 x.hofSpecs
                        ]
                        f
    ]



-- ====== FIXTURES ======


{-| The spiral fixture: `loopDef` and `testValue`, in a module named `Test`.
-}
spiralModule : Src.Module
spiralModule =
    makeModuleWithTypedDefs "Test" [ loopDef, spiralValueDef ]


{-| The definition of `loop : Int -> (Int -> Int) -> Int`, which returns `f 0`
once `n` is at most 0 and otherwise `1 + loop (n - 1) (\x -> f x + 1)`. The
`1 +` keeps the recursive call out of tail position.
-}
loopDef : TypedDef
loopDef =
    { name = "loop"
    , args = [ pVar "n", pVar "f" ]
    , tipe =
        tLambda (tType "Int" [])
            (tLambda (tLambda (tType "Int" []) (tType "Int" []))
                (tType "Int" [])
            )
    , body =
        ifExpr
            (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
            (callExpr (varExpr "f") [ intExpr 0 ])
            (binopsExpr [ ( intExpr 1, "+" ) ]
                (callExpr (varExpr "loop")
                    [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                    , lambdaExpr [ pVar "x" ]
                        (binopsExpr
                            [ ( callExpr (varExpr "f") [ varExpr "x" ], "+" ) ]
                            (intExpr 1)
                        )
                    ]
                )
            )
    }


{-| The spiral fixture's `testValue`, which is `loop 3 (\x -> x)`.
-}
spiralValueDef : TypedDef
spiralValueDef =
    { name = "testValue"
    , args = []
    , tipe = tType "Int" []
    , body =
        callExpr (varExpr "loop")
            [ intExpr 3
            , lambdaExpr [ pVar "x" ] (varExpr "x")
            ]
    }


{-| The split fixture: `inc` and `dec` add and subtract one,
`applyHof g y = g y`, `mid f x = applyHof (\v -> f (v + x)) x`, and
`testValue = mid inc 1 + mid dec 2`, all annotated with `Int` types.

The two calls of `mid` give its `f` arrow different member sets at the same
layout, so `mid` has two specs, and each mints its own copy of the inner
lambda. The two specs have equal widened keys, so the two copies are keyed
alike, although they capture different functions `f`. Whether a call through
the id minted under that key may be dispatched directly is left to
`Compiler.GlobalOpt.AbiCloning`, and is not tested here.

-}
splitModule : Src.Module
splitModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "inc"
          , args = [ pVar "x" ]
          , tipe = tLambda (tType "Int" []) (tType "Int" [])
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "dec"
          , args = [ pVar "x" ]
          , tipe = tLambda (tType "Int" []) (tType "Int" [])
          , body = binopsExpr [ ( varExpr "x", "-" ) ] (intExpr 1)
          }
        , { name = "applyHof"
          , args = [ pVar "g", pVar "y" ]
          , tipe =
                tLambda (tLambda (tType "Int" []) (tType "Int" []))
                    (tLambda (tType "Int" []) (tType "Int" []))
          , body = callExpr (varExpr "g") [ varExpr "y" ]
          }
        , { name = "mid"
          , args = [ pVar "f", pVar "x" ]
          , tipe =
                tLambda (tLambda (tType "Int" []) (tType "Int" []))
                    (tLambda (tType "Int" []) (tType "Int" []))
          , body =
                callExpr (varExpr "applyHof")
                    [ lambdaExpr [ pVar "v" ]
                        (callExpr (varExpr "f")
                            [ binopsExpr [ ( varExpr "v", "+" ) ] (varExpr "x") ]
                        )
                    , varExpr "x"
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                binopsExpr
                    [ ( callExpr (varExpr "mid") [ varExpr "inc", intExpr 1 ], "+" ) ]
                    (callExpr (varExpr "mid") [ varExpr "dec", intExpr 2 ])
          }
        ]
