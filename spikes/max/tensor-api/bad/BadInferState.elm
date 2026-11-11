module BadInferState exposing (..)

import Infer
import Nn.KvCache as KvCache
import Round2 exposing (..)
import Signature as Sig
import Tensor as T


-- the step must return the state it was given (a cache), not the layer's output
g =
    Infer.step "step" layerSpec (KvCache.sig T.float32 kvHeads context headDim) (Sig.pair (Sig.i64 T.scalar) (Sig.f32 (T.r2 (T.dim Seq 1) model))) (Sig.f32 (T.r2 (T.dim Seq 1) model)) (\l c ( p, x ) -> ( Tuple.second (step l c p x), x ))
