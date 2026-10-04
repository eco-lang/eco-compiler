module Compiler.Eco.Config exposing
    ( EcoConfig, InlineConfig, BytesFusionConfig, LogicalTypesConfig
    , default, decoder, hash, clamp
    , BorrowConfig, BorrowReify(..), CafHoistConfig, CafMemoConfig, CseConfig, GcConfig, ListConfig, LssConfig, LssStampConfig, MonoConfig, MonoEngine(..), SpecLimits, defaultLimits, defaultLss, monoEngineFromString
    )

{-| The compiler's tunable settings live here: their defaults, the decoder for
a project's `eco-config.json`, and the key that tells the build cache which
settings an artifact was built with.

Most settings switch one optimization or analysis on or off, or set one of its
limits. They are grouped by the part of the compiler that reads them: the
inliners (`InlineConfig`), monomorphization (`MonoConfig`, which holds the
lambda-set settings `LssConfig` and the watchdog limits `SpecLimits`), CAF
memoization (`CafMemoConfig`), borrow inference (`BorrowConfig`), chunked lists
(`ListConfig`), common-subexpression elimination (`CseConfig`), the garbage
collection before linking (`GcConfig`), bytes fusion (`BytesFusionConfig`),
the logical-type descriptions (`LogicalTypesConfig`), and a set of switches on
`EcoConfig` itself, most of them each gating one rewrite in the MLIR code
generator.

This module does no IO. Reading the file, and the `ECO_*` environment
variables that override individual settings, are in `Builder.Eco.Config`.

Two facts shape the module.

The first is that a setting either can change the code the compiler emits or
it cannot. A setting that can is _artifact-affecting_, and `hash` has a token
for it, so that an artifact built under one value is not reused under another.
A setting that changes no generated code, such as one that prints a report on
stderr, runs a validator, decides whether a compile fails, or asks for the
pre-link collection, is _output-only_ and gets no token, so turning it on
keeps the cache. The docstrings below say which each setting is. Four
settings are the exception: the censuses `qCensus` and `arrowCensus` in
`LssConfig` and `census` in `LssStampConfig`, and `oracleOpt` in
`BorrowConfig`, change no generated code, yet each adds a token when on.

The second is that the file is a partial override of `default`. Every key is
optional, a missing key takes its value from `default`, and unknown keys are
ignored. `decoder` lists the exceptions: four settings cannot be set from the
file at all, and a `mono` object without an `engine` key does not select the
default engine.

Each block's decoder applies a function, the record's constructor or a lambda,
to one key after another, so the order of its `D.apply` lines must follow the
order of that function's parameters. Two of the same type listed in the wrong
order swap their values and still compile.

@docs EcoConfig, InlineConfig, BytesFusionConfig, LogicalTypesConfig
@docs default, decoder, hash, clamp
@docs BorrowConfig, BorrowReify, CafHoistConfig, CafMemoConfig, CseConfig, GcConfig, ListConfig, LssConfig, LssStampConfig, MonoConfig, MonoEngine, SpecLimits, defaultLimits, defaultLss, monoEngineFromString

-}

import Compiler.Json.Decode as D


{-| The complete set of settings a build runs with.

The fields holding records group the settings of one pass or one part of the
back end, and each record type says what its settings do. Of the other fields,
the twelve `Bool` switches from `aggPromote` to `callPurityAttrs` each gate one
rewrite in the MLIR code generator; all twelve are on in `default`, and each
puts a token in `hash` when on.

`aggPromote` builds let-bound tuples and constructor values that do not escape
as aggregates (`eco.make.*` ops). `ctorInline` builds the value of a saturated
constructor call with fields in the caller, instead of calling the
constructor's function; the value is still allocated on the heap.
`sretResults` gives a function that returns a tuple it builds itself a worker
that returns the tuple's fields as separate results. `sretFresh` and
`sretTailFuncs` widen which functions qualify for that, and do nothing while
`sretResults` is off. `psplitParams` gives a function whose tuple or
single-constructor parameter is used only through projections a worker that
takes the fields instead.

`stringLengthOp`, `appendSplit`, `stringOrderIntrinsic` and `valueEq` each let
a kernel call be lowered to an MLIR op instead: string length, string or list
append, string ordering comparisons, and structural equality of two boxed
values. `valueEq` also applies to the tests of string-literal patterns.

`kernelGcLeaf` marks the declarations of kernels that cannot trigger garbage
collection with `eco.gc_leaf`, and `callPurityAttrs` marks direct calls to
kernels whose calls may be dropped with `eco.cse_safe`.

`constThunks` is a level, not a switch. At 0 no constant thunk is folded into
the places that reference it; 1 and 2 are the levels that
`Compiler.Generate.MLIR.ConstThunks` defines. It has a token whenever it is
above 0. `constThunksReport` prints a census of constant thunks on stderr and
has no token.

-}
type alias EcoConfig =
    { inline : InlineConfig
    , bytesFusion : BytesFusionConfig
    , logicalTypes : LogicalTypesConfig
    , cafMemo : CafMemoConfig
    , mono : MonoConfig
    , borrow : BorrowConfig
    , list : ListConfig
    , aggPromote : Bool
    , ctorInline : Bool
    , sretResults : Bool
    , psplitParams : Bool
    , sretFresh : Bool
    , sretTailFuncs : Bool
    , stringLengthOp : Bool
    , appendSplit : Bool
    , stringOrderIntrinsic : Bool
    , valueEq : Bool
    , kernelGcLeaf : Bool
    , callPurityAttrs : Bool
    , constThunks : Int
    , constThunksReport : Bool
    , cse : CseConfig
    , gc : GcConfig
    }


