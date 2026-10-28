module Compiler.LocalOpt.Erased.Expression exposing
    ( Cycle
    , optimize, optimizePotentialTailCall
    , destructArgs
    )

{-| Code generation wants a smaller language than the one canonicalization
produces, and this module lowers one canonical expression into the type-erased
optimized AST of `Compiler.AST.Optimized`.

Four things happen during the lowering. Every global, kernel module, constructor
and record field the expression refers to is recorded in the `Names.Tracker` the
result is built in, which is how the caller learns what a definition depends on.
The variables a pattern binds (in function arguments, `let` destructuring and
`case` branches) are bound by _destructors_: each names one variable and the
_path_ (a chain of tuple, constructor, record-field and unbox steps from a root
variable) that reads its value. For a `case`, which branch matches is decided
by `Compiler.LocalOpt.Erased.Case`, which builds the decision tree.

The fourth job is tail calls. `optimizePotentialTailCall` lowers a named
function and, where the function calls itself in tail position with exactly as
many arguments as it has parameters, emits a `TailCall` instead of a `Call`, so
that the definition becomes a `TailDef` that can be compiled as a loop.

A _cycle_ is the set of top-level names whose references are emitted as
`VarCycle` instead of as global references; which names it holds is up to the
caller.


# Core Types

@docs Cycle


# Optimization

@docs optimize, optimizePotentialTailCall


# Helpers

@docs destructArgs

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Erased.Case as Case
import Compiler.LocalOpt.Erased.Names as Names
import Compiler.Reporting.Annotation as A
import Data.Map
import Data.Set as EverySet exposing (EverySet)
import Utils.Main as Utils



-- ====== OPTIMIZE ======


{-| The set of top-level names, in the module being optimized, that are
referenced as `VarCycle` rather than registered as global dependencies.
-}
type alias Cycle =
    EverySet String Name.Name


{-| Lowers a canonical expression, recording in the tracker every dependency
and record field it uses.

A top-level name in `cycle` becomes a `VarCycle`; any other top-level or foreign
name, and every operator, becomes a registered `VarGlobal`. Negation and binary
operators become calls of their functions. A `case` whose scrutinee lowers to a
local variable matches on that variable; otherwise the scrutinee is bound to a
fresh name by a `Let` around the case. Characters, lists, tuples and unit add a
dependency on a kernel module (`Utils`, or `List` for lists).

Tail calls are not looked for here, except in the definition of a `let rec`
of one definition, which goes through `optimizePotentialTailCall`.

-}
optimize : Cycle -> Can.Expr -> Names.Tracker Opt.Expr
optimize cycle (A.At region exprInfo) =
    case exprInfo.node of
        Can.VarLocal name ->
            Names.pure (Opt.TrackedVarLocal region name)

        Can.VarTopLevel home name ->
            if EverySet.member identity name cycle then
                Names.pure (Opt.VarCycle region home name)

            else
                Names.registerGlobal region home name

        Can.VarKernel kernelPrefix home name ->
            Names.registerKernel kernelPrefix home (Opt.VarKernel region kernelPrefix home name)

        Can.VarForeign home name _ ->
            Names.registerGlobal region home name

        Can.VarCtor opts home name index _ ->
            Names.registerCtor region home (A.At region name) index opts

        Can.VarDebug home name _ ->
            Names.registerDebug name home region

        Can.VarOperator _ home name _ ->
            Names.registerGlobal region home name

        Can.Chr chr ->
            Names.registerKernel "Elm" Name.utils (Opt.Chr region chr)

        Can.Str str ->
            Names.pure (Opt.Str region str)

        Can.Int int ->
            Names.pure (Opt.Int region int)

        Can.Float float ->
            Names.pure (Opt.Float region float)

        Can.List entries ->
            Names.traverse (optimize cycle) entries
                |> Names.andThen (Names.registerKernel "Elm" Name.list << Opt.List region)

        Can.Negate expr ->
            Names.registerGlobal region ModuleName.basics Name.negate
                |> Names.andThen
                    (\func ->
                        optimize cycle expr
                            |> Names.map
                                (\arg ->
                                    Opt.Call region func [ arg ]
                                )
                    )

        Can.Binop _ home name _ left right ->
            Names.registerGlobal region home name
                |> Names.andThen
                    (\optFunc ->
                        optimize cycle left
                            |> Names.andThen
                                (\optLeft ->
                                    optimize cycle right
                                        |> Names.map
                                            (\optRight ->
                                                Opt.Call region optFunc [ optLeft, optRight ]
                                            )
                                )
                    )

        Can.Lambda args body ->
            destructArgs args
                |> Names.andThen
                    (\( argNames, destructors ) ->
                        optimize cycle body
                            |> Names.map
                                (\obody ->
                                    Opt.TrackedFunction argNames (List.foldr Opt.Destruct obody destructors)
                                )
                    )

        Can.Call func args ->
            optimize cycle func
                |> Names.andThen
                    (\optimizeExpr ->
                        Names.traverse (optimize cycle) args
                            |> Names.map (Opt.Call region optimizeExpr)
                    )

        Can.If branches finally ->
            let
                optimizeBranch : ( Can.Expr, Can.Expr ) -> Names.Tracker ( Opt.Expr, Opt.Expr )
                optimizeBranch ( condition, branch ) =
                    optimize cycle condition
                        |> Names.andThen
                            (\expr ->
                                optimize cycle branch
                                    |> Names.map (Tuple.pair expr)
                            )
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\optimizedBranches ->
                        optimize cycle finally
                            |> Names.map (Opt.If optimizedBranches)
                    )

        Can.Let def body ->
            optimize cycle body
                |> Names.andThen (optimizeDef cycle def)

        Can.LetRec defs body ->
            case defs of
                [ def ] ->
                    optimizePotentialTailCallDef cycle def
                        |> Names.andThen
                            (\tailCallDef ->
                                optimize cycle body
                                    |> Names.map (Opt.Let tailCallDef)
                            )

                _ ->
                    List.foldl
                        (\def bod ->
                            Names.andThen (optimizeDef cycle def) bod
                        )
                        (optimize cycle body)
                        defs

        Can.LetDestruct pattern expr body ->
            destruct pattern
                |> Names.andThen
                    (\( A.At nameRegion name, destructs ) ->
                        optimize cycle expr
                            |> Names.andThen
                                (\oexpr ->
                                    optimize cycle body
                                        |> Names.map
                                            (\obody ->
                                                Opt.Let (Opt.Def nameRegion name oexpr) (List.foldr Opt.Destruct obody destructs)
                                            )
                                )
                    )

        Can.Case expr branches ->
            let
                optimizeBranch : Name.Name -> Can.CaseBranch -> Names.Tracker ( Can.Pattern, Opt.Expr )
                optimizeBranch root (Can.CaseBranch pattern branch) =
                    destructCase root pattern
                        |> Names.andThen
                            (\destructors ->
                                optimize cycle branch
                                    |> Names.map
                                        (\obranch ->
                                            ( pattern, List.foldr Opt.Destruct obranch destructors )
                                        )
                            )
            in
            Names.generate
                |> Names.andThen
                    (\temp ->
                        optimize cycle expr
                            |> Names.andThen
                                (\oexpr ->
                                    case oexpr of
                                        Opt.VarLocal root ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (Case.optimize temp root)

                                        Opt.TrackedVarLocal _ root ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (Case.optimize temp root)

                                        _ ->
                                            Names.traverse (optimizeBranch temp) branches
                                                |> Names.map
                                                    (\obranches ->
                                                        Opt.Let (Opt.Def region temp oexpr) (Case.optimize temp temp obranches)
                                                    )
                                )
                    )

        Can.Accessor field ->
            Names.registerField field (Opt.Accessor region field)

        Can.Access record (A.At fieldPosition field) ->
            optimize cycle record
                |> Names.andThen
                    (\optRecord ->
                        Names.registerField field (Opt.Access optRecord fieldPosition field)
                    )

        Can.Update record updates ->
            Names.mapTraverse A.toValue (optimizeUpdate cycle) updates
                |> Names.andThen
                    (\optUpdates ->
                        optimize cycle record
                            |> Names.andThen
                                (\optRecord ->
                                    Names.registerFieldDict (Utils.dictMapKeys A.toValue updates) (Opt.Update region optRecord optUpdates)
                                )
                    )

        Can.Record fields ->
            Names.mapTraverse A.toValue (optimize cycle) fields
                |> Names.andThen
                    (\optFields ->
                        Names.registerFieldDict (Utils.dictMapKeys A.toValue fields) (Opt.TrackedRecord region optFields)
                    )

        Can.Unit ->
            Names.registerKernel "Elm" Name.utils Opt.Unit

        Can.Tuple a b cs ->
            optimize cycle a
                |> Names.andThen
                    (\optA ->
                        optimize cycle b
                            |> Names.andThen
                                (\optB ->
                                    Names.traverse (optimize cycle) cs
                                        |> Names.andThen (Names.registerKernel "Elm" Name.utils << Opt.Tuple region optA optB)
                                )
                    )

        Can.Shader src (Shader.Types attributes uniforms _) ->
            Names.pure (Opt.Shader src (EverySet.fromList identity (Data.Map.keys attributes)) (EverySet.fromList identity (Data.Map.keys uniforms)))



