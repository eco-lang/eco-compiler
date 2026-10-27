module Compiler.Monomorphize.ValidateLimits exposing (check)

{-| Reports the closures that monomorphization has made too wide for the
runtime to hold, so that the build fails with a located error rather than a
crash in the MLIR generator.

A closure's _stage arity_ is its parameters plus its captured variables, and
the runtime caps it at `Compiler.Data.HeapLimits.maxStageArity`.
Canonicalization rejects source functions over that limit, but specialization
can turn one captured polymorphic local function into several captured
specializations, so a closure can pass the limit only after monomorphization.
`check` walks every expression of every specialization in a monomorphized
graph and describes each closure over the limit by its specialization's name
and a source position. The generator's own check of the same limit crashes.

@docs check

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.HeapLimits as HeapLimits
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Reporting.Annotation as A


{-| Returns one message per closure in `graph`, nested closures included,
whose parameters plus captured variables exceed `HeapLimits.maxStageArity`;
empty when there is none. Messages are grouped by specialization in id order.

Only defined functions, tail-recursive functions and ports are searched; the
other kinds of node hold no expression.

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


{-| Returns the expression a node holds, or `Nothing` for a node kind that holds
none.
-}
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


{-| Returns the name of the specialization `specId` as `Module.name`, without
the package, or `.field` for an accessor. A specialization the registry has no
entry for is named `<spec N>`.
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


{-| Adds a message to `acc` when `expr` is a closure over the stage arity
limit, naming it by `where_`; any other expression leaves `acc` unchanged.
-}
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


{-| Returns a source region for a closure body: the body's own region if it has
one, otherwise the region of the first sub-expression that has one in a
children-first walk, otherwise `A.zero`.
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


{-| Builds the error text for a closure of `slots` stage arity, located by
the specialization name `where_` and the start of the region. A closure with
no known region is reported at line 0, column 0.
-}
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
