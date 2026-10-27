module Compiler.Data.HeapLimits exposing (maxStageArity, maxCtorFields, maxRecordFields)

{-| The size limits of Eco's heap objects that an Elm program can exceed, so
that the compiler can reject such a program with an error instead of producing
code the runtime cannot represent.

Every closure, custom type value and record on the Eco heap records, for each of
its slots, whether the slot holds a pointer or an unboxed Int, Float or Char.
Those per-slot kinds live in a fixed number of header bits plus a bounded number
of extra "tail kind words" after the fields, and that bound fixes the most slots
an object can have. The runtime defines the same three numbers in
`runtime/src/allocator/Heap.hpp` (`CLOSURE_MAX_ARITY`, `CUSTOM_MAX_FIELDS`,
`RECORD_MAX_FIELDS`); the two definitions must be kept equal by hand.

The module imports nothing, so any phase of the compiler can use it, and the
limit checks in canonicalization, the optimizer and the MLIR generator all read
their numbers from here.

@docs maxStageArity, maxCtorFields, maxRecordFields

-}


{-| The largest stage arity a closure may have: its parameters plus its captured
variables. The closure header's `max_values` field is 11 bits, and 2047 is
`CLOSURE_MAX_ARITY` in the runtime.
-}
maxStageArity : Int
maxStageArity =
    2047


{-| The most fields a custom type variant may have: 24 slots whose kinds live in
the Custom header bitmap plus at most 63 tail kind words of 32 slots each.
2040 is `CUSTOM_MAX_FIELDS` in the runtime.
-}
maxCtorFields : Int
maxCtorFields =
    2040


{-| The most fields a record may have: 32 header slots plus at most 63 tail
kind words. 2047 (not 2048) is `RECORD_MAX_FIELDS` in the runtime, so a
record alias's constructor function (arity = field count) also fits
`maxStageArity`.
-}
maxRecordFields : Int
maxRecordFields =
    2047