-- ====== UPDATE ======


{-| Lowers the new value of one field in a record update.
-}
optimizeUpdate : Cycle -> Can.FieldUpdate -> Names.Tracker Opt.Expr
optimizeUpdate cycle (Can.FieldUpdate _ expr) =
    optimize cycle expr



-- ====== DEFINITION ======


{-| Wraps `body` in a `Let` binding the lowered local definition `def`.
-}
optimizeDef : Cycle -> Can.Def -> Opt.Expr -> Names.Tracker Opt.Expr
optimizeDef cycle def body =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizeDefHelp cycle region name args expr body

        Can.TypedDef (A.At region name) _ typedArgs expr _ ->
            optimizeDefHelp cycle region name (List.map Tuple.first typedArgs) expr body


{-| Wraps `body` in a `Let` binding `name` to the lowered `expr`, or, when
there are `args`, to a function of them whose pattern arguments are destructured
at the start of its body.
-}
optimizeDefHelp : Cycle -> A.Region -> Name.Name -> List Can.Pattern -> Can.Expr -> Opt.Expr -> Names.Tracker Opt.Expr
optimizeDefHelp cycle region name args expr body =
    case args of
        [] ->
            optimize cycle expr
                |> Names.map (\oexpr -> Opt.Let (Opt.Def region name oexpr) body)

        _ ->
            optimize cycle expr
                |> Names.andThen
                    (\oexpr ->
                        destructArgs args
                            |> Names.map
                                (\( argNames, destructors ) ->
                                    let
                                        ofunc : Opt.Expr
                                        ofunc =
                                            Opt.TrackedFunction argNames (List.foldr Opt.Destruct oexpr destructors)
                                    in
                                    Opt.Let (Opt.Def region name ofunc) body
                                )
                    )



