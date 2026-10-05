module Compiler.Data.HeapLimits exposing (maxStageArity)

{-| Eco heap and closure limits that users can hit. They mirror
`runtime/src/allocator/Heap.hpp` (`CLOSURE_MAX_ARITY`); keep both in step.
This module imports nothing from `Compiler.*`, so canonicalization,
monomorphization and the MLIR generator can all use it, and it is the only
place these numbers appear in the Elm compiler.

@docs maxStageArity

-}


{-| The largest stage arity a closure may have (HEAP\_078): its parameters plus
its captured variables. The closure header's `max_values` field is 11 bits, and
2047 is `CLOSURE_MAX_ARITY` in the runtime.
-}
maxStageArity : Int
maxStageArity =
    2047
