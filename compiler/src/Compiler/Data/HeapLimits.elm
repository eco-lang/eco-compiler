module Compiler.Data.HeapLimits exposing (maxStageArity, maxCtorFields, maxRecordFields)

{-| Eco heap and closure limits that users can hit. They mirror
`runtime/src/allocator/Heap.hpp` (`CLOSURE_MAX_ARITY`, `CUSTOM_MAX_FIELDS`,
`RECORD_MAX_FIELDS`); keep both in step.
This module imports nothing from `Compiler.*`, so canonicalization,
monomorphization and the MLIR generator can all use it, and it is the only
place these numbers appear in the Elm compiler.

@docs maxStageArity, maxCtorFields, maxRecordFields

-}


{-| The largest stage arity a closure may have (HEAP\_078): its parameters plus
its captured variables. The closure header's `max_values` field is 11 bits, and
2047 is `CLOSURE_MAX_ARITY` in the runtime.
-}
maxStageArity : Int
maxStageArity =
    2047


{-| The most fields a custom type variant may have (HEAP\_019): 24 slots whose
kinds live in the Custom header bitmap plus at most 63 tail kind words of 32
slots each. 2040 is `CUSTOM_MAX_FIELDS` in the runtime.
-}
maxCtorFields : Int
maxCtorFields =
    2040


{-| The most fields a record may have (HEAP\_019): 32 header slots plus at most
63 tail kind words. 2047 (not 2048) is `RECORD_MAX_FIELDS` in the runtime, so a
record alias's constructor function (arity = field count) also fits
`maxStageArity`.
-}
maxRecordFields : Int
maxRecordFields =
    2047