-- ====== DESTRUCTURING ======


{-| Returns one parameter name per argument pattern, and the destructors
that bind the variables inside those patterns.

A variable pattern keeps its own name and an `as` pattern takes its alias name;
any other pattern gets a fresh generated name. The destructors are in argument
order and are meant to be wrapped, in that order, around the function body.

-}
destructArgs : List Can.Pattern -> Names.Tracker ( List (A.Located Name.Name), List Opt.Destructor )
destructArgs args =
    Names.traverse destruct args
        |> Names.map List.unzip
        |> Names.map
            (\( argNames, destructorLists ) ->
                ( argNames, List.concat destructorLists )
            )


{-| Returns the destructors that bind the variables of a case branch's
pattern, reading from the variable `rootName`.
-}
destructCase : Name.Name -> Can.Pattern -> Names.Tracker (List Opt.Destructor)
destructCase rootName pattern =
    destructHelp (Opt.Root rootName) pattern []
        |> Names.map List.reverse


{-| Returns the name a pattern's value is bound to, and the destructors for
the variables inside it.

The name is the pattern's own for a variable, the alias for an `as` pattern,
and a fresh generated name otherwise.

-}
destruct : Can.Pattern -> Names.Tracker ( A.Located Name.Name, List Opt.Destructor )
destruct ((A.At region patternInfo) as pattern) =
    case patternInfo.node of
        Can.PVar name ->
            Names.pure ( A.At region name, [] )

        Can.PAlias subPattern name ->
            destructHelp (Opt.Root name) subPattern []
                |> Names.map (\revDs -> ( A.At region name, List.reverse revDs ))

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        destructHelp (Opt.Root name) pattern []
                            |> Names.map
                                (\revDs ->
                                    ( A.At region name, List.reverse revDs )
                                )
                    )


