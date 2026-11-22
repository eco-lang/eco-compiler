module Compiler.MonoOpt.GenCallCensus exposing (census, render)

{-| Counts the calls the compiler could not make directly, by what kind of
expression supplies the function being called, so that a report can show where
generic calls come from.

After GlobalOpt every staged-curried call (`Mono.StageCurried`) carries a
`CallKind`. Two of the kinds are generic: `CallSegmentationUnknown` and
`CallGenericApply`, both described by `Compiler.IR.Mono`. In both the
runtime, not the compiler, decides when the closure has all its arguments.
`census` counts each such call under its kind and a tag for its callee, the
expression in function position:

  - `param`: a local variable whose name is bound as a parameter somewhere in
    the same top-level node;
  - `local`: any other local variable;
  - `callResult`: the result of another call;
  - `field`: a record field read;
  - `join`: a `case` or `if` expression;
  - `global`: a global reference;
  - `other`: anything else.

Each such call is also counted under `lss<Class>:<tag>`, the class saying what
the lambda set on its callee's type (`Mono.headAnno`) knows about the closures
that can be called (`Compiler.MonoOpt.MemberArity.classify`):

  - `lssTop`, `lssVar`, `lssPartial`: the set is ⊤, a set variable, or only a
    lower bound, so it names no complete set of closures; `lssTopWhy+<label>`
    counts the ⊤s by provenance;
  - `lssUnresolved`: a complete set with a member whose arity is not known;
    `lssUnresolvedWhy+<why>` counts them by reason;
  - `lssEmpty`: a complete set with no members;
  - `lssDisagree`: a complete set whose members' arities differ;
  - `lssExact`, `lssOver`, `lssUnder`: a complete set whose members all take
    the same number of arguments, which the call supplies exactly, more of, or
    fewer of.

The count reads the graph and changes nothing.

@docs census, render

-}

import Array
import Compiler.Core.Name exposing (Name)
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as MonoTraverse
import Compiler.MonoOpt.MemberArity as MemberArity
import Dict exposing (Dict)
import Set exposing (Set)


{-| Returns the tag for `callee`, one of those listed in the module docstring.
A local variable is tagged `param` when its name is in `params`, and `local`
otherwise.
-}
calleeTag : Set Name -> Mono.MonoExpr -> String
calleeTag params callee =
    case callee of
        Mono.MonoVarLocal name _ ->
            if Set.member name params then
                "param"

            else
                "local"

        Mono.MonoCall _ _ _ _ _ ->
            "callResult"

        Mono.MonoRecordAccess _ _ _ ->
            "field"

        Mono.MonoCase _ _ _ _ _ ->
            "join"

        Mono.MonoIf _ _ _ ->
            "join"

        Mono.MonoVarGlobal _ _ _ ->
            "global"

        _ ->
            "other"


{-| Counts the generic staged-curried calls in the graph, keyed
`<kind>:<tag>`, where the kind is `segunk` for `CallSegmentationUnknown` and
`generic` for `CallGenericApply`. A key that no call produced is absent rather
than zero.

Only nodes with a body are walked: definitions, tail functions and ports. The
parameter names used for the `param` tag are collected once per node, from its
own parameters if it is a tail function and from every closure and local
tail-recursive definition inside it, so they are not scoped to the function
that contains the call.

-}
census : Dict Int MemberArity.MemberArity -> Mono.MonoGraph -> Dict String Int
census arities (Mono.MonoGraph mono) =
    let
        paramNames acc e =
            case e of
                Mono.MonoClosure info _ _ ->
                    List.foldl (\( n, _ ) a -> Set.insert n a) acc info.params

                Mono.MonoLet (Mono.MonoTailDef _ ps _) _ _ ->
                    List.foldl (\( n, _ ) a -> Set.insert n a) acc ps

                _ ->
                    acc

        count params acc e =
            case e of
                Mono.MonoCall _ callee args _ info ->
                    let
                        tag =
                            calleeTag params callee

                        lss a =
                            List.foldl bump a (lssKeys arities tag callee (List.length args))
                    in
                    case ( info.callModel, info.callKind ) of
                        ( Mono.StageCurried, Mono.CallSegmentationUnknown ) ->
                            lss (bump ("segunk:" ++ tag) acc)

                        ( Mono.StageCurried, Mono.CallGenericApply ) ->
                            lss (bump ("generic:" ++ tag) acc)

                        _ ->
                            acc

                _ ->
                    acc

        bump k acc =
            Dict.update k (\v -> Just (Maybe.withDefault 0 v + 1)) acc

        node params0 e acc =
            let
                params =
                    MonoTraverse.foldExprAccFirst paramNames params0 e
            in
            MonoTraverse.foldExprAccFirst (count params) acc e
    in
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just (Mono.MonoDefine e _) ->
                    node Set.empty e acc

                Just (Mono.MonoTailFunc ps e _) ->
                    node (Set.fromList (List.map Tuple.first ps)) e acc

                Just (Mono.MonoPortIncoming e _) ->
                    node Set.empty e acc

                Just (Mono.MonoPortOutgoing e _) ->
                    node Set.empty e acc

                _ ->
                    acc
        )
        Dict.empty
        mono.nodes


{-| The keys a generic call through `callee` with `argCount` arguments adds
for the lambda set on the callee's type, as the module docstring describes.
-}
lssKeys : Dict Int MemberArity.MemberArity -> String -> Mono.MonoExpr -> Int -> List String
lssKeys arities tag callee argCount =
    let
        keyed cls =
            [ cls ++ ":" ++ tag ]
    in
    case MemberArity.classify arities (Mono.typeOf callee) of
        MemberArity.SetTop label ->
            ("lssTopWhy+" ++ label) :: keyed "lssTop"

        MemberArity.SetVar ->
            keyed "lssVar"

        MemberArity.SetPartial ->
            keyed "lssPartial"

        MemberArity.SetUnresolved why ->
            ("lssUnresolvedWhy+" ++ why) :: keyed "lssUnresolved"

        MemberArity.SetEmpty ->
            keyed "lssEmpty"

        MemberArity.SetDisagree ->
            keyed "lssDisagree"

        MemberArity.SetAgree arity ->
            if argCount == arity then
                keyed "lssExact"

            else if argCount > arity then
                keyed "lssOver"

            else
                keyed "lssUnder"


{-| Renders the counts as `key=count` pairs in key order, separated by single
spaces. An empty census renders as the empty string.
-}
render : Dict String Int -> String
render d =
    Dict.toList d
        |> List.map (\( k, v ) -> k ++ "=" ++ String.fromInt v)
        |> String.join " "
