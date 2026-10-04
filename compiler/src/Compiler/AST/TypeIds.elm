module Compiler.AST.TypeIds exposing
    ( MVarPh, MVarId, firstMVarId, LamPh, SrcLambdaId, firstSrcLambdaId
    , ArrowPh, ArrowId, firstArrowId, ArrowSlot(..)
    )

{-| Once a program has been type checked, monomorphization and the passes
around it number three different things with integers, and this module gives
each numbering a type of its own so that one cannot be passed where another is
expected.

The three kinds of identity are:

  - an _MVar id_ (`MVarId`), naming one type variable across the whole
    program, as it appears in `Can.Type MVarId` and in the `MVar` of a
    `Compiler.AST.Monomorphized.MonoType`;
  - a _source lambda id_ (`SrcLambdaId`), naming one lambda node
    (`Function` or `TrackedFunction`) of the typed optimized graph;
  - an _arrow id_ (`ArrowId`), naming one arrow of a function type, or one
    group of arrows the type checker unified.

The last two serve _lambda-set specialization_, which attaches to each arrow
of a function type the set of function values that can flow through it.

Each is an `Id` from `Compiler.Data.Id` with a phantom kind (`MVarPh`, `LamPh`
or `ArrowPh`); that module's docstring says what an id supply is and why
uniqueness is up to whoever holds the supply. This module provides only the
types and the first id of each kind; the supplies from which
`Compiler.Monomorphize.AssignMVarIds` numbers the program are kept in that
module.

The module also defines `ArrowSlot`, the identity field carried by every
`Can.TLambda`, because what identity an arrow has depends on how far the
compiler has got.

@docs MVarPh, MVarId, firstMVarId, LamPh, SrcLambdaId, firstSrcLambdaId
@docs ArrowPh, ArrowId, firstArrowId, ArrowSlot

-}

import Compiler.Data.Id as Id exposing (Id)


{-| The phantom kind that marks an `Id` as an MVar id. It has no other use.
-}
type MVarPh
    = MVarPh


{-| The identity of one type variable across the whole program, as used in
`Can.Type MVarId` and in the `MVar` of a monomorphized type.

This is a name for `Id MVarPh`, not a new type.

-}
type alias MVarId =
    Id MVarPh


{-| The MVar id at the start of a supply. Its `Id.toComparable` is 0.
-}
firstMVarId : MVarId
firstMVarId =
    Id.first


{-| The phantom kind that marks an `Id` as a source lambda id. It has no other
use.
-}
type LamPh
    = LamPh


{-| The identity of one lambda node (`Function` or `TrackedFunction`) of the
typed optimized graph. `Compiler.GlobalOpt.PreMono.Fresh` gives an inlined
copy of a lambda an id of its own, and gives ids to lambdas the passes create,
so one lambda of the source program can have several ids, and an id need not
come from the source program.

This is a name for `Id LamPh`, not a new type. The MonoSolver engine names the
members of a lambda set by plain `Int` member ids, which are not
`SrcLambdaId`s; `Compiler.MonoSolver.Engine` says how they are numbered.

-}
type alias SrcLambdaId =
    Id LamPh


{-| The source lambda id at the start of a supply. Its `Id.toComparable` is 0.
-}
firstSrcLambdaId : SrcLambdaId
firstSrcLambdaId =
    Id.first


{-| The phantom kind that marks an `Id` as an arrow id. It has no other use.
-}
type ArrowPh
    = ArrowPh


{-| The identity of one arrow of a function type, by which lambda-set
specialization tells one arrow's lambda set from another's.

This is a name for `Id ArrowPh`, not a new type.

An arrow cannot be identified by its structure, because two unrelated
`Int -> Int` arrows would then share one lambda set. So `AssignMVarIds` gives
each arrow an id when it converts a `Can.Type Name` to a `Can.Type MVarId`. An
arrow stamped with a solver root (see `ArrowSlot`) takes the id of that root
when `AssignMVarIds` is asked to use solver roots, so arrows stamped with the
same root in one module share one id. Any other arrow gets a fresh id of its own.

`Compiler.GlobalOpt.PreMono.Fresh` also mints arrow ids: it gives each arrow
of a copied type a fresh id, and an id to any arrow still without one, so
arrows that once shared an id need not keep sharing it.

-}
type alias ArrowId =
    Id ArrowPh


{-| The arrow id at the start of a supply. Its `Id.toComparable` is 0.
-}
firstArrowId : ArrowId
firstArrowId =
    Id.first


{-| The identity a `Can.TLambda` carries for its arrow, whose meaning depends
on the phase that built the type.

The phases follow the type parameter of `Can.Type`. A `Can.Type Name` carries
`NoArrow` or `SolverRoot`. A `Can.Type MVarId`, which `AssignMVarIds`
produces, carries `NoArrow` or `Arrow`. This is how the code that builds types
uses the slot; the type does not prevent the other combinations.

`NoArrow` means the arrow has no identity. It is on arrows built before solver
roots are stamped, on arrows the stamping could not reach, and on every arrow
built with `Can.tLambda`, at any phase. Two `NoArrow` arrows are not the same
arrow, so a table keyed by arrow identity must never record `NoArrow` as a key,
or every unstamped arrow would share one entry.

`SolverRoot` carries the index of the arrow's union-find root in the type
checker's solve of one module, stamped by `Compiler.Type.SolverRoots` after
solving. Each module numbers its roots from zero, so the index means something
only together with that module. When `AssignMVarIds` is asked to use solver
roots, it resolves each pair of module and index to one `ArrowId`.

`Arrow` carries the arrow's `ArrowId`.

`Compiler.AST.Canonical`'s binary codec keeps only `SolverRoot`; it writes
`NoArrow` and `Arrow` alike as no identity, so an `Arrow` does not survive
serialization.

-}
type ArrowSlot
    = NoArrow
    | SolverRoot Int
    | Arrow ArrowId
