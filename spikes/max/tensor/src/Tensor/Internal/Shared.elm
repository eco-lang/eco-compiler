module Tensor.Internal.Shared exposing (shared)

{-| A function applied in a graph to different arguments would otherwise have its operations
copied into the graph for each set of arguments. This module makes a _shared function_ instead:
one whose operations are recorded as a body, and whose applications each call such a body.

To _trace_ a function is to apply it to _placeholders_ (`Var` leaves standing for its arguments)
and keep the outputs it returns, written in terms of them: its _body_
(`Tensor.Internal.Expr.Body`). An application of a shared function is a `Call` node that holds
the body, a _symbol_ naming it, and the actual arguments; each result of the application is read
from that node through a projection (`proj`). How a `Call` is lowered, as an `mo.call` of a
subgraph named by the symbol or inlined inside a branch or loop, is `Tensor.Internal.Lower`'s to
say.

When the function is traced depends on the argument signature, the first signature `shared`
takes. If every slot of it (each tensor it describes) declares a dtype and a shape, the function is
traced once, when the shared function is made, and every application uses that body: the _eager
trace_, except an application whose arguments have pending axes (`shared` says more). Otherwise it
is traced at each application, on placeholders with the metas (dtypes, shapes and pending axes) of
that application's arguments.

The key the placeholders carry, their scope, mixes the function's name and the dtypes and shapes
the placeholders are made with: the signature's in the eager trace, and otherwise the arguments'.
Each placeholder's own key also mixes its pending axes. So without an eager trace, two applications
of one shared function whose arguments have the same dtypes, shapes and pending axes trace the same
body. The symbol is the name, an underscore, and a number below
10⁶ taken from the body's scope and output keys, so equal bodies under one name get equal symbols.
Different bodies under one name can also get one symbol, when those numbers happen to agree.
`Tensor.Internal.Lower` tells bodies apart by their scope and output keys, not by symbol, so each
such body still gets a subgraph of its own.

-}

import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Key as K
import Tensor.Internal.Prim
import Tensor.Internal.Shape exposing (Meta, showShape)
import Tensor.Internal.Types as I


{-| Returns a shared function named `name`, traced from `f`, that takes its arguments through the
first signature and gives its results through the second.

An application gives the value the second signature builds from the projections of one `Call`
node, one per output of the body. The body is the eager trace when every slot of the first
signature declares a dtype and a shape, and otherwise a trace on that application's arguments.
Placeholders of a trace on the arguments have the arguments' metas, pending axes (axes held as size
1 whose real size is not known yet, as `Tensor.Internal.Shape` defines them) included, so such an
axis stays pending inside the body.

With an eager trace, each argument is compared with the placeholder for it. An application whose
arguments, in number, dtype or shape, differ from the placeholders gives a `Call` node failed with
a build error such as "shared sq: argument 0 is f32[4], the signature says f32[3]". One whose
arguments agree with them but have pending axes is traced on its arguments instead, as if the
signature declared nothing.

The second signature is compared with the body's outputs: a `Call` node whose body has a different
number of outputs from its slots, or an output whose dtype or shape differs from what its slot
declares, is failed with a build error such as "shared f: result 0 is f32[4], the signature says
f32[3]". A slot that declares no dtype or shape accepts any.