{-| The settings of the full garbage collection the compiler asks for just
before the native back end lowers and links the program (`Builder.GcPoints`).

`preLink` asks for the collection and is on by default; `report` prints a line
on stderr for it. Neither has a token in `hash`.

-}
type alias GcConfig =
    { preLink : Bool
    , report : Bool
    }


{-| The settings of common-subexpression elimination over the monomorphized
program (`Compiler.GlobalOpt.MonoCse`), which binds a repeated pure call once
and reuses the result.

`minCost` is the cost below which a repeated expression is not worth a binding,
and `maxPerDef` caps the groups of repeats merged in one definition. `report`
prints a census on stderr and cannot be set from the file.

`enabled` is off by default. When it is on, `hash` gets `cse=1`, and a token
for each of the two limits that differs from `default`. `report` has no token.

-}
type alias CseConfig =
    { enabled : Bool
    , report : Bool
    , minCost : Int
    , maxPerDef : Int
    }


{-| The settings of the chunked list representation and of the list rewrites
built on it.

`chunks`, on by default, makes code generation mark the program's `main` so
that the back end treats lists as chunked, rewrites some elm/core `List`
specializations into direct kernel calls, and keeps those functions from being
inlined. `consIntrinsic` lets a saturated `x :: xs` be lowered to an
`eco.construct.list` op instead of a kernel call, where the head's types allow
it. `mapTemplate`, off by default,
replaces the body of each licensed `List.map` specialization with an
`eco.list.map` op; `Compiler.GlobalOpt.MapTemplate` decides which are licensed,
and it licenses none unless `chunks` is also on. `report` prints a census of
recognized list combinators on stderr and cannot be set from the file.

`chunks`, `consIntrinsic` and `mapTemplate` each have a token in `hash` when
on. `report` has none.

-}
type alias ListConfig =
    { chunks : Bool
    , consIntrinsic : Bool
    , mapTemplate : Bool
    , report : Bool
    }


{-| The settings of borrow inference (`Compiler.GlobalOpt.Borrow`), an analysis
of which function parameters are only borrowed.

`enabled` lets the analysis run, at the end of
`Compiler.GlobalOpt.MonoGlobalOptimize`, before CSE and the CAF passes. It runs
only when `report`, `validate` or `reify = RRc` is also on, and it returns the
program unchanged, in both `BorrowReify` modes; its products are a census and
checks, under `report` and `validate`. `oracleOpt` derives the analysis's
facts when MLIR is generated, and keeps the lambda-set member origins they
need through global optimization.

`oracleOpt` is the only borrow setting with a token in `hash` (`bopt=1`, when
on). The token keys the cache on the setting; it does not mean the emitted
code differs.

-}
type alias BorrowConfig =
    { enabled : Bool
    , reify : BorrowReify
    , report : Bool
    , validate : Bool
    , oracleOpt : Bool
    }


{-| How borrow inference applies its results to the program.

Under both modes the program is left as it was. `ROff` is the default.
`RRc` differs only in that, while `enabled` is on, it makes the analysis run
even when neither `report` nor `validate` is on. In the file it is the string
`"off"` or `"rc"`.

-}
type BorrowReify
    = ROff
    | RRc


{-| Which monomorphizer turns the typed program into specialized code.

`EngineSubst` is the dictionary-substitution engine of
`Compiler.Monomorphize.Monomorphize`, and runs without lambda-set
specialization.

`EngineSolver` is the solver-based engine of `Compiler.MonoSolver.Monomorphize`,
and the one `default` selects. It is the only engine that reads `LssConfig`.

`EngineDiff` runs both, the solver with LSS off and both with `defaultLimits`,
and fails unless their outputs match. On a match it returns the substitution
engine's output.

-}
type MonoEngine
    = EngineSubst
    | EngineSolver
    | EngineDiff


{-| The settings of monomorphization: which engine runs, the LSS settings the
solver engine reads, and the watchdog limits.

`diffDump` and `validate` cannot be set from the file, and neither has a token
in `hash`. `diffDump` adds the first differing node to the error `EngineDiff`
gives on a mismatch. `validate` runs validators on the program before and
after monomorphization and fails the compile on a violation.

-}
type alias MonoConfig =
    { engine : MonoEngine
    , diffDump : Bool
    , validate : Bool
    , lss : LssConfig
    , limits : SpecLimits
    }


{-| The watchdog limits of monomorphization. A specialization that exceeds one
makes monomorphization fail with an error naming the global.

`specTypeNodes` bounds the size of one specialization's type, in type nodes.
`specBreadth` bounds the number of specializations created for one global. A
limit of zero or less is no limit. No limit has a token in `hash`.

-}
type alias SpecLimits =
    { specTypeNodes : Int
    , specBreadth : Int
    }


{-| The watchdog limits of `default`, and the fallback for each key missing
from a `mono.limits` object.
-}
defaultLimits : SpecLimits
defaultLimits =
    { specTypeNodes = 400000
    , specBreadth = 50000
    }


