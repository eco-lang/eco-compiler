module TestLogic.Monomorphize.LssLocalMultiEnrichTest exposing (suite)

{-| E4a local-multi USE enrichment — `Translate.flushLocalMultiEnrich`.

Since 2026-09-04 the overlay of a let-function's instance annotations onto
its use sites is DEFERRED to the outermost let-function of the item and done
in one lexically scoped walk (the per-let `traverseExpr` walks were 68 % of
the self-compile's dispatch). The pin is the observable property the old
scheme established and the new one must reproduce: under the solver with LSS
on, every use of a `MonoDef`-bound local function carries its binding's
annotations — `t == overlayAnnotations t (typeOf rhs)` — in each shape the
deferral had to get right:

  - a chain of nested let-functions (inner lets defer to the outer walk);
  - a let-function inside another's RHS (walked at its own completion, the
    outer stack entry having been popped);
  - sibling scopes reusing one name for a function and a plain value;
  - an alias whose RHS is a bare use of the enclosing function;
  - a tail-recursive local (pushes the same stack) with a nested let-function;
  - a lambda capturing a let-function;
  - a five-deep chain used at two types on several levels.

Each test also asserts the fixture is non-vacuous: at least one checked use
binds to an instance whose head annotation is a real set.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , boolExpr
        , callExpr
        , caseExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , listExpr
        , makeModule
        , pCtor
        , pVar
        , qualVarExpr
        , tupleExpr
        , varExpr
        )
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "E4a local-multi use enrichment survives the deferred single walk"
        [ pin "1. nested chain of let-functions" nestedChain
        , pin "2. let-function inside another's RHS" rhsNested
        , pin "3. sibling scopes reusing a name (function vs plain value)" siblings
        , pin "4. alias whose RHS is a bare use" aliasUse
        , pin "5. tail-recursive local with a nested let-function" tailNested
        , pin "6. lambda capturing a let-function" inLambda
        , pin "7. five-deep chain used on several levels" deepChain
        ]


pin : String -> Src.Module -> Test
pin label fixture =
    Test.test label <|
        \() ->
            case run fixture of
                Err e ->
                    Expect.fail e

                Ok graph ->
                    let
                        found =
                            check graph
                    in
                    if not (List.isEmpty found.violations) then
                        Expect.fail (String.join "\n" found.violations)

                    else if found.enriched == 0 then
                        Expect.fail ("vacuous: no use bound to an instance with a set-annotated head; defs seen: " ++ String.join "; " (List.reverse found.defs))

                    else
                        Expect.pass


run : Src.Module -> Result String Mono.MonoGraph
run srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits { defaults | enabled = True } srcModule



-- ====== THE PROPERTY ======


type alias Found =
    { violations : List String, enriched : Int, defs : List String }


check : Mono.MonoGraph -> Found
check (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Nothing ->
                    acc

                Just node ->
                    List.foldl (checkExpr Dict.empty) acc (nodeExprs node)
        )
        { violations = [], enriched = 0, defs = [] }
        data.nodes


