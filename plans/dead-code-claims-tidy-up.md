---
status: not-started
updated: 2026-10-28
---

# Dead-code tidy-up: verify the "never runs" claims from the recomment run

## Why

The 2026-10 elm-doc-comments run (`compiler/recomment-bugs.txt`, triaged in
`compiler/recomment-bugs-triage.tsv`) left 82 claims, outside `tests/`, that some code is dead,
unused, unreachable or "can never happen". Every one is an agent's reading of the code; none has
been checked by tooling or by running anything. This plan records them and how to settle each, so
a later pass can work through them. Line numbers are against the tree of the run that reported
them and may have drifted.

The S1 verification of 2026-10-27/28 already settled three such claims by reading: the
`generateIf` terminated-else path (`Generate/MLIR/Expr.elm`) and the two no-registry fallbacks in
`Generate/MLIR/Patterns.elm` are unreachable today, but would miscompile if reached.

## Three kinds of claim, three kinds of evidence

1. **Unused definition** (function, import, parameter, constructor with no reference). Provable
   mechanically: run elm-review's `NoUnused.*` rules. Check `src-xhr` results against the kernel
   API before deleting anything there; elm-review once stripped kernel twin parameters.
2. **Impossible branch** (a case the inputs supposedly never produce). Evidence is either a proof
   from the types (strongest: then change the type so the branch disappears), or a pipeline
   invariant (only as good as that invariant), plus a crash probe (below). A probe that never
   fires shows the branch is not exercised by our corpus, not that no program can reach it.
3. **Live only under a non-default setting** (a flag, budget or census). Not dead: reachable by
   configuration. A default-settings probe would wrongly call it dead. Needs a test with the
   setting on, or a decision to remove the setting.

The kind given in the appendix is a keyword guess from the claim's wording; re-classify on contact.

## Steps

0. **Re-locate.** For each entry, find the code in today's tree; drop entries whose code is gone
   or already changed.
1. **Kind 1, elm-review.** Run `NoUnused.Variables`, `NoUnused.Parameters`, `NoUnused.CustomTypeConstructors`
   and `NoUnused.Exports` over `compiler/src` (the elm-review project is `compiler/review/`). Delete what it confirms (not in `src-xhr` without
   the kernel-API check). Entries it does not confirm move to kind 2.
2. **Kind 2, crash probes.** Do not delete. Replace each "impossible" branch body with a crash that
   names the invariant it relies on (e.g. `Utils.Crash.crash "CtorShapes: no registry entry for
   <layout> (Prune.elm fills every path type)"`). Then one run of elm-tests, `full`, stress and the
   bootstrap. A hit means the claim was wrong: keep the branch and file a bug. No hit: keep the
   loud crash (it turns a silent miscompile into a crash if the invariant ever breaks). Where the
   types alone exclude the case, prefer changing the type to remove the branch.
3. **Kind 3, settings.** For each, decide: keep the setting and add a test with it on, or remove
   the setting and the code it gates.
4. **Close out.** Mark each entry done in this file's appendix (or delete its row); update
   `recomment-bugs-triage.tsv` and the entry in `recomment-bugs.txt`.

## Gate

Each step's changes: elm-tests, `full`, stress and a bootstrap fixed point (4b/8c/9b), each run
once. Kind-2 crash probes must not change any test result.

## Appendix: the claims

### Kind 1: unused definitions (13)