{-| The settings of lambda-set specialization (_LSS_). With LSS, the
solver-based monomorphizer tracks, for each function-typed position, the set of
functions that can reach it, so that a call through that position can be
specialized for the set.

`enabled` switches LSS as a whole. `maxSetSize` is the largest set kept as a
set: a larger one widens to "unknown". `maxSpecsPerGlobal` bounds the
specializations of one global; past it, a new demand is keyed by its type with
its sets widened. For both, zero or less means no limit, which is the default.
These three are artifact-affecting: `enabled` has the token `lss=1` when on,
and each limit a token when it differs from `defaultLss`.

`report` prints an LSS census on stderr and has no token. `qCensus` records the
set constraints the solver emits and checks them. `arrowCensus` counts which
function-typed positions are applied to an argument; its counts need `report`
too. Neither changes generated code, but each has a token when on.

-}
type alias LssConfig =
    { enabled : Bool
    , maxSetSize : Int
    , maxSpecsPerGlobal : Int
    , report : Bool
    , qCensus : Bool
    , arrowCensus : Bool
    , stamp : LssStampConfig
    }


{-| The settings of instance qualification, and the switch for ABI cloning's
per-site census. The solver translates a let-bound function once per instance,
and qualification tags the lambdas of every instance after the first with that
instance's ordinal, so that two instances' different bodies do not share one
member id.

`maxInstances` caps the ordinals that are tagged: an instance at or past the
cap shares its enclosing id. `1` tags nothing, and zero or less is no cap. It
has a token in `hash` when it differs from `defaultLss`.

`census` makes ABI cloning collect its per-call-site census tables. It changes
no generated code, but has a token when on.

In the file, both keys are read from the `mono.lss` object itself, as
`instanceQualMaxInstances` and `census`.

-}
type alias LssStampConfig =
    { maxInstances : Int
    , census : Bool
    }


{-| The LSS settings of `default`, and the fallback for each key missing from a
`mono.lss` object: LSS on, no limit on set size or on specializations per
global, instance qualification capped at 8, and every census off.
-}
defaultLss : LssConfig
defaultLss =
    { enabled = True
    , maxSetSize = 0
    , maxSpecsPerGlobal = 0
    , report = False
    , qCensus = False
    , arrowCensus = False
    , stamp = { maxInstances = 8, census = False }
    }


{-| The settings of the inliners, and of the two rewrites that run before
monomorphization, ahead of the pre-monomorphization inliner.

`preMono` and `postMono` switch the two inliners: `InlineSimplify`, which
works before monomorphization and is off by default, and `MonoInlineSimplify`,
which works after it. Each has its own size budget and number of rounds:
`preMonoThreshold` and `preMonoFixpointIterations` for the first,
`postMonoThreshold` and `postMonoFixpointIterations` for the second.
`pruneDead` removes the specializations left unreferenced once the second has
had its turn.

`aliasForward` and `etaExpand` switch the two pre-monomorphization rewrites:
alias forwarding, which replaces references to a definition that only names
another with references to that other, with the exceptions
`Compiler.GlobalOpt.PreMono.AliasForward` states, and eta expansion.
`etaThreshold` is the budget of eta expansion's cheapness test, and `etaOnly`,
when not empty, restricts eta expansion to the globals whose qualified name
(`Module.name`) starts with one of its prefixes. With `report` on, both
rewrites run even when switched off, as a census that leaves the program
unchanged.

The rest belong to `MonoInlineSimplify`:

  - The names in `whitelist` are added to its built-in whitelist, and the names
    in `blacklist` are removed from the result and never inlined. A
    whitelisted function is exempt from the cost budget; being listed is not
    needed for a function within the budget to be a candidate. A recursive
    specialization is never a candidate, listed or not.
  - `hofThreshold` is a wider budget for a function that calls one of its
    parameters: the budget for such a function is the larger of it and
    `postMonoThreshold`. A function admitted only by this budget is inlined
    only at call sites that pass every argument, unless `partialHof` is on.
  - `preserveSets` declines an inline at a call site that passes some but not
    all arguments, since the closure that inline would build loses its
    lambda-set member. With `partialHof` also on, `preserveSets` wins.
  - `loopify` copies a tail-recursive function into a caller that passes a
    qualifying lambda literal, specialized to that lambda. The literal must
    take the parameter's full flat arity, and the parameter must only be
    called and passed on in tail calls.
  - `arityRaise` merges the stages of a curried specialization whose first
    stage does little work, which can move a crash or a `Debug.log` in that
    stage to the point of application. `raiseAppliedShareMin` is a percentage:
    a specialization is raised only if at least that share of its saturated
    call results are applied, and at zero or less every candidate is raised.
  - `maxPerFunction` caps the inlines into one function.
  - `kernelFactsDce` lets dead-binding removal drop a kernel call that the
    kernel facts mark droppable.
  - With `kernelCostClasses` on, a kernel call costs `kernelCostInline` when it
    lowers to an inline op, and otherwise the cost of its kernel's class:
    `kernelCostGcLeaf`, `kernelCostAlloc` or `kernelCostHof`, or 6 for a
    kernel of unknown class. With it off, every kernel call costs the same and
    the four costs are unused.

Every field except `report` is artifact-affecting. `raiseAppliedShareMin` has
a token only while `arityRaise` is on and it is above zero, and the four costs
only while `kernelCostClasses` is on.

-}
type alias InlineConfig =
    { preMonoThreshold : Int
    , postMonoThreshold : Int
    , etaThreshold : Int
    , whitelist : List String
    , blacklist : List String
    , maxPerFunction : Int
    , preMonoFixpointIterations : Int
    , postMonoFixpointIterations : Int
    , hofThreshold : Int
    , loopify : Bool
    , arityRaise : Bool
    , raiseAppliedShareMin : Int
    , partialHof : Bool
    , preserveSets : Bool
    , pruneDead : Bool
    , preMono : Bool
    , postMono : Bool
    , etaExpand : Bool
    , etaOnly : List String
    , report : Bool
    , kernelFactsDce : Bool
    , kernelCostClasses : Bool
    , kernelCostInline : Int
    , kernelCostGcLeaf : Int
    , kernelCostAlloc : Int
    , kernelCostHof : Int
    , aliasForward : Bool
    }


