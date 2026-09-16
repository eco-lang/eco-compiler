module Compiler.Type.Vars exposing
    ( Variable, Point(..), PointCell(..), RootedVar
    , Descriptor, Content(..), SuperType(..), Mark(..)
    , FlatType(..), LambdaSet(..), SortedRel(..)
    )

{-| The union-find VOCABULARY of type inference: the data the solver's store
holds, with no reference to the monad that threads it.

Split out of `System.TypeCheck.IO` on 2026-09-08. These types were declared
alongside the `IO` monad, so every module that merely wanted to NAME a type
variable had to import the monad — 88 modules imported `System.TypeCheck.IO`
while only 13 ever used a monadic operation. The module's shape actively
misrepresented how widely the monad was used
(`/work/direct-call-decline-census.md` §3).

Pure data: nothing here mentions `IO` or `State`, which is exactly why the
split is possible. The layering is `IO -> Vars -> ModuleName`.

@docs Variable, Point, PointCell, RootedVar
@docs Descriptor, Content, SuperType, Mark
@docs FlatType, LambdaSet, SortedRel

-}

import Compiler.Elm.ModuleName exposing (Canonical)
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Dict as CoreDict


{-| A type variable is represented as a Point.

Variables are the fundamental unit of type inference, connected through
the union-find structure and associated with Descriptors.

-}
type alias Variable =
    Point


{-| A reference to a type variable in the union-find structure.

Points are integer indices into the `ioRefsPoint` array in the State.
Used to implement path compression and union-by-rank for type unification.

-}
type Point
    = Pt Int


{-| The union-find cell for a Point.

  - `Root weight descriptor`: a root, carrying its weight and its descriptor
    INLINE
  - `Chain parent`: a non-root node pointing at its parent

kernel-opt-02 replaced the former `PointInfo = Info Int Int | Link Point` plus
the separate `ioRefsWeight`/`ioRefsDescriptor` arrays with this single cell. The
three arrays were index-synchronised — only `UnionFind.fresh` ever grew them, one
element each — so `Info w d` stored two copies of the point's own index. The
merge preserves the numeric Point ids exactly.

-}
type PointCell
    = Root Int Descriptor
    | Chain Point


{-| A type descriptor containing information about a type variable.

Descriptors are stored inline in the `ioRefsPoint` cell of their root Point.
Each descriptor contains the actual type content, rank for generalization,
marking for traversal algorithms, and an optional copy field for cloning.

Formerly a single-constructor wrapper; collapsed to a bare record alias so it is
read/written directly on the hot union-find path with no box or wrap/unwrap.

  - `content`: The actual type information (flex var, rigid var, structure, etc.)
  - `rank`: Used for let-generalization and determining type variable scope
  - `mark`: Used by traversal algorithms to avoid revisiting nodes
  - `copy`: Optional reference to a copied variable during cloning operations

-}
type alias Descriptor =
    { content : Content
    , rank : Int
    , mark : Mark
    , copy : Maybe Variable
    }


{-| The content of a type descriptor.

  - `FlexVar name`: A flexible type variable (can be unified with anything)
  - `FlexSuper supertype name`: A flexible variable constrained by a supertype
  - `RigidVar name`: A rigid type variable (cannot be unified)
  - `RigidSuper supertype name`: A rigid variable constrained by a supertype
  - `Structure type`: A concrete type structure (function, record, etc.)
  - `Alias canonical name args realType`: A type alias with its expansion
  - `Error`: Represents a type error

-}
type Content
    = FlexVar (Maybe String)
    | FlexSuper SuperType (Maybe String)
    | RigidVar String
    | RigidSuper SuperType String
    | Structure FlatType
    | Alias Canonical String (List ( String, Variable )) Variable
    | Error


{-| Supertypes that constrain type variables.

  - `Number`: Can be Int or Float
  - `Comparable`: Can be compared with (<), (>), etc.
  - `Appendable`: Can be concatenated with (++)
  - `CompAppend`: Both comparable and appendable

-}
type SuperType
    = Number
    | Comparable
    | Appendable
    | CompAppend


{-| A mark used for graph traversal algorithms.

Marks prevent infinite loops when traversing cyclic type structures.
Each traversal uses a unique mark value to identify visited nodes.

-}
type Mark
    = Mark Int


{-| A union-find root variable together with the super constraint recorded on
its root descriptor at snapshot time.

The `super` is solver truth about the ROOT — it is read from the root's
`Content` (`FlexSuper`/`RigidSuper`) at normalization time, independent of
whichever type-variable name happens to refer to that root. This is what lets
downstream passes recover `number`/`comparable`/`appendable`/`compappend`
without re-parsing variable names.

-}
type alias RootedVar =
    { var : Variable
    , super : Maybe SuperType
    }