| Location | Reported by | Claim |
|---|---|---|
| `src/Compiler/Compile.elm:270` | comment | Warnings from canonicalize (and from optimize/optimizeTyped at lines 600, 615) are discarded: only Tuple.second of ReportingResult.run is kept, and no module renders a Warning. So unused-variable and missing-annotation warnings are computed but never shown. |
| `src/Compiler/Generate/JavaScript/Builder.elm:447` | comment | Unlabelled Break and Continue (also line 460) are printed without the indent every other statement gets; no caller in src builds them, so layout only. |
| `src/Compiler/GlobalOpt/CsePurity.elm:432` | map | foldChildren visits only a MonoClosure's body, not its capture expressions. scanBody therefore misses a Debug kernel or a MonoVarGlobal callee edge that appears only in a capture expression (oracle may be optimistic), and countLocalUses misses uses inside capture expressions (a dead-let count, or... |
| `src/Compiler/GlobalOpt/InlineSimplify.elm:2095` | map | locatedName is defined but never used. |
| `src/Compiler/GlobalOpt/MonoCse.elm:590-591` | comment, review; run 2026-10-27 | The bound expression of a MonoTailDef (a local tail-recursive function's body) is tagged 'u ld', which counts as unconditional, but it runs only when the function is called. A group whose only all-unconditional occurrence is inside that body is therefore bound at an outer LCA, and the call is eva... |
| `src/Compiler/GlobalOpt/MonoGlobalOptimize.elm:741` | map | rewriteExprForAbi and everything only it reaches (rewriteCaseForAbi, rewriteIfForAbi, processBranchResult, processDeciderForAbi, processJumpsForAbi, computeBranchNormalization, collectCaseLeafFunctionsGO, buildAbiWrapperGO, buildNestedCallsGO) are never called from any entry point; globalOptimize... |
| `src/Compiler/GlobalOpt/MonoInlineSimplify.elm:5866` | map | inlineVar, inlineVarInDef, inlineVarInPath, inlineVarInDtPath, inlineVarInDecider and isFunctionType are never called (dead code). |
| `src/Compiler/GlobalOpt/MonoInlineSimplify.elm:6028` | comment; run 2026-10-27 | inlineVar and its helpers (inlineVarInDef, inlineVarInPath, inlineVarInDtPath, inlineVarInDecider) are never called: dead code. |
| `src/Compiler/MonoSolver/Monomorphize.elm:5140` | map | Unannotated duplicate `renderFailure` at end of module is never called (drain errors use Engine.renderFailure); dead code that can drift from the real one. |
| `src/Compiler/Parse/Expression.elm:349` | comment; run 2026-10-27 | accessibleRecord and chompRecordAccessField are never called (dead code). |
| `src/Compiler/Reporting/Error.elm:209` | comment, review | The `suggestions` field of a Report is never read anywhere in src: reportToDoc (Error.elm:209-215) uses title and doc, reportToJson (Error.elm:267-272) uses title, region and doc, and Terminal.Repl (src/Terminal/Repl.elm:575-579) reads only region. Producers that compute suggestions (e.g. src/Com... |
| `src/Control/Monad/State/Strict.elm:76` | comment, review | put saves the REPL state through Eco.Runtime.saveState, but no module in src or src-xhr calls Eco.Runtime.loadState, so the saved state is never read back (dead write). |
| `src/Mlir/Bytecode/VarInt.elm:203` | rework | shiftRightBy with amount <= 31 calls Bitwise.shiftRightBy, which under JavaScript truncates `value` to 32 bits, so (2^40) shifted by 3 gives 0. No caller in the module reaches this today, because encode9Bytes passes only 32 to 56. It is a latent defect if the helper is reused. |

### Kind 2: impossible branches (66)

| Location | Reported by | Claim |
|---|---|---|
| `bin/eco-io-handler.js:189` | review | Console.readAll: each call adds new 'data' and 'end' listeners to process.stdin. If readAll is called a second time after stdin has already ended, 'end' never fires again, so that request never gets a response and hangs. |
| `bin/eco-io-handler.js:443-446` | comment, map, review | Process.spawn (and Process.spawnProcess at :468) attach no 'error' listener to the child; Node reports ENOENT/EACCES from spawn asynchronously as an 'error' event, which with no listener is thrown and crashes the eco-io host instead of yielding a tag 1/2 failure (so CommandNotFound/CommandNotExec... |
| `bin/eco-io-handler.js:468` | review, rework | Process.spawnProcess calls child_process.spawn and replies 200 with a process handle without adding an 'error' listener to the child. When the command does not exist (ENOENT, which is reported asynchronously), the child's 'error' event goes unhandled and crashes the Node host. The Elm side's spaw... |
| `src-xhr/Eco/Http/Error.elm:44` | comment | Five of the seven HttpError constructors (BadUrl, Timeout, Tls, BodyDecode, OtherHttp) are never constructed anywhere in the project; decode builds only Network (status 0) or BadStatus. So the matching branches in Builder.Http.fromHttpError and in toString cannot be reached, and a timeout or bad ... |
| `src-xhr/Eco/Http/Error.elm:69` | comment | toString is exposed but nothing in src, src-xhr or tests calls it, so it is dead code. |
| `src-xhr/Eco/Process/Error.elm:45` | comment | The OtherProcessError constructor is never constructed anywhere in src, src-xhr or the identical kernel twin (eco-kernel-cpp/src/Eco/Process/Error.elm). The toString branch for it (line 96) can never run in this tree. This is dead code, not a wrong result. |
| `src/API/Make.elm:113` | rework; run 2026-10-27 | crash "TODO" branch for several mains is unreachable with a single root path (dead code); with zero mains the process crashes via crash "No main!" (line 106) instead of returning a JSON error. |
| `src/Builder/Elm/Details.elm:2388` | map | extrasEncoder writes ArtifactsFresh in full (all dependency interfaces and the whole global object graph) into d.dat, which Builder.Build.writeDetails rewrites after every build; d.dat duplicates i.dat/o.dat and ArtifactsCached is never produced, so the lazy o.dat/i.dat loading paths are dead. |
| `src/Builder/Reporting/Exit/Help.elm:204` | comment, review; run 2026-10-27 | toHandle asks IO.isTerminal without the handle, and isTerminal always answers True, so ANSI escape sequences are written even when stdout/stderr is redirected to a file or pipe; the plain-text branch is unreachable. |
| `src/Common/Format/Cheapskate/Inlines.elm:857` | review | pLink's fallback `return (Str "[" :: lab_ ++ [ Str "]" ])` is unreachable: pReferenceLink is built with `option rawlab ...`, which is `oneOf p (pure x)` and never fails. So any balanced `[text]` becomes `Link lab (Ref text) ""` even when no reference definition exists, instead of staying literal ... |
| `src/Common/Format/Render/Box.elm:655` | comment; run 2026-10-27 | Names on @docs lines are matched as written. `@docs Type(..)` therefore does not match the exposed `Type`, which ends up in the trailing group of the exposing list. textToRef also recognises only one- and two-character operators, so `(</>)` is never matched. |
| `src/Compiler/Data/BitSet.elm:200-202` | comment, review, rework | In insert (and identically remove at line 230), the Nothing branch of Array.get after ensureWord cannot be reached, since ensureWord guarantees the word exists; dead but harmless. |
| `src/Compiler/Data/CtorTag.elm:85` | comment, review | Used by src/Compiler/Generate/MLIR/Patterns.elm:1250: an IsCtor test on a user constructor named True or False in a non-Bool custom type is tagged constantTag (0xFFFD), but such a value is emitted as a Bool constant word, for which eco_get_tag returns 0 or 1 (runtime/src/allocator/RuntimeExports.... |
| `src/Compiler/Generate/JavaScript/Expression.elm:566` | review, rework | `moduleName == Name.jsArray` compares with "JsArray" (src/Compiler/Data/Name.elm:510), but a core call into elm/core's `Elm.JsArray` has module name "Elm.JsArray". The branch never fires, so the inlining of JsArray.singleton and unsafeGet in generateJsArrayCall is dead and those calls go through ... |
| `src/Compiler/Generate/JavaScript/Expression.elm:1373` | review | generateCaseTest checks an IsCtor for name == Name.bool ("Bool", the type name) in Basics; no constructor is named Bool and Bool patterns become IsBool, so this branch is dead. |
| `src/Compiler/Generate/JavaScript/Expression.elm:691-694` | comment, review; run 2026-10-27 | generateCoreCall compares the core module name with Name.jsArray (the type name JsArray), but elm/core's module is Elm.JsArray, so generateJsArrayCall's inlining of singleton/unsafeGet never runs. |
| `src/Compiler/Generate/JavaScript/Expression.elm:1617-1619` | comment, review; run 2026-10-27 | generateCaseTest checks `name == Name.bool` on a constructor test; a constructor name (True/False) never equals the type name Bool, so the branch is dead. |
| `src/Compiler/Generate/MLIR/BytesFusion/Reify.elm:1260` | map | The Bytes.Decode.loop args are bound as [stepFnExpr, initialStateExpr], but elm/bytes loop is `state -> callback -> Decoder`. The initial-state checks (tuple with [] or empty list) are applied to the callback, so loop reification can never match: DCountLoop and DSentinelLoop are unreachable from ... |
| `src/Compiler/Generate/MLIR/Context.elm:226` | comment, review; run 2026-10-27 | hasKernelImplementation is the constant False, so the kernel-fallback branch it guards at Expr.elm:3939 can never run (dead code). |
| `src/Compiler/Generate/MLIR/Context.elm:555` | comment; run 2026-10-27 | If registration fails, getOrCreateTypeIdForMonoType silently returns TypeId 0, an id that already belongs to another type. As far as the code shows this cannot happen, but if it did the debug type would be wrong. |
| `src/Compiler/Generate/MLIR/Context.elm:569` | review; run 2026-10-27 | getOrCreateTypeIdForMonoType returns TypeId 0 (belonging to another type) silently if registration fails; unreachable as far as the code shows. |
| `src/Compiler/Generate/MLIR/Expr.elm:3939` | review; run 2026-10-27 | Branch guarded by Ctx.hasKernelImplementation, which is the constant False (Context.elm:228), so the kernel-fallback path is dead code. |
| `src/Compiler/Generate/MLIR/Expr.elm:6937-6938` | comment, review; run 2026-10-27 | generateTupleCreate calls the one-argument crash with three strings. Only "Compiler.Generate.CodeGen.MLIR" is reported, so the explanation of the unreachable case (more than three elements) is lost. |
| `src/Compiler/Generate/MLIR/Intrinsics.elm:575` | comment; run 2026-10-27 | generateIntrinsicOp's StringOrderCompare arm emits a placeholder over %error operands, and its ValueEq/BoolEq arms ignore negate (BoolEq always emits xor, i.e. /=). These arms are dead because generateIntrinsicOps intercepts these constructors, but a direct call would give wrong code. |
| `src/Compiler/Generate/MLIR/Patterns.elm:1016` | map | In generateMonoUnboxOnHeap the condition `Types.isUnboxable targetType` is tested twice in a row (lines 1012 and 1016). The first branch crashes, so the second branch, which emits an eco.unbox, can never run. |
| `src/Compiler/Generate/MLIR/Patterns.elm:1034-1037` | comment, review; run 2026-10-27 | In generateMonoUnboxOnHeap, the second `else if Types.isUnboxable targetType` branch (the hand-built eco.unbox) has the same condition as the crash branch above it, so it can never run. |
| `src/Compiler/GlobalOpt/AbiCloning.elm:1701-1706` | comment, review; run 2026-10-27 | bumpPapSite records only reasons starting 'g1absentp\|WOULDSTAMP', but its only caller (line 1585, the PsNotCandidate arm) never receives that reason: papResolve returns it only together with a target, which becomes PsStampPap. So instQual.papSites is always empty (dead census logic). |
| `src/Compiler/GlobalOpt/Borrow.elm:852` | comment | The `LParams _ -> True` branch of escapesR looks unreachable. Nothing under src constructs LParams: Solve seeds lifetimes only through L.fromPath, which yields LLocal, and Lifetime.join only passes on an LParams it is given. Escapes to parameters are caught only by the alpha-set test. |
| `src/Compiler/GlobalOpt/Borrow/Constrain.elm:604` | comment, review | Constrain builds each Path by consing the deeper step onto the parent's path (`Seq n 0 :: path`, also lines 685, 706, 1157, 1167, 1275), so the head is the innermost step. Lifetime (fromPath, endsBefore, onBoundary) reads the head as the step leaving the root, and Solve.elm:76 (L.fromPath) and So... |
| `src/Compiler/GlobalOpt/Borrow/Lifetime.elm:139` | review | Lifetime reads a Path with its head as the step leaving the root (fromPathLife, endsBeforeLife, onBoundaryLife). Constrain builds paths by consing the deeper step onto the parent's path (`Seq n i :: path`, Constrain.elm:604 and the other sites), so its head is the innermost step. Solve passes the... |
| `src/Compiler/GlobalOpt/Borrow/Solve.elm:76` | rework | Constrain builds paths innermost-first by consing the deeper step onto the parent path (`Seq n i :: path`, `Arm n i :: path`). Solve passes those seed paths to `L.fromPath` here, and the scope paths to `L.endsBefore` at Solve.elm:347, without reversing them, but Lifetime reads the head step as th... |
| `src/Compiler/GlobalOpt/CseCensus.elm:688` | comment, review; run 2026-10-27 | Dead-let test uses CsePurity.countLocalUses, which ignores a name used only as a case scrutinee or destructuring root, so such a let is counted as dead. |
| `src/Compiler/GlobalOpt/MapTemplate.elm:124-126` | review; run 2026-10-27 | Stats.declinedCalleeLocalLSet is never incremented anywhere (no HOKind maps to it), so report always prints declinedCalleeLocalLSet=0: a dead census counter. |
| `src/Compiler/GlobalOpt/MapTemplate.elm:1185` | comment; run 2026-10-27 | argProvenance's MonoVarKernel Debug arm (giving PoisonArgTaint ArgMemberPoison) cannot be reached from scanWith: scanWith walks the arguments before calling argTaint, so a Debug kernel argument is already PoisonDebug. |
| `src/Compiler/GlobalOpt/MonoInlineSimplify.elm:118` | map | buildBodyLookup decides recursion from callEdges, but optimize returns callEdges = Array.empty; when inline.pruneDead is off nothing restores edges, so Backend's buildBodyLookup on the final graph treats every spec as non-recursive and admits recursive helpers its docstring says are excluded. |
| `src/Compiler/GlobalOpt/MonoInlineSimplify.elm:171` | comment; run 2026-10-27 | buildBodyLookup decides recursion from the graph's callEdges, which optimize empties. With inline.pruneDead off, pruneAfterInline does not restore the edges, so every spec counts as non-recursive and recursive MonoDefine bodies enter the reify-time lookup. |
| `src/Compiler/GlobalOpt/MonoInlineSimplify.elm:175` | review; run 2026-10-27 | buildBodyLookup decides recursion from the graph's callEdges, but optimize returns callEdges = Array.empty (line 1004). If Prune.pruneAfterInline does not restore the edges (inline.pruneDead off), every MonoDefine counts as non-recursive. Recursive bodies then enter the lookup, which its consumer... |
| `src/Compiler/GlobalOpt/MonoInlineSimplify.elm:5259` | comment; run 2026-10-27 | censusDeadDefs runs on every simplifyLetChain call, so in every fixpoint round. A dead binding that is kept (a bare kernel reference or an impure call) is counted again each round, inflating deadLets and deadBareKernelVar. |
| `src/Compiler/GlobalOpt/MonoInlineSimplify.elm:5925` | review; run 2026-10-27 | countUsages' MonoDestruct arm keeps counting in `inner` even when the destructuring binds `name`, unlike substitute/renameLocal, which stop there. A use of a shadowing destructure binder is therefore counted as a use of the outer name, which can block forwarding or dead-let dropping. This is late... |
| `src/Compiler/GlobalOpt/PreMono/EtaExpand.elm:1189` | map | betaLambda's fewer-args fallback rebuilds the lambda as `TOpt.Function Nothing params body (TOpt.metaOf body)`, giving the lambda node its body's type instead of a function type (documented as unreachable). |
| `src/Compiler/GlobalOpt/PreMono/LiftClosedArgs.elm:326` | review; run 2026-10-27 | The namesCycle test only runs in InDefine scope, but VarCycle is only emitted inside a recursive group's own definitions (LocalOpt/Typed/Expression.elm:394,407), which are walked as InCycle/InTailDef; so declinedVarCycle appears always 0 (dead branch). |
| `src/Compiler/GlobalOpt/Staging/ProducerInfo.elm:230` | map | Kernel producers are recorded under ProducerKernel ("kernel:" ++ nodeId), key K:kernel:<n>, but GraphBuilder.producerFromExpr creates kernel nodes as ProducerKernel (home ++ "." ++ name), key K:<home>.<name>. Solver.kernelSegForNode looks up the graph's key in naturalSeg and never finds it, so th... |
| `src/Compiler/Json/String.elm:189-190` | comment, review, rework | The `Escape word` fallback, which writes a backslash and then the character, can never run. chompChunks only builds Escape 'n', Escape '"' and Escape '\\' (lines 86-92), and writeChunksHelp matches each of those earlier and writes it back as the literal character. So on any input, the Escape-chun... |
| `src/Compiler/LocalOpt/Erased/Case.elm:126` | review; run 2026-10-27 | In treeToDecider's `DT.Decision path edges Nothing` arm, the `[]` (line 126) and `[ ( _, singleTree ) ]` (line 129) sub-cases are dead code, because the earlier arms at lines 104 and 108 already match those shapes. |
| `src/Compiler/LocalOpt/Erased/Expression.elm:252` | comment; run 2026-10-27 | The Opt.VarLocal arm in the Case lowering (and its twin in optimizeTail) can never match, because optimize returns TrackedVarLocal for local variables. This is dead code. |
| `src/Compiler/LocalOpt/Typed/DecisionTree.elm:231` | review | The HintCustom "" branch for tuples of four or more elements (also at line 559) is dead code: Canonicalize/Pattern.elm:315 rejects such tuple patterns with TupleLargerThanThree. |
| `src/Compiler/LocalOpt/Typed/Expression.elm:818` | map | catchMissing ignores its fallback argument and returns the tracker unchanged. lookupLocalType crashes on a missing local, so the intended fallback to the use-site type never happens. |
| `src/Compiler/MonoSolver/Engine.elm:2007-2010` | comment, review; run 2026-10-27 | On the LSS-off arm of enqueueSpec, hit is hard-coded to Registry.CreatedNew. As a result bumpKeyedHit never counts anything there and storedChanged is always False, so the dirty-marking path cannot run on this arm. This is dead logic, probably left behind from a removed arm. |
| `src/Compiler/MonoSolver/LssInfer.elm:1938` | comment; run 2026-10-27 | joinTunnels is dead code. KernelSetFacts.ParamSetFlow has only PSFOpaque and PSFApplies, so kernelArgsGo (line 1962) never adds anything to tunnelsRev, and joinTunnels is always called with []. |
| `src/Compiler/MonoSolver/LssInfer.elm:1942` | review; run 2026-10-27 | joinTunnels is always called with an empty list: kernelArgsGo never extends tunnelsRev, because ParamSetFlow has no tunnelling constructor. The code is dead (the commenting agent also reported this). |
| `src/Compiler/MonoSolver/Monomorphize.elm:3707-3711` | comment, review; run 2026-10-27 | processItem's `BitSet.member specId s.inProgress` check can never be true: only the item being processed is in progress, and every Ok path (finishNode, the no-body retranslation branch) removes it before the next item, while Err paths end the drain. Dead logic; recursion is not stopped by it. |
| `src/Compiler/MonoSolver/Translate.elm:4133` | comment, review; run 2026-10-27 | poisonKernelPerParam never adds anything to tunnelsRev, because ParamSetFlow has only PSFOpaque and PSFApplies. joinKernelTunnels (line 4160) is therefore always called with an empty list, so the tunnel-join path for Positional kernel rows is dead code. |
| `src/Compiler/Monomorphize/AssignMVarIds.elm:119-122` | comment, review; run 2026-10-27 | Ctx.defKey is set (rewriteNodes, rewriteAnnotation, assignIdsToType) but never read anywhere: a dead field. |
| `src/Compiler/Monomorphize/Monomorphize.elm:404` | comment; run 2026-10-27 | The inProgress skip branch can never run: inProgress is set and cleared within the same processOneWorkItem call, and Specialize.enqueueSpec queues each id at most once. |
| `src/Compiler/Nitpick/PatternMatches.elm:201` | map | The nTuple (#N) union declares numArgs = 3 regardless of tuple size, while isUseful uses List.length args for Ctor rows. Specializing a matrix mixing #N rows and wildcard rows would give rows of different lengths. This is currently unreachable because canonicalization rejects tuples larger than t... |
| `src/Compiler/Parse/Expression.elm:349` | map, review | accessibleRecord and chompRecordAccessField (lines 349-366) are called by nothing except each other. This is dead code, and it reports a missing access field as E.RecordOpen. |
| `src/Compiler/Parse/Expression.elm:438-439` | review; run 2026-10-27 | `accessibleRecord` and `chompRecordAccessField` are dead code: nothing calls them except each other. |
| `src/Compiler/Reporting/Doc.elm:485` | comment | isWindows is hard-wired to False, so the ASCII branches of cycleTop/cycleLn/cycleMid/cycleEnd are dead code; those ASCII forms also differ in shape from the Unicode ones ('\| \|' has no arrow, '+-<---+' puts the arrow on the bottom line). |
| `src/Compiler/Reporting/Error/Syntax.elm:1639` | comment | Code.Other branches test for characters that Code.whatIsNext always classifies as Operator (in Symbol.binopCharSet): '!' and '%' here, and '+','-','*','/','^','&','\|','!','%' in the list at line 2345, so those entries can never match (dead logic). |
| `src/Compiler/Reporting/Error/Syntax.elm:7269` | comment | PWildcardReservedWord is constructed by no parser in src, so its report branch and codec branches are unreachable. |
| `src/Mlir/Bytecode/AttrType.elm:213` | comment | The unknown-location test compares only name == "unknown" and start == 0:0, ignoring end; a Loc for a real file named "unknown" at 0:0, or one with a non-zero end, would be encoded as UnknownLoc (same in locKey at line 204). Unreachable today because only Loc.unknown is ever built. |
| `src/Mlir/Bytecode/DialectSection.elm:305` | comment | The `_ -> acc` branch of addOpNameToDict is unreachable because String.split never returns an empty list; harmless dead code. |
| `src/Mlir/Bytecode/IrSection.elm:293` | map | encodeRegion's numBlocks == 0 branch is unreachable (numBlocks is 1 + named blocks); dead code. |
| `src/Mlir/Bytecode/IrSection.elm:403` | comment, review | The `if numBlocks == 0` branch in encodeRegion is dead code: numBlocks is `1 + List.length namedBlocks` and can never be 0. |
| `src/Mlir/Bytecode/StreamEncode.elm:410` | comment, review | The `_ ->` branch of addDialectOp's `case String.split "." fullName of` is unreachable, because String.split never returns an empty list. |
| `src/Mlir/Bytecode/StringTable.elm:175` | comment | The `_ ->` branches after String.split "." in addOpName (line 175, baseline 129) and in collectType's NamedStruct case (line 254, baseline 198) can never run, because String.split always returns at least one element. This dead code does no harm. |

### Kind 3: live only under a setting (3)

| Location | Reported by | Claim |
|---|---|---|
| `src/Common/Format/Render/Box.elm:756` | review; run 2026-10-27 | The @docs narrowing of a default header's exposing list is dead code. It runs only when the module has no header, and then docs is always Nothing because formatModu reads docs only from the header (line 1161). |
| `src/Compiler/Generate/MLIR/Context.elm:402` | rework | When borrow.oracleOpt is on, Backend.deriveOracleFacts (Backend.elm:150) computes the oracle facts and Backend.elm:192 and :334 store them in the context through Ctx.withOracleFacts. No code in src reads ctx.oracleFacts, so switching oracleOpt on costs compile time but cannot change the emitted M... |
| `src/Compiler/GlobalOpt/PreMono/EtaExpand.elm:1640` | map | willExpand (used by buildPostArity) omits expandDefinition's constructor-alias refusal, and buildPostArity/rewriteGraph differ on the flags decoder and the etaOnly allow-list; for those globals Gate.arity predicts the declared arity although the definition is not expanded, so the merge rule can m... |
