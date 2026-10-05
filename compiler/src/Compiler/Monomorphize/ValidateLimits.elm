module Compiler.Monomorphize.ValidateLimits exposing (check)

{-| Post-monomorphization backstop for the closure stage arity limit
(HEAP\_078, `plans/wide-object-tail-kind-words.md` §S.9).

Canonicalization rejects user-written functions, lambdas and local functions
whose parameters plus captured variables exceed
`Compiler.Data.HeapLimits.maxStageArity`. Specialization can still multiply
one captured polymorphic local function into several captured
specializations, so a closure can grow past the limit after
monomorphization. `check` finds every such closure and describes it with its
module, enclosing function and source position, so that the build fails with
a located error instead of reaching the MLIR generator, whose own check is an
internal-compiler-error assert.

`Builder.Generate` runs it unconditionally after monomorphization and again
after GlobalOpt. The passes between them decline any rewrite that would exceed
the limit, so a violation found by the second run is a compiler bug; it is
reported the same way.

@docs check

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.HeapLimits as HeapLimits
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Reporting.Annotation as A


{-| Returns one message per closure in `graph` whose parameters plus captured
variables exceed `HeapLimits.maxStageArity`, in specialization order; empty
when there is none.
-}
check : Mono.MonoGraph -> List String
check (Mono.MonoGraph graph) =
    Array.foldr
        (\( specId, maybeNode ) acc ->
            case maybeNode of
                Just node ->
                    case nodeExpr node of
                        Just e ->
                            Traverse.foldExpr (checkExpr (specName graph.registry specId)) [] e ++ acc

                        Nothing ->
                            acc

                Nothing ->
                    acc
        )
        []
        (Array.indexedMap Tuple.pair graph.nodes)


nodeExpr : Mono.MonoNode -> Maybe Mono.MonoExpr
nodeExpr node =
    case node of
        Mono.MonoDefine e _ ->
            Just e

        Mono.MonoTailFunc _ e _ ->
            Just e

        Mono.MonoPortIncoming e _ ->
            Just e

        Mono.MonoPortOutgoing e _ ->
            Just e

        _ ->
            Nothing


{-| `Home.function` for the specialization `specId`, from the registry's
reverse mapping.
-}
specName : Mono.SpecializationRegistry -> Int -> String
specName registry specId =
    case Array.get specId registry.reverseMapping |> Maybe.andThen identity of
        Just ( Mono.Global (ModuleName.Canonical _ home) name, _ ) ->
            home ++ "." ++ name

        Just ( Mono.Accessor field, _ ) ->
            "." ++ field

        Nothing ->
            "<spec " ++ String.fromInt specId ++ ">"


checkExpr : String -> Mono.MonoExpr -> List String -> List String
checkExpr where_ expr acc =
    case expr of
        Mono.MonoClosure info body _ ->
            let
                slots =
                    List.length info.params + List.length info.captures
            in
            if slots > HeapLimits.maxStageArity then
                message where_ (closureRegion body) slots :: acc

            else
                acc

        _ ->
            acc


{-| The region of a closure body: `Closure.extractRegion` of the body, or,
when that has none, the first located sub-expression.
-}
closureRegion : Mono.MonoExpr -> A.Region
closureRegion body =
    let
        direct =
            Closure.extractRegion body
    in
    if direct /= A.zero then
        direct

    else
        Traverse.foldExpr
            (\e found ->
                if found /= A.zero then
                    found

                else
                    Closure.extractRegion e
            )
            A.zero
            body


message : String -> A.Region -> Int -> String
message where_ (A.Region (A.Position line col) _) slots =
    where_
        ++ ": line "
        ++ String.fromInt line
        ++ ", column "
        ++ String.fromInt col
        ++ ": a closure has "
        ++ String.fromInt slots
        ++ " parameters and captured variables after specialization; Eco supports at most "
        ++ String.fromInt HeapLimits.maxStageArity
        ++ " (HEAP_078). Capture a record instead of many polymorphic local functions."
