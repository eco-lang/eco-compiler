module TestLogic.GlobalOpt.BinopSchemeTypeLeakTest exposing (suite)

{-| A binary operator's occurrence must carry the type it is used at, not the
operator's generic scheme type.

`Compiler.LocalOpt.Typed.Expression` turns most operator applications
(`Can.Binop`), `*` among them, into a call of the operator's global. That
global reference must be typed from the operands' types and the result type,
not with the operator's annotation as written: for `*`, `number -> number ->
number`, whose `number` is `Basics.mul`'s own scheme variable. Type variables
are identified by NAME within a scope (`Compiler.Monomorphize.AssignMVarIds`
keeps one id per name within a scope, such as a definition's own type
variables), so when the enclosing definition's scheme also has a `number`, the
operator's `number` would be taken for it.

In `wrapInt x = ( x * 1, 4 * 2 * 2 )` with `wrapInt 2.5`, a scheme-typed
reference would give every `*` the type of `x`, so under the substitution
engine (`ECO_MONO_ENGINE=subst`) the `*` of the Int chain `4 * 2 * 2` would be
specialized at `Float -> Float -> Float`. With alias forwarding
(`Compiler.GlobalOpt.PreMono.AliasForward`, default on) the reference would be
forwarded to `Elm.Kernel.Basics.mul` with that type, and code generation would
abort with a kernel signature mismatch for `Elm_Kernel_Basics_mul_Float`.

The fixture is one module, `WrapInt`, holding `wrapInt x = ( x * 1, 4 * 2 * 2 )`
and `testValue = wrapInt 2.5`. The second test also adds a `Basics.mul` node
defined as `Elm.Kernel.Basics.mul`, since the mock interfaces carry no code.

The tests:

  - The typed optimizer's graph: every call of a global must have its
    reference typed with parameter types equal to its arguments' types and a
    result type equal to the call's type. `AliasForward` relies on this, since
    it carries the caller's reference metadata (its type) unchanged. This is
    the root-cause check; it is engine-independent. A failure reports, e.g.,
    `mul is referenced at number -> number -> number but called with
    [number1, number1] giving number1`.
  - The substitution engine, after alias forwarding as the build runs it,
    with `Basics.mul` an alias of `Elm.Kernel.Basics.mul` as in `elm/core`:
    every call of a kernel must have parameter types equal to its arguments'
    types. A failure reports, e.g., `Basics.mul is typed [MFloat,MFloat] but
    called with [MFloat,MInt]`.

Among what is not tested: calls nested inside a `case`, a destructuring, a
record, or (in the typed graph) a `let`-bound definition, since the expression
walks do not descend into them; the fixture has none. Operator values passed
as arguments (`Can.VarOperator`) are not exercised.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as SB
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.PreMono.AliasForward as AliasForward
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Monomorphize.Monomorphize as Monomorphize
import Compiler.Reporting.Annotation as A
import Data.Map
import Data.Set
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| Two checks: in the typed optimizer's graph, each global call the
expression walk reaches has a reference type matching its arguments and
result; in the substitution engine's output after alias forwarding, each
kernel call the walk reaches has parameter types matching its arguments.
-}
suite : Test
suite =
    Test.describe "A binop's operator reference is typed at its use (subst + alias forwarding)"
        [ Test.test "typed optimizer types each operator reference at its operands' types" <|
            \_ ->
                case Pipeline.runToTypedOpt wrapIntModule of
                    Err msg ->
                        Expect.fail msg

                    Ok result ->
                        let
                            (TOpt.LocalGraph data) =
                                result.localGraph
                        in
                        data.nodes
                            |> Data.Map.values
                            |> List.concatMap nodeExprs
                            |> List.concatMap globalCallMismatches
                            |> expectNone
        , Test.test "substitution engine after alias forwarding calls the mul kernel at its operands' types" <|
            \_ ->
                case Pipeline.runToMonoStage5 wrapIntModule of
                    Err msg ->
                        Expect.fail msg

                    Ok artifacts ->
                        let
                            assigned =
                                EntryPrep.assign ( False, False ) "main" (withMulAlias artifacts.globalGraph)

                            ( forwardedGraph, forwardedState, _ ) =
                                AliasForward.run Config.default.inline assigned.mvarState assigned.graph
                        in
                        case Monomorphize.monomorphizeWithLimitsAssigned Config.defaultLimits "main" artifacts.globalTypeEnv { assigned | graph = forwardedGraph, mvarState = forwardedState } of
                            Err msg ->
                                Expect.fail msg

                            Ok (Mono.MonoGraph graph) ->
                                graph.nodes
                                    |> Array.toList
                                    |> List.filterMap identity
                                    |> List.concatMap monoNodeExprs
                                    |> List.concatMap kernelCallMismatches
                                    |> expectNone
        ]


{-| `wrapInt x = ( x * 1, 4 * 2 * 2 )` and `testValue = wrapInt 2.5`.
-}
wrapIntModule : Src.Module
wrapIntModule =
    SB.makeModuleWithDefs "WrapInt"
        [ ( "wrapInt"
          , [ SB.pVar "x" ]
          , SB.tupleExpr
                (SB.binopsExpr [ ( SB.varExpr "x", "*" ) ] (SB.intExpr 1))
                (SB.binopsExpr [ ( SB.intExpr 4, "*" ), ( SB.intExpr 2, "*" ) ] (SB.intExpr 2))
          )
        , ( "testValue", [], SB.callExpr (SB.varExpr "wrapInt") [ SB.floatExpr 2.5 ] )
        ]


{-| Adds `Basics.mul = Elm.Kernel.Basics.mul`, as `elm/core` defines it, to a
global graph built from the mock interfaces, which carry no code.
-}
withMulAlias : TOpt.GlobalGraph Name -> TOpt.GlobalGraph Name
withMulAlias (TOpt.GlobalGraph nodes fields annotations roots supers) =
    let
        number =
            Can.TVar "number"

        mulType =
            Can.tLambda number (Can.tLambda number number)

        node =
            TOpt.Define
                (TOpt.VarKernel A.zero "Elm" "Basics" "mul" { tipe = mulType, tvar = Nothing })
                Data.Set.empty
                { tipe = mulType, tvar = Nothing }
    in
    TOpt.GlobalGraph
        (Data.Map.insert TOpt.toComparableGlobal (TOpt.Global ModuleName.basics "mul") node nodes)
        fields
        annotations
        roots
        supers


{-| Passes on an empty list; otherwise fails with the problems, one per line.
-}
expectNone : List String -> Expect.Expectation
expectNone problems =
    if List.isEmpty problems then
        Expect.pass

    else
        Expect.fail (String.join "\n" problems)



-- ====== TYPED OPTIMIZED GRAPH ======


{-| Returns the body of a `Define` or `TrackedDefine` node; other node kinds
give nothing.
-}
nodeExprs : TOpt.Node Name -> List (TOpt.Expr Name)
nodeExprs node =
    case node of
        TOpt.Define e _ _ ->
            [ e ]

        TOpt.TrackedDefine _ e _ _ ->
            [ e ]

        _ ->
            []


{-| Returns a problem line for each call reached by `children` whose function
is a global reference typed with a function type that disagrees with the
arguments or the call's result.
-}
globalCallMismatches : TOpt.Expr Name -> List String
globalCallMismatches expr =
    let
        here =
            case expr of
                TOpt.Call _ (TOpt.VarGlobal _ (TOpt.Global _ name) funcMeta) args callMeta ->
                    let
                        ( params, result ) =
                            peel (List.length args) funcMeta.tipe

                        argTypes =
                            List.map TOpt.typeOf args
                    in
                    if params == argTypes && result == callMeta.tipe then
                        []

                    else
                        [ name
                            ++ " is referenced at "
                            ++ Debug.toString funcMeta.tipe
                            ++ " but called with "
                            ++ Debug.toString argTypes
                            ++ " giving "
                            ++ Debug.toString callMeta.tipe
                        ]

                _ ->
                    []
    in
    here ++ List.concatMap globalCallMismatches (children expr)


{-| Splits up to `n` parameter types off a function type, returning them with
the remaining type. Stops early, with the type reached as the result, when that
type is not a `Can.TLambda` (an alias-wrapped function type is not unwrapped).
-}
peel : Int -> Can.Type Name -> ( List (Can.Type Name), Can.Type Name )
peel n tipe =
    case ( n, tipe ) of
        ( 0, _ ) ->
            ( [], tipe )

        ( _, Can.TLambda _ a b ) ->
            let
                ( rest, r ) =
                    peel (n - 1) b
            in
            ( a :: rest, r )

        _ ->
            ( [], tipe )


{-| Returns the direct subexpressions the typed-graph walk descends into: a
call's function and arguments, tuple and list elements, function bodies, an
`if`'s conditions and branches, and a `let`'s body (not its definition). Every
other expression gives none.
-}
children : TOpt.Expr Name -> List (TOpt.Expr Name)
children expr =
    case expr of
        TOpt.Call _ f args _ ->
            f :: args

        TOpt.Tuple _ a b cs _ ->
            a :: b :: cs

        TOpt.List _ es _ ->
            es

        TOpt.Function _ _ body _ ->
            [ body ]

        TOpt.TrackedFunction _ _ body _ ->
            [ body ]

        TOpt.Let _ body _ ->
            [ body ]

        TOpt.If branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        _ ->
            []



-- ====== MONO GRAPH ======


{-| Returns the body of a `MonoDefine` or `MonoTailFunc` node; other node kinds
give nothing.
-}
monoNodeExprs : Mono.MonoNode -> List Mono.MonoExpr
monoNodeExprs node =
    case node of
        Mono.MonoDefine e _ ->
            [ e ]

        Mono.MonoTailFunc _ e _ ->
            [ e ]

        _ ->
            []


{-| Returns a problem line for each kernel call reached by `monoChildren` whose
argument types differ from the kernel reference's parameter types.
-}
kernelCallMismatches : Mono.MonoExpr -> List String
kernelCallMismatches expr =
    let
        here =
            case expr of
                Mono.MonoCall _ (Mono.MonoVarKernel _ _ home name kernelType) args _ _ ->
                    let
                        params =
                            monoParams (List.length args) kernelType

                        argTypes =
                            List.map Mono.typeOf args
                    in
                    if params == argTypes then
                        []

                    else
                        [ home ++ "." ++ name ++ " is typed " ++ Debug.toString params ++ " but called with " ++ Debug.toString argTypes ]

                _ ->
                    []
    in
    here ++ List.concatMap kernelCallMismatches (monoChildren expr)


{-| Returns the first `n` parameter types of a monomorphic function type,
continuing into the result type when one `MFunction` holds fewer than `n`
parameters. A non-function type ends the list early.
-}
monoParams : Int -> Mono.MonoType -> List Mono.MonoType
monoParams n tipe =
    if n <= 0 then
        []

    else
        case tipe of
            Mono.MFunction _ _ params result ->
                List.take n params ++ monoParams (n - List.length params) result

            _ ->
                []


{-| Returns the direct subexpressions the mono-graph walk descends into: a
call's function and arguments, tuple and list elements, a closure's body, a
`let`'s bound expression and body, and an `if`'s conditions and branches. Every
other expression gives none.
-}
monoChildren : Mono.MonoExpr -> List Mono.MonoExpr
monoChildren expr =
    case expr of
        Mono.MonoCall _ f args _ _ ->
            f :: args

        Mono.MonoTupleCreate _ es _ ->
            es

        Mono.MonoList _ es _ ->
            es

        Mono.MonoClosure _ body _ ->
            [ body ]

        Mono.MonoLet (Mono.MonoDef _ bound) body _ ->
            [ bound, body ]

        Mono.MonoLet (Mono.MonoTailDef _ _ bound) body _ ->
            [ bound, body ]

        Mono.MonoIf branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        _ ->
            []
