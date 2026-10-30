module Compiler.GlobalOpt.FloatMinMax exposing (rewrite)

{-| Gives elm/core's `Basics.max`, `Basics.min` and `Basics.clamp` at `Float` IEEE 754-2019
semantics on every path (CGEN\_086, design\_docs/float-semantics.md).

elm/core defines them in Elm on top of the order operators (`max x y = if gt x y then x else y`),
so with a NaN argument the result depends on the argument order. This pass replaces the body of
each `Float` specialization of the three with calls of the `Basics` kernel functions `max` and
`min`, which `Compiler.GlobalOpt.KernelIntrinsics` lowers to `eco.float.max` / `eco.float.min`
(IEEE 754-2019 maximum / minimum: NaN propagates, -0 is below +0); `clamp lo hi x` becomes
`min (max x lo) hi`. No C++ `Basics.max` or `Basics.min` exists, so these kernel calls must always
be intrinsics: the pass only builds saturated calls with two `Float` arguments.

It runs before the post-mono inliner (`Compiler.Pipeline.Steps.inline`), so a call site that
inlines one of these specializations gets the new body, and a use as a function value calls the
rewritten specialization. A program's own function of the same name is never rewritten: the
functions are recognised by the registry's key, home package included. `Int` and other
specializations keep elm/core's bodies.

@docs rewrite

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Monomorphize.Registry as Registry
import Compiler.Reporting.Annotation as A


{-| Returns the graph with the body of every `Float` specialization of elm/core's `Basics.max`,
`Basics.min` and `Basics.clamp` replaced, as the module comment describes. Every other node is
unchanged.
-}
rewrite : Mono.MonoGraph -> Mono.MonoGraph
rewrite (Mono.MonoGraph graph) =
    Mono.MonoGraph
        { graph
            | nodes =
                Array.indexedMap
                    (\specId maybeNode -> Maybe.map (rewriteNode graph.registry specId) maybeNode)
                    graph.nodes
        }


{-| Returns `node` rewritten when `specId` is a specialization of one of the three functions,
and `node` unchanged otherwise.
-}
rewriteNode : Mono.SpecializationRegistry -> Mono.SpecId -> Mono.MonoNode -> Mono.MonoNode
rewriteNode registry specId node =
    case Registry.lookupSpecKey specId registry of
        Just ( Mono.Global (ModuleName.Canonical pkg "Basics") name, _ ) ->
            if pkg == Pkg.core && (name == "max" || name == "min" || name == "clamp") then
                rewriteFloatNode name node

            else
                node

        _ ->
            node


{-| Returns `node` with its body replaced when it is a `MonoDefine` of a closure with no
captures whose parameters are all `Float` (two for `max` and `min`, three for `clamp`), and
`node` unchanged otherwise.
-}
rewriteFloatNode : Name.Name -> Mono.MonoNode -> Mono.MonoNode
rewriteFloatNode name node =
    case node of
        Mono.MonoDefine (Mono.MonoClosure ci _ ct) nt ->
            if List.isEmpty ci.captures && List.all (\( _, t ) -> t == Mono.MFloat) ci.params then
                case ( name, ci.params ) of
                    ( "clamp", [ ( lo, _ ), ( hi, _ ), ( x, _ ) ] ) ->
                        Mono.MonoDefine
                            (Mono.MonoClosure ci
                                (floatKernel "min" (floatKernel "max" (local x) (local lo)) (local hi))
                                ct
                            )
                            nt

                    ( _, [ ( a, _ ), ( b, _ ) ] ) ->
                        if name == "clamp" then
                            node

                        else
                            Mono.MonoDefine (Mono.MonoClosure ci (floatKernel name (local a) (local b)) ct) nt

                    _ ->
                        node

            else
                node

        _ ->
            node


local : Name.Name -> Mono.MonoExpr
local n =
    Mono.MonoVarLocal n Mono.MFloat


{-| A saturated call of the `Basics` kernel function `name` on two `Float`s, returning a
`Float`. The call kind is `CallDirectFlat`, so the arguments are passed unboxed.
-}
floatKernel : Name.Name -> Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr
floatKernel name a b =
    let
        defaultInfo : Mono.CallInfo
        defaultInfo =
            Mono.defaultCallInfo
    in
    Mono.MonoCall A.zero
        (Mono.MonoVarKernel A.zero
            "Elm"
            "Basics"
            name
            (Mono.mFunction Mono.topSynth [ Mono.MFloat, Mono.MFloat ] Mono.MFloat)
        )
        [ a, b ]
        Mono.MFloat
        { defaultInfo | callKind = Mono.CallDirectFlat }
