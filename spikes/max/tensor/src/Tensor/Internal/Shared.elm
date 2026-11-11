module Tensor.Internal.Shared exposing (shared)

{-| Shared subgraphs: a function traced once on placeholders, applied through `Call` nodes that
lower to `mo.call` of one `isSubgraph` graph.

The body is traced when the `Shared` value is built, if the argument signature gives every shape;
otherwise at each application, on placeholders shaped like the arguments (identical traces share
one subgraph anyway: the subgraph is named by its body).

-}

import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Key as K
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Types as I


shared : String -> I.SigBuilder a a -> I.SigBuilder b b -> (a -> b) -> I.Shared a b
shared name (I.SigBuilder sa) (I.SigBuilder sb) f =
    let
        shapes =
            List.map (\sl -> Maybe.map2 Tuple.pair sl.dtype sl.shape) sa.slots

        allKnown =
            List.all ((/=) Nothing) shapes

        traceOn : List ( DT, List Int ) -> E.Body
        traceOn metas =
            let
                scope =
                    List.foldl (\( dt, s ) k -> k |> K.mixString (Tensor.Internal.Prim.dtName dt) |> K.mixInts s) (K.start "shared" |> K.mixString name) metas

                vars =
                    List.indexedMap (\i ( dt, s ) -> E.var scope i dt s) metas
            in
            { scope = scope, arity = List.length metas, outputs = sb.flatten (f (Tuple.first (sa.build vars))) }

        -- traced once, here, when every shape is known
        eager =
            if allKnown then
                Just (traceOn (List.filterMap identity shapes))

            else
                Nothing

        apply a =
            let
                args =
                    sa.flatten a

                body =
                    case eager of
                        Just b ->
                            b

                        Nothing ->
                            traceOn (List.map (\x -> ( E.dtype x, E.shape x )) args)

                symbol =
                    name ++ "_" ++ String.fromInt (modBy 1000000 (Tuple.first (bodyKey body)))

                node =
                    E.call symbol body args
            in
            Tuple.first (sb.build (List.indexedMap (\i _ -> E.proj node i) body.outputs))
    in
    I.Shared { name = name, apply = apply }


bodyKey : E.Body -> K.Key
bodyKey b =
    List.foldl (\o k -> K.mixKey (E.key o) k) (K.start "body" |> K.mixKey b.scope) b.outputs