{-| Lexically scoped: a `MonoDef` binds its name for its BODY only (the old
walk never covered a group's own RHSs); tail defs are never enriched.
-}
checkExpr : Dict.Dict String Mono.MonoType -> Mono.MonoExpr -> Found -> Found
checkExpr env expr acc =
    case expr of
        Mono.MonoVarLocal n t ->
            case Dict.get n env of
                Just src ->
                    if Mono.overlayAnnotations t src == t then
                        { acc | enriched = acc.enriched + boolToInt (headIsSet src) }

                    else
                        { acc
                            | violations =
                                ("use of `" ++ n ++ "` is not enriched: " ++ Mono.monoTypeToDebugString t ++ "  vs def  " ++ Mono.monoTypeToDebugString src)
                                    :: acc.violations
                        }

                Nothing ->
                    acc

        Mono.MonoLet (Mono.MonoDef n rhs) body _ ->
            let
                seen =
                    { acc | defs = (n ++ " : " ++ Mono.monoTypeToDebugString (Mono.typeOf rhs)) :: acc.defs }
            in
            checkExpr (Dict.insert n (Mono.typeOf rhs) env) body (checkExpr env rhs seen)

        _ ->
            List.foldl (checkExpr env) acc (MonoTraverse.childrenOf expr)


headIsSet : Mono.MonoType -> Bool
headIsSet t =
    case t of
        Mono.MFunction _ (Mono.LSet _) _ _ ->
            True

        _ ->
            False


boolToInt : Bool -> Int
boolToInt b =
    if b then
        1

    else
        0


nodeExprs : Mono.MonoNode -> List Mono.MonoExpr
nodeExprs node =
    case node of
        Mono.MonoDefine expr _ ->
            [ expr ]

        Mono.MonoTailFunc _ expr _ ->
            [ expr ]

        Mono.MonoPortIncoming expr _ ->
            [ expr ]

        Mono.MonoPortOutgoing expr _ ->
            [ expr ]

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []



-- ====== FIXTURES ======


fn : String -> String -> Src.Expr -> Src.Def
fn name param body =
    define name [ pVar param ] body


call1 : String -> Src.Expr -> Src.Expr
call1 f arg =
    callExpr (varExpr f) [ arg ]


{-| let a x = x in let b y = a y in let c z = b z in (c 1, (c True, a [2]))
-}
nestedChain : Src.Module
nestedChain =
    makeModule "testValue"
        (letExpr [ fn "a" "x" (varExpr "x") ]
            (letExpr [ fn "b" "y" (call1 "a" (varExpr "y")) ]
                (letExpr [ fn "c" "z" (call1 "b" (varExpr "z")) ]
                    (tupleExpr (call1 "c" (intExpr 1))
                        (tupleExpr (call1 "c" (boolExpr True)) (call1 "a" (listExpr [ intExpr 2 ])))
                    )
                )
            )
        )


{-| let wrap v = (let pick p = p in (pick v, pick True)) in (wrap 1, wrap False)
-}
rhsNested : Src.Module
rhsNested =
    makeModule "testValue"
        (letExpr
            [ fn "wrap"
                "v"
                (letExpr [ fn "pick" "p" (varExpr "p") ]
                    (tupleExpr (call1 "pick" (varExpr "v")) (call1 "pick" (boolExpr True)))
                )
            ]
            (tupleExpr (call1 "wrap" (intExpr 1)) (call1 "wrap" (boolExpr False)))
        )


{-| case True of
True -> let f x = x in f 1 + (if f True then 1 else 0)
False -> let f = 2 in f + f
-}
siblings : Src.Module
siblings =
    makeModule "testValue"
        (caseExpr (boolExpr True)
            [ ( pCtor "True" []
              , letExpr [ fn "f" "x" (varExpr "x") ]
                    (binopsExpr [ ( call1 "f" (intExpr 1), "+" ) ]
                        (ifExpr (call1 "f" (boolExpr True)) (intExpr 1) (intExpr 0))
                    )
              )
            , ( pCtor "False" []
              , letExpr [ define "f" [] (intExpr 2) ]
                    (binopsExpr [ ( varExpr "f", "+" ) ] (varExpr "f"))
              )
            ]
        )


{-| let base x = x in let same = base in (same 1, (same True, base [2]))

The alias's own instances are re-translated under a fresh-store demand and
carry ⊤ heads (the recorded RHS type is the un-enriched use of `base` — the
old per-let scheme's order, reproduced by the deferral), so the direct
two-type use of `base` is what makes the pin non-vacuous.

-}
aliasUse : Src.Module
aliasUse =
    makeModule "testValue"
        (letExpr [ fn "base" "x" (varExpr "x") ]
            (letExpr [ define "same" [] (varExpr "base") ]
                (tupleExpr (call1 "same" (intExpr 1))
                    (tupleExpr (call1 "same" (boolExpr True)) (call1 "base" (listExpr [ intExpr 2 ])))
                )
            )
        )


{-| let go acc i = if i <= 0 then acc else (let step k = k in go (acc + step i) (if step True then i - 1 else 0))
in go 0 3
-}
tailNested : Src.Module
tailNested =
    makeModule "testValue"
        (letExpr
            [ define "go"
                [ pVar "acc", pVar "i" ]
                (ifExpr (binopsExpr [ ( varExpr "i", "<=" ) ] (intExpr 0))
                    (varExpr "acc")
                    (letExpr [ fn "step" "k" (varExpr "k") ]
                        (callExpr (varExpr "go")
                            [ binopsExpr [ ( varExpr "acc", "+" ) ] (call1 "step" (varExpr "i"))
                            , ifExpr (call1 "step" (boolExpr True)) (binopsExpr [ ( varExpr "i", "-" ) ] (intExpr 1)) (intExpr 0)
                            ]
                        )
                    )
                )
            ]
            (callExpr (varExpr "go") [ intExpr 0, intExpr 3 ])
        )


{-| let show v = v in List.map (\\x -> (show x, show True)) [1, 2]
-}
inLambda : Src.Module
inLambda =
    makeModule "testValue"
        (letExpr [ fn "show" "v" (varExpr "v") ]
            (callExpr (qualVarExpr "List" "map")
                [ lambdaExpr [ pVar "x" ] (tupleExpr (call1 "show" (varExpr "x")) (call1 "show" (boolExpr True)))
                , listExpr [ intExpr 1, intExpr 2 ]
                ]
            )
        )


{-| let a x = x in let b x = a x in let c x = b x in let d x = c x in let e x = d x
in (e 1, (e True, (c False, a 3)))
-}
deepChain : Src.Module
deepChain =
    makeModule "testValue"
        (letExpr [ fn "a" "x" (varExpr "x") ]
            (letExpr [ fn "b" "x" (call1 "a" (varExpr "x")) ]
                (letExpr [ fn "c" "x" (call1 "b" (varExpr "x")) ]
                    (letExpr [ fn "d" "x" (call1 "c" (varExpr "x")) ]
                        (letExpr [ fn "e" "x" (call1 "d" (varExpr "x")) ]
                            (tupleExpr (call1 "e" (intExpr 1))
                                (tupleExpr (call1 "e" (boolExpr True))
                                    (tupleExpr (call1 "c" (boolExpr False)) (call1 "a" (intExpr 3)))
                                )
                            )
                        )
                    )
                )
            )
        )
