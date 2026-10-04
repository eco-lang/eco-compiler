module Compiler.Type.Vars exposing
    ( Variable, Point(..), PointCell(..), RootedVar
    , Descriptor, Content(..), SuperType(..), Mark(..)
    , FlatType(..), LambdaSet(..), SortedRel(..)
    )

{-| Many modules need to name a type variable, or read what the solver knows
about one, without running the solver. This module gives them the types for
that, apart from the `System.TypeCheck.IO` monad that threads the solver's
state, so they can depend on these types without depending on the monad.

It is pure data: it defines types and no functions. `System.TypeCheck.IO`
imports it, and the only compiler module whose types it uses is
`Compiler.Elm.ModuleName`, for the module a named type belongs to.

Type inference works on _points_. A point is a type variable, and the points
that unification has made equal are joined into one equivalence class by a
union-find structure. The _store_ holds one cell per point. Each class has one
root, and the root's cell carries the class's _descriptor_: what the solver
currently knows the type to be, which is its _content_, together with
bookkeeping for generalization and for graph traversals. `Variable` and `Point`
are two names for the same type.

A content is one of five kinds. A _flex_ variable is one that unification may
still bind to a type. A _rigid_ variable comes from a type annotation and is
never bound; unification can only bind a flex variable to it. Either kind may
carry a _super-type_, the constraint Elm expresses by naming a variable
`number`, `comparable`, `appendable` or `compappend`. A structure is a concrete
type, and it is _flat_: its children are points, not nested types, so unifying
two structures means unifying their child points. The remaining kinds are an
alias together with its expansion, and `Error`.

The last few types serve lambda-set specialization, which the monomorphization
solver (`Compiler.MonoSolver.*`) runs on stores of its own built from these same
types. A _lambda set_ is the set of function values that a function-typed value
can be, each named by an integer _member id_. In those stores an arrow that
carries a lambda set is a `FunL`, whose third point, the _set slot_, holds the
arrow's lambda set as a `LambdaSet1` content. The type checker builds neither.

@docs Variable, Point, PointCell, RootedVar
@docs Descriptor, Content, SuperType, Mark
@docs FlatType, LambdaSet, SortedRel

-}

import Compiler.Elm.ModuleName exposing (Canonical)
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Dict as CoreDict


{-| A type variable, which is a point in the union-find store.

This is a name for `Point`, not a new type, and the two are interchangeable.

-}
type alias Variable =
    Point


{-| A reference to one cell of the union-find store.

`Pt` carries the cell's index. A store numbers its points from 0 in the order
it makes them, so an index identifies a point only within the store that made
it. The index is visible to other modules, and `System.TypeCheck.IO.pointKey`
returns it for use as a key.

-}
type Point
    = Pt Int


{-| The contents of one cell of the union-find store: either the root of a
class or a link towards one.

`Root` carries the class's weight and its descriptor. The weight is the number
of points in the class, and `Compiler.Type.UnionFind` uses it to decide which of
two roots stays a root when their classes are joined. It is not the
descriptor's rank.

`Chain` carries the next point on the way to the root, which may itself be a
`Chain`. Only a root's cell holds a descriptor.

-}
type PointCell
    = Root Int Descriptor
    | Chain Point


{-| What the solver knows about one class of type variables, stored on its
root.

`rank` is the let-nesting depth the class belongs to, which generalization uses
to decide which variables it may quantify; `Compiler.Type.Type` names its
reserved values. `mark` is the stamp a graph traversal leaves on a class it has
visited. `copy` is used while a generalized type is instantiated, and holds the
copy already made of this class, so that a class reached twice is copied once.

-}
type alias Descriptor =
    { content : Content
    , rank : Int
    , mark : Mark
    , copy : Maybe Variable
    }