-}
shared : String -> I.SigBuilder a a -> I.SigBuilder b b -> (a -> b) -> I.Shared a b
shared name (I.SigBuilder sa) (I.SigBuilder sb) f =
    let
        declared =
            List.map (\sl -> Maybe.map2 (\dt s -> { shape = s, pending = [], dtype = dt }) sl.dtype sl.shape) sa.slots

        traceOn : List Meta -> E.Body
        traceOn metas =
            let
                scope =
                    List.foldl (\m k -> k |> K.mixString (Tensor.Internal.Prim.dtName m.dtype) |> K.mixInts m.shape) (K.start "shared" |> K.mixString name) metas

                vars =
                    List.indexedMap (\i m -> E.varMeta scope i m) metas
            in
            { scope = scope, arity = List.length metas, outputs = sb.flatten (f (Tuple.first (sa.build vars))) }

        eager =
            if List.all ((/=) Nothing) declared then
                Just ( traceOn (List.filterMap identity declared), List.filterMap identity declared )

            else
                Nothing

        apply a =
            let
                args =
                    sa.flatten a

                metas =
                    List.map E.meta args

                ( body, argError ) =
                    case eager of
                        Just ( b, placeholders ) ->
                            case argumentError placeholders metas of
                                Just msg ->
                                    ( b, Just msg )

                                Nothing ->
                                    if List.all (.pending >> List.isEmpty) metas then
                                        ( b, Nothing )

                                    else
                                        ( traceOn metas, Nothing )

                        Nothing ->
                            ( traceOn metas, Nothing )

                symbol =
                    name ++ "_" ++ String.fromInt (modBy 1000000 (Tuple.first (bodyKey body)))

                check =
                    case argError of
                        Just msg ->
                            Just msg

                        Nothing ->
                            resultError body

                node =
                    case check of
                        Just msg ->
                            E.failWith ("shared " ++ name ++ ": " ++ msg) (E.call symbol body args)

                        Nothing ->
                            E.call symbol body args
            in
            Tuple.first (sb.build (List.indexedMap (\i _ -> E.proj node i) body.outputs))

        resultError body =
            if List.length body.outputs /= List.length sb.slots then
                Just ("the result signature describes " ++ String.fromInt (List.length sb.slots) ++ " tensors, the body gives " ++ String.fromInt (List.length body.outputs))

            else
                List.map2
                    (\( i, o ) sl ->
                        let
                            want =
                                { shape = Maybe.withDefault (E.shape o) sl.shape, pending = [], dtype = Maybe.withDefault (E.dtype o) sl.dtype }
                        in
                        if want.shape == E.shape o && want.dtype == E.dtype o then
                            Nothing

                        else
                            Just ("result " ++ String.fromInt i ++ " is " ++ describe (E.meta o) ++ ", the signature says " ++ describe want)
                    )
                    (List.indexedMap Tuple.pair body.outputs)
                    sb.slots
                    |> List.filterMap identity
                    |> List.head
    in
    I.Shared { name = name, apply = apply }


{-| Returns why arguments with the metas `got` do not fit placeholders with the metas `want`: a
different number of them, or the first argument whose dtype or shape differs. Pending axes are not
compared. `Nothing` when they fit.
-}
argumentError : List Meta -> List Meta -> Maybe String
argumentError want got =
    if List.length want /= List.length got then
        Just ("the signature describes " ++ String.fromInt (List.length want) ++ " arguments, the application gives " ++ String.fromInt (List.length got))

    else
        List.map2
            (\( i, w ) g ->
                if w.shape == g.shape && w.dtype == g.dtype then
                    Nothing

                else
                    Just ("argument " ++ String.fromInt i ++ " is " ++ describe g ++ ", the signature says " ++ describe w)
            )
            (List.indexedMap Tuple.pair want)
            got
            |> List.filterMap identity
            |> List.head


{-| Returns a meta's dtype and shape as messages write them, such as `f32[2, 3]`, with the position
of each pending axis after the shape.
-}
describe : Meta -> String
describe m =
    Tensor.Internal.Prim.dtName m.dtype
        ++ showShape m.shape
        ++ (if List.isEmpty m.pending then
                ""

            else
                " (broadcast at " ++ String.join ", " (List.map String.fromInt m.pending) ++ ")"
           )


{-| Returns the key a call's symbol is taken from: `b`'s scope and then the key of each of its
outputs, in order, mixed into a key started from `"body"`. It is not how `E.call` mixes a body
into its own key, which also mixes in the arity.
-}
bodyKey : E.Body -> K.Key
bodyKey b =
    List.foldl (\o k -> K.mixKey (E.key o) k) (K.start "body" |> K.mixKey b.scope) b.outputs