{-| Adds to `revDs`, which is in reverse order, the destructors for every
variable bound by a pattern whose value is at `path`.

Literal, wildcard and unit patterns bind nothing. A record pattern also counts
each of its fields as used. A tuple of more than three elements reads its extra
elements from the `cs` field. A constructor with one argument reads it by index
0, or through `Unbox` when its type's options are `Unbox`. A record's fields are
read directly from `path`. A tuple, list or cons pattern, or a constructor with
several arguments, whose value is nested below the root is first bound to a
fresh name and its parts are read from that.

-}
destructHelp : Opt.Path -> Can.Pattern -> List Opt.Destructor -> Names.Tracker (List Opt.Destructor)
destructHelp path (A.At region patternInfo) revDs =
    case patternInfo.node of
        Can.PAnything ->
            Names.pure revDs

        Can.PVar name ->
            Names.pure (Opt.Destructor name path :: revDs)

        Can.PRecord fields ->
            let
                toDestruct : Name.Name -> Opt.Destructor
                toDestruct name =
                    Opt.Destructor name (Opt.Field name path)
            in
            Names.registerFieldList fields (List.map toDestruct fields ++ revDs)

        Can.PAlias subPattern name ->
            (Opt.Destructor name path :: revDs) |> destructHelp (Opt.Root name) subPattern

        Can.PUnit ->
            Names.pure revDs

        Can.PTuple a b [] ->
            destructTwo path a b revDs

        Can.PTuple a b [ c ] ->
            case path of
                Opt.Root _ ->
                    destructHelp (Opt.Index Index.first path) a revDs
                        |> Names.andThen (destructHelp (Opt.Index Index.second path) b)
                        |> Names.andThen (destructHelp (Opt.Index Index.third path) c)

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\name ->
                                let
                                    newRoot : Opt.Path
                                    newRoot =
                                        Opt.Root name
                                in
                                destructHelp (Opt.Index Index.first newRoot) a (Opt.Destructor name path :: revDs)
                                    |> Names.andThen (destructHelp (Opt.Index Index.second newRoot) b)
                                    |> Names.andThen (destructHelp (Opt.Index Index.third newRoot) c)
                            )

        Can.PTuple a b cs ->
            case path of
                Opt.Root _ ->
                    List.foldl (\( index, arg ) -> Names.andThen (destructHelp (Opt.ArrayIndex index (Opt.Field "cs" path)) arg))
                        (destructHelp (Opt.Index Index.first path) a revDs
                            |> Names.andThen (destructHelp (Opt.Index Index.second path) b)
                        )
                        (List.indexedMap Tuple.pair cs)

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\name ->
                                let
                                    newRoot : Opt.Path
                                    newRoot =
                                        Opt.Root name
                                in
                                List.foldl (\( index, arg ) -> Names.andThen (destructHelp (Opt.ArrayIndex index (Opt.Field "cs" newRoot)) arg))
                                    (destructHelp (Opt.Index Index.first newRoot) a (Opt.Destructor name path :: revDs)
                                        |> Names.andThen (destructHelp (Opt.Index Index.second newRoot) b)
                                    )
                                    (List.indexedMap Tuple.pair cs)
                            )

        Can.PList [] ->
            Names.pure revDs

        Can.PList (hd :: tl) ->
            -- The rest of the list is a synthesized pattern, so it has no node id; -1 stands in.
            destructTwo path hd (A.At region { id = -1, node = Can.PList tl }) revDs

        Can.PCons hd tl ->
            destructTwo path hd tl revDs

        Can.PChr _ ->
            Names.pure revDs

        Can.PStr _ _ ->
            Names.pure revDs

        Can.PInt _ ->
            Names.pure revDs

        Can.PBool _ _ ->
            Names.pure revDs

        Can.PCtor { union, args } ->
            case args of
                [ Can.PatternCtorArg _ _ arg ] ->
                    let
                        (Can.Union unionData) =
                            union
                    in
                    case unionData.opts of
                        Can.Normal ->
                            destructHelp (Opt.Index Index.first path) arg revDs

                        Can.Unbox ->
                            destructHelp (Opt.Unbox path) arg revDs

                        Can.Enum ->
                            destructHelp (Opt.Index Index.first path) arg revDs

                _ ->
                    case path of
                        Opt.Root _ ->
                            List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg path revDs_ arg))
                                (Names.pure revDs)
                                args

                        _ ->
                            Names.generate
                                |> Names.andThen
                                    (\name ->
                                        List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg (Opt.Root name) revDs_ arg))
                                            (Names.pure (Opt.Destructor name path :: revDs))
                                            args
                                    )