{-| The flattened representation of concrete type structures.

  - `App1 module name args`: Type constructor application (e.g., List Int)
  - `Fun1 arg result`: Function type (no lambda-set slot)
  - `FunL arg result setSlot`: Function type WITH a lambda-set slot. Minted
    ONLY by MonoSolver stores with `lss.enabled`; the typechecking phase
    never constructs it. `Fun1` retains the meaning "arrow with no set
    slot" so the lss-off path is allocation-identical to today.
  - `EmptyRecord1`: The empty record type {}
  - `Record1 fields extension`: Record type with named fields and optional extension
  - `Unit1`: The unit type ()
  - `Tuple1 first second rest`: Tuple type (2 or more elements)
  - `LambdaSet1 set`: A lambda set — the ONLY legal content of a
    `FunL` set slot besides `FlexVar` (LSS\_007); it never appears anywhere
    else, and typecheck-phase stores contain neither `FunL` nor
    `LambdaSet1`. Members are ground per-run ids. Since LSS\_023 a set MAY
    carry deferred in-edge source Points (`LsFrom` — Variables that are SET
    SLOTS, not type structure), so "no Variables inside" is retired; the
    join is STILL total (edge lists merge) and can never mismatch.

-}
type FlatType
    = App1 Canonical String (List Variable)
    | Fun1 Variable Variable
    | FunL Variable Variable Variable
    | EmptyRecord1
    | Record1 (CoreDict.Dict String Variable) Variable
    | Unit1
    | Tuple1 Variable Variable (List Variable)
    | LambdaSet1 LambdaSet


{-| An LSS lambda set in a `FunL` slot (`plans/lss-set-write-substrate.md`
Phase 2; formerly `Bool (Dict Int ())`).

`LsMembers` is ascending, deduped, and NON-EMPTY by construction — every
producer feeds an already-ascending list (a zonked `Mono.LSet`, a signature
fact, or a singleton injection), mirroring LSS\_001 for the in-store form.

`LsTop` is ⊤ (widened/kernel-facing): terminal (nothing un-tops a slot) and
absorbing under join. Members are DEAD under ⊤ at every reader in the repo
(audited 2026-08-17, census included), so ⊤ carries none — every poison
write is a set of the shared `lsTopContent` constant, allocation-free, and
every join-with-⊤ is a constant return. ⊤ also DROPS `LsFrom` sources
(⊤ ⊇ everything — sound).

`LsFrom members sources` (LSS\_023, `plans/lss-directed-set-flow.md`) is a
set carrying DEFERRED INCLUSION edges: "this slot ⊇ each source slot",
resolved at READ (zonk) time by a DFS over the reachable edge graph — never
eagerly, never by a write hook. Invariants:

  - the source list is NON-EMPTY by construction: no transition mints a
    source-free `LsFrom` (`Store.addSlotSource` only adds; merges carry
    sources through; ⊤ drops the whole variant). There is deliberately NO
    collapse rule.
  - `members` is ascending/deduped but MAY be empty (unlike `LsMembers`).
  - sources are deduped by `pointKey` at install; UF unions may later alias
    them — resolution re-dedupes via its visited set.
  - `LsFrom` is created ONLY under `lss.sigFlow` (every producer is gated,
    including the kernel-tunnel selector) and NEVER escapes the store:
    `zonkSetSlot`/`zonkSigGo` resolve it, `Mono.LambdaSetAnno` stays
    `LTop | LSet`.

-}
type LambdaSet
    = LsTop Int
    | LsMembers (List Int)
    | LsFrom (List Int) (List Variable)
      -- LsRow (F3-a, plans/lss-container-payload-transport.md §12.9.5): a set
      -- DEFERRED TO CONSTRUCTOR ROWS — "⊇ members ∪ ⋃ row(r)" for each row
      -- id r (an interned `r|<ctor>|<path>` key naming one payload position
      -- of one constructor, program-wide). Born at a destructure of a
      -- SYNTACTIC payload arrow (the scrutinee's type has no slot for it),
      -- resolved post-drain by `Monomorphize.settleRowRefs` from the
      -- COMPLETE union of every construction of that row. Joins: rows
      -- union, members union; ⊤ absorbs; an edge (`LsFrom`) meeting a row
      -- widens to ⊤ (edge kind) — the two deferrals do not compose.
    | LsRow (List Int) (List Int)


{-| Relation between two ascending member lists, decided in ONE merge-scan:
O(n+m), zero allocation, early exit to `SortedMixed` once both sides have
shown an exclusive element. `SortedSuper` = second ⊆ first (strictly);
`SortedSub` = first ⊆ second (strictly).
-}
type SortedRel
    = SortedEqual
    | SortedSuper
    | SortedSub
    | SortedMixed