{-| What a class of type variables is known to be.

`FlexVar` is a variable that unification may still bind. Its name is `Nothing`
when it has none; `Compiler.Type.Type` writes generated names into such
variables when it converts solved types back.

`FlexSuper` is a flex variable constrained by a super-type, so it may be bound
only to types that satisfy that constraint.

`RigidVar` and `RigidSuper` are variables from a type annotation, with the
name written there. Unification never binds them to another type. It succeeds
against a `FlexVar`, against a `FlexSuper` only when the rigid variable is a
`RigidSuper` whose super-type is compatible, and against `Error`; in the first
two cases the flex variable takes on the rigid content. Against an alias the
outcome depends on argument order, since with the alias first its expansion is
unified with the rigid variable. Against another rigid variable or a structure
it fails.

`Structure` is a concrete type, as a `FlatType`.

`Alias` is a use of a type alias: the module that defines it, its name, each of
its parameter names paired with the argument given for it, and the point that
holds the type the alias expands to.

`Error` marks a class that unification or the occurs check has found
inconsistent. Unifying anything with it succeeds and leaves `Error`, so one
mistake produces one error report rather than many.

-}
type Content
    = FlexVar (Maybe String)
    | FlexSuper SuperType (Maybe String)
    | RigidVar String
    | RigidSuper SuperType String
    | Structure FlatType
    | Alias Canonical String (List ( String, Variable )) Variable
    | Error


{-| A constraint on what a type variable may stand for, which Elm expresses by
the variable's name.

`Number` admits `Int` and `Float`. `Comparable` admits the types the
comparison operators accept. `Appendable` admits the types `++` accepts.
`CompAppend` admits the types that are both comparable and appendable.

-}
type SuperType
    = Number
    | Comparable
    | Appendable
    | CompAppend


{-| A stamp that a traversal of the type graph writes on the descriptors it
visits, so that it can recognise a class it has already reached and stop on a
cyclic type.

`Compiler.Type.Type` defines the fixed marks and `nextMark`, which gives a mark
different from the one it is given.

-}
type Mark
    = Mark Int


{-| The root of a class, as it was after solving, together with the super-type
recorded in the root's content.

`super` is read from the root's `FlexSuper` or `RigidSuper` content, so it does
not depend on the name of any variable that refers to the root. `var` is a point
of the store it was read from, and has meaning only alongside that store.

-}
type alias RootedVar =
    { var : Variable
    , super : Maybe SuperType
    }


{-| A concrete type whose immediate children are points rather than types.

`App1` is a named type applied to its arguments: the module that defines it, its
name, and the arguments.

`Fun1` is a function type from its first point to its second.

`FunL` is a function type that also has a set slot, its third point. Only the
monomorphization solver builds it, and there the slot's content is either a flex
variable, while nothing is known yet, or a `LambdaSet1`. `Compiler.Type.Unify`
treats a `Fun1` as a `FunL` whose slot is unconstrained.

`EmptyRecord1` is the record type with no fields.

`Record1` is a record type: its fields, and the point for the rest of the
record, which may hold more fields; for a closed record that chain ends in
`EmptyRecord1`.

`Unit1` is the type `()`.

`Tuple1` is a tuple type of two or more elements: the first, the second, and the
rest.

`LambdaSet1` is the content of a set slot. It is not a type of values, and the
type checker's conversions back to types crash if they meet one anywhere but in
a `FunL`'s slot.

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


{-| A lambda set as it is held in a set slot of the monomorphization solver's
store.

`LsTop` is _top_, the set that admits any function value. Joining top with any
set gives top, and no join or slot write replaces a top with a smaller set.
Its `Int` records why the set was widened, as a provenance code, and does not
change what the set means; it carries no members and no sources.

`LsMembers` is a set of known member ids. Its list is ascending and has no
duplicates; the type does not enforce this, and the merges that join two sets
rely on it.

`LsFrom` is a set that also includes, besides its own members, every set held in
its source slots. Its members follow the same rule as those of `LsMembers`, but
may be empty. Its sources are set slots of the same store, and the list of them
is not empty. Sources are not followed when the edge is added or when two sets
are joined, only when the set is read back, by `Compiler.MonoSolver.Store` and
`Compiler.MonoSolver.LssInfer`. Only `Compiler.MonoSolver.Store` adds a
source, and it does not add a point that is already listed, though two listed
points may be, or later become, the same class.

Joining two lambda sets never fails. `Compiler.Type.Unify` states the join.

-}
type LambdaSet
    = LsTop Int
    | LsMembers (List Int)
    | LsFrom (List Int) (List Variable)


{-| How two ascending lists of member ids relate as sets, the result of
`System.TypeCheck.IO.classifySorted`.

`SortedEqual` means they hold the same ids. `SortedSuper` means the first
holds every id of the second and at least one more. `SortedSub` means the
second holds every id of the first and at least one more. `SortedMixed` means
each holds an id the other lacks.

The answer is meaningful only for lists that are ascending and have no
duplicates.

-}
type SortedRel
    = SortedEqual
    | SortedSuper
    | SortedSub
    | SortedMixed
