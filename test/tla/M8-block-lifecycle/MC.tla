--------------------------------- MODULE MC ---------------------------------
(***************************************************************************)
(* M8's constants that a .cfg cannot write: the class tables, the          *)
(* scenario filters (Keep) and a compact view of a counterexample (ALIAS). *)
(* Geometry in 8-byte granules: G = 6 is one page (alloc_buffer_size),     *)
(* CellSize[0] = 2 is MIN_FREE_CELL_SIZE (16 B), a header is 1 granule.    *)
(***************************************************************************)
EXTENDS BlockLifecycle

\* two uniform classes (16 B, 24 B: every small class is a multiple of 8, so a request
\* fills its cell) and one mixed-only class (32 B, the 16K..64K classes)
MC_Cells6 == [c \in 0..2 |-> CASE c = 0 -> 2 [] c = 1 -> 3 [] OTHER -> 4]
\* a medium-like uniform class: a 3-granule request takes a 4-granule cell (the real
\* medium classes step by powers of two), so the bag rung's exact carve
\* (allocateFromBagPage step 1) differs from rung 4's class-sized one (CR-029)
MC_Cells6b == [c \in 0..2 |-> CASE c = 0 -> 2 [] c = 1 -> 4 [] OTHER -> 5]
MC_Off == -1        \* DemoteMax: demotion off (demote_live_fraction = 0.0)

\* Keep: every allocation outcome (all rows but CR-035's) ...
MC_All(x) == TRUE
\* ... or none that overwrites a rooted object: CR-035's rows, so that their
\* counterexamples are the stale-entry story alone, not CR-018's overwrite. (A
\* CONSTRAINT or ACTION_CONSTRAINT would not do: TLC still checks the invariants on
\* the states they prune.)
MC_NoLiveOverwrite(x) == ~OverwritesLive(x)

\* A compact view of a counterexample (ALIAS MC_Alias): mem shows each granule's
\* header ("o3": object 3's, "f2": Tag_Free of 2 granules, ".": never written).
HS(x) == CASE x.t = "o" -> "o" \o ToString(x.v) [] x.t = "f" -> "f" \o ToString(x.v) [] OTHER -> "."
MC_Alias ==
    [pc |-> pc, ops |-> h.ops, phase |-> h.phase, sweep |-> <<h.swIdx, h.swCur>>, color |-> h.color,
     blocks |-> [i \in {j \in Ids : h.blk[j].live} |->
                   <<"slot", h.blk[i].s,
                     IF h.blk[i].lg THEN "large" ELSE IF h.blk[i].cls = Mixed THEN "mixed"
                     ELSE "u" \o ToString(h.blk[i].cls),
                     h.blk[i].st, "lb", h.blk[i].lb, "fs", h.blk[i].fs, "marks", h.blk[i].marks,
                     "eoo", h.blk[i].eoo>>],
     order |-> h.order, freeIds |-> h.freeIds, owner |-> h.owner, bag |-> h.bag, ext |-> h.ext,
     bump |-> h.bump, mem |-> [s \in Slots |-> [g \in Offs |-> HS(h.mem[s][g])]],
     objs |-> [o \in {x \in Objs : h.objs[x].st # "N"} |->
                 <<h.objs[o].st, "at", h.objs[o].s, h.objs[o].off, "sz", h.objs[o].sz,
                   IF h.objs[o].root THEN "rooted" ELSE "dropped", IF h.objs[o].ylos THEN "ylos" ELSE "-",
                   "age", h.objs[o].age>>],
     fl |-> h.fl, flarge |-> h.flarge, part |-> h.part, cur |-> h.cur,
     index |-> {<<a, h.index[a]>> : a \in {x \in Addrs : h.index[x] # 0}},
     meta |-> [m \in 1..h.mhw |-> h.meta[m]], owned |-> h.owned, freeMeta |-> h.freeMeta,
     toReach |-> h.toReach, lie |-> h.lie, bad |-> h.bad]
=============================================================================
