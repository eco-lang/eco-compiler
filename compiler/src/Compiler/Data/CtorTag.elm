module Compiler.Data.CtorTag exposing (checkNullConsCapacity, constantTag, effective, embedsAsNullCons, isEmbeddedConstantCtor, nullConsCapacity)

{-| Runtime ctor-tag conventions shared between monomorphization (which sets
`CtorShape.tag` used at construction time) and code generation (which emits the
ctor-tag constants used by pattern matching).

Most constructors use their zero-based declaration index as the runtime tag.
Some types, however, need the runtime to recognise them as "special" so that
structural operations like `==` can implement type-specific semantics instead
of the default tree-shape walk. We reserve the top of the 16-bit ctor range
for those markers; the values must stay in sync with
`elm-kernel-cpp/src/core/Utils.cpp`.

The current reservations cover `Dict`/`Set` so that `Dict` equality compares
by content (in-order key/value traversal) instead of by tree shape.

@docs effective

-}

import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)



-- ============================================================================
-- ====== RESERVED CTOR TAGS ======
-- ============================================================================


{-| Ctor tag for `Dict.RBNode_elm_builtin`. Must match `Utils.cpp`.

`RBEmpty_elm_builtin` is deliberately NOT reserved: it is nullary, so it
compiles to an embedded null-cons constant carrying its plain declaration
index 1 (HEAP_044, plans/null-cons-hpointer-embedding.md P3.0). The reserved
set is {0xFFFF RBNode, 0xFFFD constantTag}.

-}
dictRBNode : Int
dictRBNode =
    0xFFFF


{-| Ctor tag emitted for embedded "empty" constant constructor branches
(`Nil`, `Nothing`, and any other nullary constant that shares the merged empty
bit pattern). Because those constants can no longer be told apart by value, the
runtime returns this single reserved tag for all of them (`eco_get_tag` / the
`eco.case` lowering), and the compiler tags the matching branch the same. Sits
just below the `Dict` reservations. Must match `CONSTANT_TAG` in
`runtime/src/allocator/Heap.hpp` and `value_enc::ConstantTag`. See plan D9.
-}
constantTag : Int
constantTag =
    0xFFFD


{-| True for a constructor whose runtime representation is an embedded HPointer
constant (Nothing / True / False). Mirrors the nullary-constant selection in
`Compiler.Generate.MLIR.Functions.generateNullaryConstructor`. Such
constructors dispatch by the merged constant tag (`constantTag`) rather than a
per-declaration index, since their bit pattern is shared with the other empties.
(True / False normally reach pattern matching via `Test.IsBool`, not
`Test.IsCtor`; they are included here for completeness.)
-}
isEmbeddedConstantCtor : Name -> Bool
isEmbeddedConstantCtor name =
    name == "Nothing" || name == "True" || name == "False"



-- ============================================================================
-- ====== NULL-CONS EMBEDDING (HEAP_044 / CGEN_079) ======
-- ============================================================================


{-| Nullary ctors embed as HPointer null-cons constants carrying their
zero-based DECLARATION INDEX (`(idx << 43) | 0b111` — see
plans/null-cons-hpointer-embedding.md §2.1), EXCEPT the legacy three whose bit
patterns predate this mechanism (True/False via Bool, Nothing via the merged
empty 0x6 — see D3). RBEmpty is index 1 like any other ctor (P3.0 demoted its
reservation); RBNode keeps 0xFFFF but has 5 fields so it never meets this
mechanism.
-}
nullConsCapacity : Int
nullConsCapacity =
    1023


{-| Does this nullary constructor compile to `eco.constant.null_cons`?
Takes the ctor name and its effective tag; the tag is unused today (every
nullary ctor's effective tag is its declaration index after P3.0) but keeps
the policy's signature honest should a reserved nullary tag ever reappear.
-}
embedsAsNullCons : Name -> Int -> Bool
embedsAsNullCons name _ =
    not (isEmbeddedConstantCtor name)


{-| Enforce the 10-bit `null_cons_idx` capacity: passes the tag through
unchanged, or hard-crashes the compile naming the constructor (user decision
2026-08-19 — see plans/null-cons-hpointer-embedding.md §2.2; the corpus
maximum is ~20, so this is theoretical headroom).
-}
checkNullConsCapacity : Name -> Int -> Int
checkNullConsCapacity name tag =
    if tag > nullConsCapacity then
        crash
            ("nullary constructor '"
                ++ name
                ++ "' has declaration index "
                ++ String.fromInt tag
                ++ ", exceeding the 10-bit HPointer null_cons_idx capacity ("
                ++ String.fromInt nullConsCapacity
                ++ "); widen the field using the padding bits — see "
                ++ "plans/null-cons-hpointer-embedding.md §2.2"
            )

    else
        tag



-- ============================================================================
-- ====== TAG COMPUTATION ======
-- ============================================================================


{-| Compute the runtime ctor tag for a constructor.

Normal constructors use `Index.toMachine` (their zero-based declaration index).
Constructors in runtime-recognised types (currently `Dict`) use reserved tag
values so the runtime can dispatch to a type-specific implementation.

-}
effective : IO.Canonical -> Name -> Index.ZeroBased -> Int
effective home name index =
    if home == ModuleName.dict then
        if name == "RBNode_elm_builtin" then
            dictRBNode

        else
            Index.toMachine index

    else
        Index.toMachine index