{-| The switch for bytes fusion, in which the MLIR code generator compiles the
encoder passed to an `elm/bytes` encode call into fused code.

`enabled` gates encoder fusion only: decoder fusion is attempted whatever it
says. It has a token in `hash`.

-}
type alias BytesFusionConfig =
    { enabled : Bool }


{-| The settings of CAF memoization and of the passes around it. A _CAF_ is a
top-level value that takes no arguments.

With `enabled`, on by default, a CAF that qualifies caches its value in a
global slot, so that later references reuse it; which CAFs qualify is decided
by `Compiler.Generate.MLIR.Functions`. `dedupe` merges structurally identical
nullary specializations into one. `hoist` holds the settings of CAF hoisting.
`census` prints a census of CAF opportunities on stderr.

`enabled` and `dedupe` each have a token in `hash` when on; `census` has none.

-}
type alias CafMemoConfig =
    { enabled : Bool
    , census : Bool
    , dedupe : Bool
    , hoist : CafHoistConfig
    }


{-| The settings of CAF hoisting (`Compiler.GlobalOpt.CafHoist`), which moves
closed expressions out of function bodies into new nullary specializations.

`minNodes` is the size, in nodes, below which an expression is not hoisted, and
`maxHoists` caps the specializations hoisting creates. `enabled` is off by
default. When it is on, `hash` gets `cafh=1`, and a token for each of the two
limits that differs from `default`.

-}
type alias CafHoistConfig =
    { enabled : Bool
    , minNodes : Int
    , maxHoists : Int
    }


{-| The settings of the logical-type descriptions the MLIR code generator
attaches to the functions it emits, one for each parameter and the result.

`customMaxFields` is the largest number of fields a single-constructor custom
type may have and still be described field by field; a larger one is
described as a boxed value. `clamp` keeps it between 1 and 24. It has a token
in `hash`.

-}
type alias LogicalTypesConfig =
    { customMaxFields : Int }


{-| The built-in configuration, and the value each key missing from
`eco-config.json` falls back to.

Every switch on `EcoConfig` itself is on, except the `constThunksReport`
census. Among the passes that are off are the pre-monomorphization inliner,
arity raising, CSE, CAF hoisting and deduplication, borrow inference and the
list map template.

-}
default : EcoConfig
default =
    { inline =
        { preMonoThreshold = 10
        , postMonoThreshold = 10
        , etaThreshold = 10
        , whitelist = []
        , blacklist = []
        , maxPerFunction = 1000
        , preMonoFixpointIterations = 4
        , postMonoFixpointIterations = 4
        , hofThreshold = 25
        , loopify = True
        , arityRaise = False
        , raiseAppliedShareMin = 0
        , partialHof = False
        , preserveSets = True
        , pruneDead = True
        , preMono = False
        , postMono = True
        , etaExpand = True
        , etaOnly = []
        , report = False
        , kernelFactsDce = True
        , kernelCostClasses = True
        , kernelCostInline = 1
        , kernelCostGcLeaf = 4
        , kernelCostAlloc = 8
        , kernelCostHof = 20
        , aliasForward = True
        }
    , callPurityAttrs = True
    , cse = { enabled = False, report = False, minCost = 5, maxPerDef = 64 }
    , gc = { preLink = True, report = False }
    , bytesFusion = { enabled = True }
    , logicalTypes = { customMaxFields = 8 }
    , cafMemo = { enabled = True, census = False, dedupe = False, hoist = { enabled = False, minNodes = 3, maxHoists = 8192 } }
    , mono = { engine = EngineSolver, diffDump = False, validate = False, lss = defaultLss, limits = defaultLimits }
    , borrow = { enabled = False, reify = ROff, report = False, validate = False, oracleOpt = False }
    , list = { chunks = True, consIntrinsic = True, mapTemplate = False, report = False }
    , aggPromote = True
    , ctorInline = True
    , sretResults = True
    , psplitParams = True
    , sretFresh = True
    , sretTailFuncs = True
    , stringLengthOp = True
    , appendSplit = True
    , stringOrderIntrinsic = True
    , valueEq = True
    , kernelGcLeaf = True
    , constThunks = 2
    , constThunksReport = False
    }