{-| Adds to `revDs` the destructors for two patterns at indexes 0 and 1 of the
value at `path`, binding that value to a fresh name first unless `path` is a
root.
-}
destructTwo : Opt.Path -> Can.Pattern -> Can.Pattern -> List Opt.Destructor -> Names.Tracker (List Opt.Destructor)
destructTwo path a b revDs =
    case path of
        Opt.Root _ ->
            destructHelp (Opt.Index Index.first path) a revDs
                |> Names.andThen (destructHelp (Opt.Index Index.second path) b)

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        let
                            newRoot : Opt.Path
                            newRoot =
                                Opt.Root name
                        in
                        destructHelp (Opt.Index Index.first newRoot) a (Opt.Destructor name path :: revDs)
                            |> Names.andThen (destructHelp (Opt.Index Index.second newRoot) b)
                    )


{-| Adds to `revDs` the destructors for one constructor argument, read at its
index in the value at `path`.
-}
destructCtorArg : Opt.Path -> List Opt.Destructor -> Can.PatternCtorArg -> Names.Tracker (List Opt.Destructor)
destructCtorArg path revDs (Can.PatternCtorArg index _ arg) =
    destructHelp (Opt.Index index path) arg revDs



-- ====== TAIL CALL ======


{-| Lowers a local definition as `optimizePotentialTailCall` does, taking the
name, arguments and body from `def`.
-}
optimizePotentialTailCallDef : Cycle -> Can.Def -> Names.Tracker Opt.Def
optimizePotentialTailCallDef cycle def =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizePotentialTailCall cycle region name args expr

        Can.TypedDef (A.At region name) _ typedArgs expr _ ->
            optimizePotentialTailCall cycle region name (List.map Tuple.first typedArgs) expr


{-| Lowers the definition of the function `name`, as a `TailDef` if it calls
itself in tail position and as a `Def` of a function otherwise.

A call is a tail self-call when its callee is `name` itself (as a local or a
top-level name) and it passes exactly as many arguments as there are `args`; it
becomes a `TailCall`. Tail position is followed through `if` branches, `case`
branches, `let`, `let` destructuring and a `let rec` of one definition, but not
into the body of a `let rec` of several definitions. A zero-argument definition
still comes back as a function of no parameters.

-}
optimizePotentialTailCall : Cycle -> A.Region -> Name.Name -> List Can.Pattern -> Can.Expr -> Names.Tracker Opt.Def
optimizePotentialTailCall cycle region name args expr =
    destructArgs args
        |> Names.andThen
            (\( argNames, destructors ) ->
                optimizeTail cycle name argNames expr
                    |> Names.map (toTailDef region name argNames destructors)
            )


