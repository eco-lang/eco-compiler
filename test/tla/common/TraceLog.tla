------------------------------ MODULE TraceLog ------------------------------
(***************************************************************************)
(* Trace validation, the part every trace spec shares                      *)
(* (plans/threaded-gc-tla-verification.md §6.3; test/tla/README.md,        *)
(* "Trace validation").                                                    *)
(*                                                                         *)
(* A model's Trace<Name>.tla EXTENDS the model and TraceInOrder or        *)
(* TraceAnyOrder (both EXTEND this module). It reads                       *)
(* the merged log that test/tla/trace/merge_trace.py wrote (the runner     *)
(* puts it next to the spec as trace.ndjson; $ECO_TLA_TRACE_FILE names     *)
(* another file) and constrains the model's Next: every step either        *)
(* matches the next logged event or is a hidden step (a model step the     *)
(* code does not log).                                                     *)
(*                                                                         *)
(* Two ways to consume the log; a spec EXTENDS one of the two modules     *)
(* that EXTEND this one:                                                   *)
(*  - TraceInOrder: in log order (TL*, one counter tl). Cheap. Right when  *)
(*    the events are on one thread, or when the model steps of events the *)
(*    log leaves unordered commute.                                        *)
(*  - TraceAnyOrder: in any order the log allows (TP*, one counter per     *)
(*    thread, tpos): event e of thread u may be matched once every thread *)
(*    v has matched e.vc[v] of its events. This is the plan's "where the   *)
(*    order is ambiguous, the trace spec admits either order".             *)
(*                                                                         *)
(* ACCEPTANCE. The spec's configuration lists one invariant, TLUnmatched   *)
(* (in order) or TPUnmatched (any order): "some event is still            *)
(* unmatched". TLC reports it                                              *)
(* violated exactly when a behaviour has matched the whole log: the trace  *)
(* is ACCEPTED (and TLC stops there). If TLC finishes with no error, no    *)
(* behaviour matches the log: the trace is REJECTED. Every step that       *)
(* matches an event prints the new furthest match ("TRACE-PROGRESS", n,    *)
(* ...) the first time any behaviour gets that far, so the runner can      *)
(* name the first event no behaviour could match.                          *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, Json, IOUtils, TLC

LOCAL Ext == INSTANCE TLCExt

TraceFile == IF "ECO_TLA_TRACE_FILE" \in DOMAIN IOEnv
             THEN IOEnv.ECO_TLA_TRACE_FILE ELSE "trace.ndjson"
TraceLines == ndJsonDeserialize(TraceFile)
\* The header: the harness's own fields, plus threads, tev and count (merger).
TraceHdr == TraceLines[1].hdr
\* The events, in the merger's order: TraceLog[i].i = i.
TraceLog == [j \in 1..(Len(TraceLines) - 1) |-> TraceLines[j + 1]]
TraceLen == Len(TraceLog)
TraceThreads == {TraceHdr.threads[j] : j \in DOMAIN TraceHdr.threads}
\* How many events have this name (e.g. to size a model bound from the log). The
\* merger counts them in the header: a set comprehension over the log, used in a
\* cfg's `<-` bound, made TLC's initial states take minutes.
TraceCount(name) == IF name \in DOMAIN TraceHdr.counts THEN TraceHdr.counts[name] ELSE 0
\* A field of an event, or d when the event does not carry it.
TraceGet(e, f, d) == IF f \in DOMAIN e THEN e[f] ELSE d
\* An event that stands for "no event": the log is used up.
NoEvent == [ev |-> "", t |-> "", i |-> 0, nxt |-> ""]

\* Printed each time some behaviour matches further than any before
\* (register 17; the runner reads the largest n).
TraceProgress(n, e) ==
    LET old == Ext!TLCGetAndSet(17, LAMBDA a, b : IF a > b THEN a ELSE b, n, 0)
    IN IF n > old THEN PrintT(<<"TRACE-PROGRESS", n, e.i, e.t, e.ev>>) ELSE TRUE

=============================================================================