{-| A decoder for an `eco-config.json` document, which must be a JSON object.

Every key is optional, in the document and in each object within it, and a
missing key takes its value from `default`. Unknown keys are ignored. The
exceptions are these:

  - A `mono` object without an `engine` key selects `EngineSubst`, though
    `default` selects `EngineSolver`. Only a document with no `mono` object
    at all gets the default engine. An `engine` or `borrow.reify` string that
    is not recognized gives the default.
  - `list.report`, `cse.report`, `mono.diffDump` and `mono.validate` are not
    read; they always take their default.
  - The two `LssStampConfig` settings are read from the `mono.lss` object
    itself, as `instanceQualMaxInstances` and `census`.

The decoder never fails with a problem of its own, so its problem type is left
open.

-}
decoder : D.Decoder x EcoConfig
decoder =
    D.pure EcoConfig
        |> D.apply (D.optionalField "inline" inlineDecoder default.inline)
        |> D.apply (D.optionalField "bytesFusion" bytesFusionDecoder default.bytesFusion)
        |> D.apply (D.optionalField "logicalTypes" logicalTypesDecoder default.logicalTypes)
        |> D.apply (D.optionalField "cafMemo" cafMemoDecoder default.cafMemo)
        |> D.apply (D.optionalField "mono" monoDecoder default.mono)
        |> D.apply (D.optionalField "borrow" borrowDecoder default.borrow)
        |> D.apply (D.optionalField "list" listDecoder default.list)
        |> D.apply (D.optionalField "aggPromote" D.bool default.aggPromote)
        |> D.apply (D.optionalField "ctorInline" D.bool default.ctorInline)
        |> D.apply (D.optionalField "sretResults" D.bool default.sretResults)
        |> D.apply (D.optionalField "psplitParams" D.bool default.psplitParams)
        |> D.apply (D.optionalField "sretFresh" D.bool default.sretFresh)
        |> D.apply (D.optionalField "sretTailFuncs" D.bool default.sretTailFuncs)
        |> D.apply (D.optionalField "stringLengthOp" D.bool default.stringLengthOp)
        |> D.apply (D.optionalField "appendSplit" D.bool default.appendSplit)
        |> D.apply (D.optionalField "stringOrderIntrinsic" D.bool default.stringOrderIntrinsic)
        |> D.apply (D.optionalField "valueEq" D.bool default.valueEq)
        |> D.apply (D.optionalField "kernelGcLeaf" D.bool default.kernelGcLeaf)
        |> D.apply (D.optionalField "callPurityAttrs" D.bool default.callPurityAttrs)
        |> D.apply (D.optionalField "constThunks" D.int default.constThunks)
        |> D.apply (D.optionalField "constThunksReport" D.bool default.constThunksReport)
        |> D.apply (D.optionalField "cse" cseDecoder default.cse)
        |> D.apply (D.optionalField "gc" gcDecoder default.gc)


{-| A decoder for the `gc` object, each key falling back to `default`.
-}
gcDecoder : D.Decoder x GcConfig
gcDecoder =
    D.pure GcConfig
        |> D.apply (D.optionalField "preLink" D.bool default.gc.preLink)
        |> D.apply (D.optionalField "report" D.bool default.gc.report)


{-| A decoder for the `list` object, each key falling back to `default`.
`report` is not read and keeps its default.
-}
listDecoder : D.Decoder x ListConfig
listDecoder =
    D.pure
        (\chunks consIntrinsic mapTemplate ->
            { chunks = chunks
            , consIntrinsic = consIntrinsic
            , mapTemplate = mapTemplate
            , report = default.list.report
            }
        )
        |> D.apply (D.optionalField "chunks" D.bool default.list.chunks)
        |> D.apply (D.optionalField "consIntrinsic" D.bool default.list.consIntrinsic)
        |> D.apply (D.optionalField "mapTemplate" D.bool default.list.mapTemplate)


{-| A decoder for the `cse` object, each key falling back to `default`.
`report` is not read and keeps its default.
-}
cseDecoder : D.Decoder x CseConfig
cseDecoder =
    D.pure (\enabled minCost maxPerDef -> CseConfig enabled default.cse.report minCost maxPerDef)
        |> D.apply (D.optionalField "enabled" D.bool default.cse.enabled)
        |> D.apply (D.optionalField "minCost" D.int default.cse.minCost)
        |> D.apply (D.optionalField "maxPerDef" D.int default.cse.maxPerDef)


{-| A decoder for the `inline` object, which has a key for every field of
`InlineConfig`, each falling back to `default`.
-}
inlineDecoder : D.Decoder x InlineConfig
inlineDecoder =
    D.pure InlineConfig
        |> D.apply (D.optionalField "preMonoThreshold" D.int default.inline.preMonoThreshold)
        |> D.apply (D.optionalField "postMonoThreshold" D.int default.inline.postMonoThreshold)
        |> D.apply (D.optionalField "etaThreshold" D.int default.inline.etaThreshold)
        |> D.apply (D.optionalField "whitelist" (D.list D.string) default.inline.whitelist)
        |> D.apply (D.optionalField "blacklist" (D.list D.string) default.inline.blacklist)
        |> D.apply (D.optionalField "maxPerFunction" D.int default.inline.maxPerFunction)
        |> D.apply (D.optionalField "preMonoFixpointIterations" D.int default.inline.preMonoFixpointIterations)
        |> D.apply (D.optionalField "postMonoFixpointIterations" D.int default.inline.postMonoFixpointIterations)
        |> D.apply (D.optionalField "hofThreshold" D.int default.inline.hofThreshold)
        |> D.apply (D.optionalField "loopify" D.bool default.inline.loopify)
        |> D.apply (D.optionalField "arityRaise" D.bool default.inline.arityRaise)
        |> D.apply (D.optionalField "raiseAppliedShareMin" D.int default.inline.raiseAppliedShareMin)
        |> D.apply (D.optionalField "partialHof" D.bool default.inline.partialHof)
        |> D.apply (D.optionalField "preserveSets" D.bool default.inline.preserveSets)
        |> D.apply (D.optionalField "pruneDead" D.bool default.inline.pruneDead)
        |> D.apply (D.optionalField "preMono" D.bool default.inline.preMono)
        |> D.apply (D.optionalField "postMono" D.bool default.inline.postMono)
        |> D.apply (D.optionalField "etaExpand" D.bool default.inline.etaExpand)
        |> D.apply (D.optionalField "etaOnly" (D.list D.string) default.inline.etaOnly)
        |> D.apply (D.optionalField "report" D.bool default.inline.report)
        |> D.apply (D.optionalField "kernelFactsDce" D.bool default.inline.kernelFactsDce)
        |> D.apply (D.optionalField "kernelCostClasses" D.bool default.inline.kernelCostClasses)
        |> D.apply (D.optionalField "kernelCostInline" D.int default.inline.kernelCostInline)
        |> D.apply (D.optionalField "kernelCostGcLeaf" D.int default.inline.kernelCostGcLeaf)
        |> D.apply (D.optionalField "kernelCostAlloc" D.int default.inline.kernelCostAlloc)
        |> D.apply (D.optionalField "kernelCostHof" D.int default.inline.kernelCostHof)
        |> D.apply (D.optionalField "aliasForward" D.bool default.inline.aliasForward)