{-| Lowers `locExpr`, the body or a tail-position part of the body of the
function `rootName` with parameters `argNames`, turning saturated self-calls in
tail position into `TailCall`s.
-}
optimizeTail : Cycle -> Name.Name -> List (A.Located Name.Name) -> Can.Expr -> Names.Tracker Opt.Expr
optimizeTail cycle rootName argNames ((A.At region exprInfo) as locExpr) =
    case exprInfo.node of
        Can.Call func args ->
            Names.traverse (optimize cycle) args
                |> Names.andThen
                    (\oargs ->
                        let
                            isMatchingName : Bool
                            isMatchingName =
                                case (A.toValue func).node of
                                    Can.VarLocal name ->
                                        rootName == name

                                    Can.VarTopLevel _ name ->
                                        rootName == name

                                    _ ->
                                        False
                        in
                        if isMatchingName then
                            case Index.indexedZipWith (\_ a b -> ( A.toValue a, b )) argNames oargs of
                                Index.LengthMatch pairs ->
                                    Names.pure (Opt.TailCall rootName pairs)

                                Index.LengthMismatch _ _ ->
                                    optimize cycle func
                                        |> Names.map (\ofunc -> Opt.Call region ofunc oargs)

                        else
                            optimize cycle func
                                |> Names.map (\ofunc -> Opt.Call region ofunc oargs)
                    )

        Can.If branches finally ->
            let
                optimizeBranch : ( Can.Expr, Can.Expr ) -> Names.Tracker ( Opt.Expr, Opt.Expr )
                optimizeBranch ( condition, branch ) =
                    optimize cycle condition
                        |> Names.andThen
                            (\optimizeCondition ->
                                optimizeTail cycle rootName argNames branch
                                    |> Names.map (Tuple.pair optimizeCondition)
                            )
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\obranches ->
                        optimizeTail cycle rootName argNames finally
                            |> Names.map (Opt.If obranches)
                    )

        Can.Let def body ->
            optimizeTail cycle rootName argNames body
                |> Names.andThen (optimizeDef cycle def)

        Can.LetRec defs body ->
            case defs of
                [ def ] ->
                    optimizePotentialTailCallDef cycle def
                        |> Names.andThen
                            (\obody ->
                                optimizeTail cycle rootName argNames body
                                    |> Names.map (Opt.Let obody)
                            )

                _ ->
                    List.foldl
                        (\def bod ->
                            Names.andThen (optimizeDef cycle def) bod
                        )
                        (optimizeTail cycle rootName argNames body)
                        defs

        Can.LetDestruct pattern expr body ->
            destruct pattern
                |> Names.andThen
                    (\( A.At dregion dname, destructors ) ->
                        optimize cycle expr
                            |> Names.andThen
                                (\oexpr ->
                                    optimizeTail cycle rootName argNames body
                                        |> Names.map
                                            (\obody ->
                                                Opt.Let (Opt.Def dregion dname oexpr) (List.foldr Opt.Destruct obody destructors)
                                            )
                                )
                    )

        Can.Case expr branches ->
            let
                optimizeBranch : Name.Name -> Can.CaseBranch -> Names.Tracker ( Can.Pattern, Opt.Expr )
                optimizeBranch root (Can.CaseBranch pattern branch) =
                    destructCase root pattern
                        |> Names.andThen
                            (\destructors ->
                                optimizeTail cycle rootName argNames branch
                                    |> Names.map
                                        (\obranch ->
                                            ( pattern, List.foldr Opt.Destruct obranch destructors )
                                        )
                            )
            in
            Names.generate
                |> Names.andThen
                    (\temp ->
                        optimize cycle expr
                            |> Names.andThen
                                (\oexpr ->
                                    case oexpr of
                                        Opt.VarLocal root ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (Case.optimize temp root)

                                        Opt.TrackedVarLocal _ root ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (Case.optimize temp root)

                                        _ ->
                                            Names.traverse (optimizeBranch temp) branches
                                                |> Names.map
                                                    (\obranches ->
                                                        Opt.Let (Opt.Def region temp oexpr) (Case.optimize temp temp obranches)
                                                    )
                                )
                    )

        _ ->
            optimize cycle locExpr



-- ====== DETECT TAIL CALLS ======


{-| Builds a `TailDef` if the lowered body contains a tail call, and otherwise
a `Def` of a function; either way the argument destructors wrap the body.
-}
toTailDef : A.Region -> Name.Name -> List (A.Located Name.Name) -> List Opt.Destructor -> Opt.Expr -> Opt.Def
toTailDef region name argNames destructors body =
    if hasTailCall body then
        Opt.TailDef region name argNames (List.foldr Opt.Destruct body destructors)

    else
        Opt.Def region name (Opt.TrackedFunction argNames (List.foldr Opt.Destruct body destructors))


{-| Reports whether an expression contains a `TailCall` in tail position,
looking through `if`, `let`, destructuring and every branch of a `case`, whether
or not the branch is reachable.
-}
hasTailCall : Opt.Expr -> Bool
hasTailCall expression =
    case expression of
        Opt.TailCall _ _ ->
            True

        Opt.If branches finally ->
            hasTailCall finally || List.any (Tuple.second >> hasTailCall) branches

        Opt.Let _ body ->
            hasTailCall body

        Opt.Destruct _ body ->
            hasTailCall body

        Opt.Case _ _ decider jumps ->
            decidecHasTailCall decider || List.any (Tuple.second >> hasTailCall) jumps

        _ ->
            False


{-| Reports whether any branch inlined into a decision tree contains a tail
call.
-}
decidecHasTailCall : Opt.Decider Opt.Choice -> Bool
decidecHasTailCall decider =
    case decider of
        Opt.Leaf choice ->
            case choice of
                Opt.Inline expr ->
                    hasTailCall expr

                Opt.Jump _ ->
                    False

        Opt.Chain _ success failure ->
            decidecHasTailCall success || decidecHasTailCall failure

        Opt.FanOut _ tests fallback ->
            decidecHasTailCall fallback || List.any (Tuple.second >> decidecHasTailCall) tests
