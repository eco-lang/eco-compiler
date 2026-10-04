module TestLogic.Monomorphize.LssLocalMultiEnrichTest exposing (suite)

{-| Checks that, once the solver engine has monomorphized a program with
lambda-set specialization on, each use of a let-bound name carries the
lambda-set annotations of the definition it refers to. A use left with ⊤ where
its definition has a set is still sound, only less precise, so the compiled
program would not show the loss.

A lambda-set annotation, defined in `Compiler.AST.Monomorphized`, says which
function values can flow through an arrow of a function type; an `LSet` lists
the ones that can flow, and ⊤ means the analysis could not bound the set. The
solver translates the body of a `let` that binds a function before the function
itself, so each use is emitted with a type whose annotations can be weaker than
those of the instance it is bound to. Only afterwards is the right-hand side
translated, once for each type the function is used at, giving one definition
per instance (`f`, `f$1`, ...), or once at its declared type if it is unused; a
tail-recursive function gets a single definition. Copying each instance's
annotations onto its uses is _use enrichment_, and `flushLocalMultiEnrich` in
`Compiler.MonoSolver.Translate` does it. What matters here is that a
let-function in the body of another hands its enrichment to the enclosing one,
so that the outermost does it for all of them in a single walk of its body. The
fixtures are nesting shapes that this walk has to get right.

The property checked is this: for a use `MonoVarLocal n t` in the body of a
`let` whose definition is `MonoDef n rhs`,
`Mono.overlayAnnotations t (Mono.typeOf rhs)` equals `t`, that is, copying the
definition's annotations onto the use's type changes nothing. Every `MonoDef` is
bound, plain values as well as functions, and only for the body of its `let`,
not for its own right-hand side. A `MonoTailDef` binds nothing in the check, so
uses of its name are not checked. Every node of the output graph is walked, not
only `testValue`.

Each fixture is a module `Test` whose `testValue` is the expression shown in the
fixture's docstring. Every test goes through `pin`, and passes when the pipeline
succeeds, no checked use disagrees with its definition, and at least one checked
use refers to a definition whose type has an `LSet` on its outermost arrow, so
that a case cannot pass only because every annotation is ⊤.

  - Test 1, `nestedChain`: three let-functions, each in the body of the one
    before and calling it, with the innermost used at two types and the
    outermost also used directly.
  - Test 2, `rhsNested`: a let-function defined inside another's right-hand
    side rather than its body, with the outer one used at two types.
  - Test 3, `siblings`: two `case` branches that each bind `f`, one to a
    function used at two types and the other to a number, so that each
    branch's uses are compared with its own `f`.
  - Test 4, `aliasUse`: a `let` whose right-hand side is a bare use of an
    enclosing let-function, with both names used.
  - Test 5, `tailNested`: a local function that calls itself in tail position,
    with a let-function used at two types in its body.
  - Test 6, `inLambda`: a let-function used at two types inside a lambda passed
    to `List.map`.
  - Test 7, `deepChain`: a chain of five let-functions, with `e`, `c` and `a`
    used in the innermost body.

Among what is not tested: the substitution engine, or the solver with
lambda-set specialization off; whether the sets are the right ones, rather than
the same on the use as on the definition; uses of a name inside its own
right-hand side; names bound by a `MonoTailDef` or by destructuring.

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


{-| The seven enrichment tests, one per fixture.
-}
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


{-| Builds the test named `label` that monomorphizes `fixture` and checks the
graph with `check`.

It fails with the pipeline's message if any stage of the pipeline fails, with
every disagreeing use if there are any, and as vacuous if no checked use refers
to a definition with an `LSet` on its outermost arrow. The vacuous message lists
each `MonoDef` the walk met, with its right-hand side's type, in the order met.

-}
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


{-| Monomorphizes `srcModule` with the solver engine, under the default
specialization limits and the default lambda-set configuration with `enabled`
set, and returns the graph before global optimization. `enabled` is already on
in the default.
-}
run : Src.Module -> Result String Mono.MonoGraph
run srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits { defaults | enabled = True } srcModule



-- ====== THE PROPERTY ======


{-| What `check` has gathered so far from a graph.

`violations` holds one message per use whose type copying the definition's
annotations would change, newest first. `enriched` counts the uses that agree
with their definition and whose definition has an `LSet` on its outermost arrow.
`defs` names each `MonoDef` met, with its right-hand side's type, newest first.

-}
type alias Found =
    { violations : List String, enriched : Int, defs : List String }


{-| Returns what `checkExpr` finds in every expression of every node of the
graph, each walked with no names bound. Only define, tail-function and port
nodes hold expressions.
-}
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


{-| Adds to `acc` what is found in `expr`, given `env`, which maps each name
bound by an enclosing `MonoDef` to the type of its right-hand side.

A use of a name in `env` is recorded as a violation if overlaying the
definition's annotations changes its type, and otherwise counted in `enriched`
when the definition's outermost arrow has an `LSet`. A use of any other name is
ignored. A `MonoDef` is checked under `env` and binds its name for the `let`
body only. A `let` of a `MonoTailDef`, like every other expression, has its
children walked under the same `env`, so its name is never bound. Nothing is
removed from `env` either, so a lambda parameter or destructured name is not
told apart from an enclosing `MonoDef` of the same name.

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


{-| Returns whether `t` is a function type whose outermost arrow is annotated
with an `LSet`, of any size, the empty set included.
-}
headIsSet : Mono.MonoType -> Bool
headIsSet t =
    case t of
        Mono.MFunction _ (Mono.LSet _) _ _ ->
            True

        _ ->
            False


{-| Returns 1 for `True` and 0 for `False`.
-}
boolToInt : Bool -> Int
boolToInt b =
    if b then
        1

    else
        0


{-| Returns the expression a node holds: the body of a define or a tail
function, or a port's expression. Constructor, enum, extern and effect-manager
leaf nodes hold none.
-}
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


{-| Builds a let definition of a function `name` with one parameter, the
variable `param`.
-}
fn : String -> String -> Src.Expr -> Src.Def
fn name param body =
    define name [ pVar param ] body


{-| Builds a call of the unqualified name `f` with the single argument `arg`.
-}
call1 : String -> Src.Expr -> Src.Expr
call1 f arg =
    callExpr (varExpr f) [ arg ]


{-| A module whose `testValue` is a chain of three let-functions, the
innermost used at an integer literal and at `Bool` and the outermost at a
list:

    let
        a x =
            x
    in
    let
        b y =
            a y
    in
    let
        c z =
            b z
    in
    ( c 1, ( c True, a [ 2 ] ) )

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


{-| A module whose `testValue` has a let-function, `pick`, inside the right-hand
side of another, `wrap`. `wrap` is used at an integer literal and at `Bool`, and
`pick` at `wrap`'s argument and at `Bool`:

    let
        wrap v =
            let
                pick p =
                    p
            in
            ( pick v, pick True )
    in
    ( wrap 1, wrap False )

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


{-| A module whose `testValue` binds `f` in two `case` branches, to a function
used at an integer literal and at `Bool` in one and to a number in the other:

    case True of
        True ->
            let
                f x =
                    x
            in
            f 1
                + (if f True then
                    1

                   else
                    0
                  )

        False ->
            let
                f =
                    2
            in
            f + f

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


{-| A module whose `testValue` has a let, `same`, whose right-hand side is a
bare use of the enclosing let-function `base`:

    let
        base x =
            x
    in
    let
        same =
            base
    in
    ( same 1, ( same True, base [ 2 ] ) )

`base` is also used directly, at a list, so the case has a checked use of
`base` itself and not only of `same`.

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


{-| A module whose `testValue` has a local function `go` that calls itself
in tail position, with a let-function `step` used at `go`'s number argument
and at `Bool` in its body:

    let
        go acc i =
            if i <= 0 then
                acc

            else
                let
                    step k =
                        k
                in
                go (acc + step i)
                    (if step True then
                        i - 1

                     else
                        0
                    )
    in
    go 0 3

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


{-| A module whose `testValue` uses a let-function at an integer and at
`Bool` inside a lambda passed to `List.map`:

    let
        show v =
            v
    in
    List.map (\x -> ( show x, show True )) [ 1, 2 ]

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


{-| A module whose `testValue` is a chain of five let-functions, each calling
the one before, with `e` used at an integer literal and at `Bool`, `c` at
`Bool` and `a` at an integer literal:

    let
        a x =
            x
    in
    let
        b x =
            a x
    in
    let
        c x =
            b x
    in
    let
        d x =
            c x
    in
    let
        e x =
            d x
    in
    ( e 1, ( e True, ( c False, a 3 ) ) )

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