{-| A decoder for the `bytesFusion` object, falling back to `default`.
-}
bytesFusionDecoder : D.Decoder x BytesFusionConfig
bytesFusionDecoder =
    D.pure BytesFusionConfig
        |> D.apply (D.optionalField "enabled" D.bool default.bytesFusion.enabled)


{-| A decoder for the `cafMemo` object, each key falling back to `default`. The
hoisting settings are in a nested `hoist` object.
-}
cafMemoDecoder : D.Decoder x CafMemoConfig
cafMemoDecoder =
    D.pure CafMemoConfig
        |> D.apply (D.optionalField "enabled" D.bool default.cafMemo.enabled)
        |> D.apply (D.optionalField "census" D.bool default.cafMemo.census)
        |> D.apply (D.optionalField "dedupe" D.bool default.cafMemo.dedupe)
        |> D.apply (D.optionalField "hoist" cafHoistDecoder default.cafMemo.hoist)


{-| A decoder for the `cafMemo.hoist` object, each key falling back to
`default`.
-}
cafHoistDecoder : D.Decoder x CafHoistConfig
cafHoistDecoder =
    D.pure CafHoistConfig
        |> D.apply (D.optionalField "enabled" D.bool default.cafMemo.hoist.enabled)
        |> D.apply (D.optionalField "minNodes" D.int default.cafMemo.hoist.minNodes)
        |> D.apply (D.optionalField "maxHoists" D.int default.cafMemo.hoist.maxHoists)


{-| A decoder for the `logicalTypes` object, falling back to `default`. It does
not check the range of `customMaxFields`; `clamp` does.
-}
logicalTypesDecoder : D.Decoder x LogicalTypesConfig
logicalTypesDecoder =
    D.pure LogicalTypesConfig
        |> D.apply (D.optionalField "customMaxFields" D.int default.logicalTypes.customMaxFields)


{-| A decoder for the `borrow` object, each key falling back to `default`.
`reify` is a string, read as `borrowReifyFromString` reads it, and one it does
not recognize gives `default`'s `ROff`.
-}
borrowDecoder : D.Decoder x BorrowConfig
borrowDecoder =
    D.pure
        (\enabled reifyStr report validate oracleOpt ->
            { enabled = enabled
            , reify = Maybe.withDefault default.borrow.reify (borrowReifyFromString reifyStr)
            , report = report
            , validate = validate
            , oracleOpt = oracleOpt
            }
        )
        |> D.apply (D.optionalField "enabled" D.bool default.borrow.enabled)
        |> D.apply (D.optionalField "reify" D.string "off")
        |> D.apply (D.optionalField "report" D.bool default.borrow.report)
        |> D.apply (D.optionalField "validate" D.bool default.borrow.validate)
        |> D.apply (D.optionalField "oracleOpt" D.bool default.borrow.oracleOpt)


{-| Returns the `BorrowReify` that `s` names, `"off"` or `"rc"`, ignoring case
and surrounding whitespace, or `Nothing` for any other string.
-}
borrowReifyFromString : String -> Maybe BorrowReify
borrowReifyFromString s =
    case String.toLower (String.trim s) of
        "off" ->
            Just ROff

        "rc" ->
            Just RRc

        _ ->
            Nothing


{-| A decoder for the `mono` object, which has the keys `engine`, `lss` and
`limits`.

A missing `engine` gives `EngineSubst`, not `default`'s `EngineSolver`, while
one that is not recognized gives `EngineSolver`. `diffDump` and `validate` are
not read and keep their defaults.

-}
monoDecoder : D.Decoder x MonoConfig
monoDecoder =
    D.pure
        (\s lss limits ->
            { engine = Maybe.withDefault default.mono.engine (monoEngineFromString s)
            , diffDump = default.mono.diffDump
            , validate = default.mono.validate
            , lss = lss
            , limits = limits
            }
        )
        |> D.apply (D.optionalField "engine" D.string "subst")
        |> D.apply (D.optionalField "lss" lssDecoder defaultLss)
        |> D.apply (D.optionalField "limits" specLimitsDecoder defaultLimits)


{-| A decoder for the `mono.limits` object, each key falling back to
`defaultLimits`.
-}
specLimitsDecoder : D.Decoder x SpecLimits
specLimitsDecoder =
    D.pure SpecLimits
        |> D.apply (D.optionalField "specTypeNodes" D.int defaultLimits.specTypeNodes)
        |> D.apply (D.optionalField "specBreadth" D.int defaultLimits.specBreadth)


{-| A decoder for the `mono.lss` object, each key falling back to `defaultLss`.
The `stamp` settings are read from this same object, by
`lssInstanceQualDecoder`.
-}
lssDecoder : D.Decoder x LssConfig
lssDecoder =
    D.pure LssConfig
        |> D.apply (D.optionalField "enabled" D.bool defaultLss.enabled)
        |> D.apply (D.optionalField "maxSetSize" D.int defaultLss.maxSetSize)
        |> D.apply (D.optionalField "maxSpecsPerGlobal" D.int defaultLss.maxSpecsPerGlobal)
        |> D.apply (D.optionalField "report" D.bool defaultLss.report)
        |> D.apply (D.optionalField "qCensus" D.bool defaultLss.qCensus)
        |> D.apply (D.optionalField "arrowCensus" D.bool defaultLss.arrowCensus)
        |> D.apply lssInstanceQualDecoder


{-| A decoder for the instance-qualification settings, read from the `mono.lss`
object itself rather than from a nested one: `instanceQualMaxInstances` gives
`maxInstances` and `census` gives `census`, each falling back to `defaultLss`.
-}
lssInstanceQualDecoder : D.Decoder x LssStampConfig
lssInstanceQualDecoder =
    D.pure LssStampConfig
        |> D.apply (D.optionalField "instanceQualMaxInstances" D.int defaultLss.stamp.maxInstances)
        |> D.apply (D.optionalField "census" D.bool defaultLss.stamp.census)


{-| Returns the engine that `s` names, `"subst"`, `"solver"` or `"diff"`,
ignoring case and surrounding whitespace, or `Nothing` for any other string.
-}
monoEngineFromString : String -> Maybe MonoEngine
monoEngineFromString s =
    case String.toLower (String.trim s) of
        "subst" ->
            Just EngineSubst

        "solver" ->
            Just EngineSolver

        "diff" ->
            Just EngineDiff

        _ ->
            Nothing


{-| Returns `cfg` with every setting that has hard bounds brought within them,
together with a warning for each setting it changed.

The only such setting is `logicalTypes.customMaxFields`, which is brought
within 1 to 24.

-}
clamp : EcoConfig -> ( EcoConfig, List String )
clamp cfg =
    let
        cmf =
            cfg.logicalTypes.customMaxFields
    in
    if cmf < 1 || cmf > 24 then
        let
            clamped =
                Basics.clamp 1 24 cmf
        in
        ( { cfg | logicalTypes = { customMaxFields = clamped } }
        , [ "eco-config.json: logicalTypes.customMaxFields "
                ++ String.fromInt cmf
                ++ " is out of range [1,24]; clamped to "
                ++ String.fromInt clamped
                ++ "."
          ]
        )

    else
        ( cfg, [] )


{-| Returns the cache key for `cfg`: a version token, then tokens for its
artifact-affecting settings, for the three read-only censuses and for
`borrow.oracleOpt`, joined by `|`.

The key depends on nothing else, so a file that spells out `default` gets the
same key as no file at all. No token comes from any `report` setting,
`cafMemo.census`, `constThunksReport`, `mono.diffDump`, `mono.validate`,
`mono.limits`, `gc`, or any `borrow` setting but `oracleOpt`.

Many switches have a token only when on, and many limits only when they
differ from `default`. Among the engines, `EngineSolver` and `EngineDiff` have
a token and `EngineSubst` has none. The LSS tokens appear whatever the engine,
though `EngineSolver` is the only engine that reads `LssConfig`.

-}
hash : EcoConfig -> String
hash cfg =
    String.join "|"
        ([ "v1"
         , "preThr=" ++ String.fromInt cfg.inline.preMonoThreshold
         , "postThr=" ++ String.fromInt cfg.inline.postMonoThreshold
         , "etaThr=" ++ String.fromInt cfg.inline.etaThreshold
         , "phof="
            ++ (if cfg.inline.partialHof then
                    "1"

                else
                    "0"
               )
         , "psets="
            ++ (if cfg.inline.preserveSets then
                    "1"

                else
                    "0"
               )
         , "prune="
            ++ (if cfg.inline.pruneDead then
                    "1"

                else
                    "0"
               )
         , "preInl="
            ++ (if cfg.inline.preMono then
                    "1"

                else
                    "0"
               )
         , "postInl="
            ++ (if cfg.inline.postMono then
                    "1"

                else
                    "0"
               )
         , "eta="
            ++ (if cfg.inline.etaExpand then
                    "1"

                else
                    "0"
               )
         , "etaOnly=" ++ String.join "," cfg.inline.etaOnly
         , "afwd="
            ++ (if cfg.inline.aliasForward then
                    "1"

                else
                    "0"
               )
         , "wl=" ++ String.join "," cfg.inline.whitelist
         , "bl=" ++ String.join "," cfg.inline.blacklist
         , "mpf=" ++ String.fromInt cfg.inline.maxPerFunction
         , "preFpi=" ++ String.fromInt cfg.inline.preMonoFixpointIterations
         , "postFpi=" ++ String.fromInt cfg.inline.postMonoFixpointIterations
         , "hthr=" ++ String.fromInt cfg.inline.hofThreshold
         , "loop="
            ++ (if cfg.inline.loopify then
                    "1"

                else
                    "0"
               )
         , "bf="
            ++ (if cfg.bytesFusion.enabled then
                    "1"

                else
                    "0"
               )
         , "cmf=" ++ String.fromInt cfg.logicalTypes.customMaxFields
         ]
            ++ (if cfg.cafMemo.enabled then
                    [ "cafm=1" ]

                else
                    []
               )
            ++ (if cfg.cafMemo.dedupe then
                    [ "cafd=1" ]

                else
                    []
               )
            ++ (if cfg.cafMemo.hoist.enabled then
                    "cafh=1"
                        :: ((if cfg.cafMemo.hoist.minNodes /= default.cafMemo.hoist.minNodes then
                                [ "cafhN=" ++ String.fromInt cfg.cafMemo.hoist.minNodes ]

                             else
                                []
                            )
                                ++ (if cfg.cafMemo.hoist.maxHoists /= default.cafMemo.hoist.maxHoists then
                                        [ "cafhM=" ++ String.fromInt cfg.cafMemo.hoist.maxHoists ]

                                    else
                                        []
                                   )
                           )

                else
                    []
               )
            ++ (if cfg.inline.arityRaise then
                    "ar=1"
                        :: (if cfg.inline.raiseAppliedShareMin > 0 then
                                [ "arm=" ++ String.fromInt cfg.inline.raiseAppliedShareMin ]

                            else
                                []
                           )

                else
                    []
               )
            ++ (if cfg.inline.kernelFactsDce then
                    [ "kfdce=1" ]

                else
                    []
               )
            ++ (if cfg.callPurityAttrs then
                    [ "cpur=1" ]

                else
                    []
               )
            ++ (if cfg.cse.enabled then
                    "cse=1"
                        :: (if cfg.cse.minCost /= default.cse.minCost then
                                [ "cseMin=" ++ String.fromInt cfg.cse.minCost ]

                            else
                                []
                           )
                        ++ (if cfg.cse.maxPerDef /= default.cse.maxPerDef then
                                [ "cseMax=" ++ String.fromInt cfg.cse.maxPerDef ]

                            else
                                []
                           )

                else
                    []
               )
            ++ (if cfg.inline.kernelCostClasses then
                    [ "kcc="
                        ++ String.fromInt cfg.inline.kernelCostInline
                        ++ "/"
                        ++ String.fromInt cfg.inline.kernelCostGcLeaf
                        ++ "/"
                        ++ String.fromInt cfg.inline.kernelCostAlloc
                        ++ "/"
                        ++ String.fromInt cfg.inline.kernelCostHof
                    ]

                else
                    []
               )
            ++ (case cfg.mono.engine of
                    EngineSubst ->
                        []

                    EngineSolver ->
                        [ "mono=solver" ]

                    EngineDiff ->
                        [ "mono=diff" ]
               )
            ++ (let
                    lss =
                        cfg.mono.lss
                in
                List.concat
                    [ if lss.enabled then
                        [ "lss=1" ]

                      else
                        []
                    , if lss.maxSetSize /= defaultLss.maxSetSize then
                        [ "lssS=" ++ String.fromInt lss.maxSetSize ]

                      else
                        []
                    , if lss.maxSpecsPerGlobal /= defaultLss.maxSpecsPerGlobal then
                        [ "lssB=" ++ String.fromInt lss.maxSpecsPerGlobal ]

                      else
                        []
                    , if lss.stamp.maxInstances /= defaultLss.stamp.maxInstances then
                        [ "lssIQM=" ++ String.fromInt lss.stamp.maxInstances ]

                      else
                        []

                    -- The three census tokens change no generated code; they keep
                    -- a census build in cache entries of its own.
                    , if lss.qCensus /= defaultLss.qCensus then
                        [ "lssQC="
                            ++ (if lss.qCensus then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []
                    , if lss.stamp.census /= defaultLss.stamp.census then
                        [ "lssCen="
                            ++ (if lss.stamp.census then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []
                    , if lss.arrowCensus /= defaultLss.arrowCensus then
                        [ "lssAC="
                            ++ (if lss.arrowCensus then
                                    "1"

                                else
                                    "0"
                               )
                        ]

                      else
                        []
                    ]
               )
            ++ (if cfg.list.chunks then
                    [ "lchunks=1" ]

                else
                    []
               )
            ++ (if cfg.list.consIntrinsic then
                    [ "lcons=1" ]

                else
                    []
               )
            ++ (if cfg.list.mapTemplate then
                    [ "lmapt=1" ]

                else
                    []
               )
            ++ (if cfg.aggPromote then
                    [ "aggp=1" ]

                else
                    []
               )
            ++ (if cfg.ctorInline then
                    [ "ctori=1" ]

                else
                    []
               )
            ++ (if cfg.sretResults then
                    [ "sretr=1" ]

                else
                    []
               )
            ++ (if cfg.psplitParams then
                    [ "psplit=1" ]

                else
                    []
               )
            ++ (if cfg.sretFresh then
                    [ "sretf=1" ]

                else
                    []
               )
            ++ (if cfg.sretTailFuncs then
                    [ "srtf=1" ]

                else
                    []
               )
            ++ (if cfg.stringLengthOp then
                    [ "strlen=1" ]

                else
                    []
               )
            ++ (if cfg.appendSplit then
                    [ "apsplit=1" ]

                else
                    []
               )
            ++ (if cfg.stringOrderIntrinsic then
                    [ "strord=1" ]

                else
                    []
               )
            ++ (if cfg.valueEq then
                    [ "veq=1" ]

                else
                    []
               )
            ++ (if cfg.constThunks > 0 then
                    [ "cthk=" ++ String.fromInt cfg.constThunks ]

                else
                    []
               )
            ++ (if cfg.kernelGcLeaf then
                    [ "kgcl=1" ]

                else
                    []
               )
            ++ (if cfg.borrow.oracleOpt then
                    [ "bopt=1" ]

                else
                    []
               )
        )
