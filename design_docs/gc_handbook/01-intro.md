# 1. Introduction to Garbage Collection

Garbage collection is the automatic reclamation of memory occupied by objects that are no longer in use by a program. This chapter establishes the foundational concepts, terminology, and metrics used throughout the study of automatic memory management, and examines why garbage collection has become essential to modern programming languages.

---

## 1.1 The Case for Automatic Memory Management

Developers increasingly turn to managed languages and runtime systems for the security, flexibility, and productivity they offer. Because many services are provided by the virtual machine, programmers write less code. Code is safer when the runtime verifies it as it loads, checks array bounds, and manages memory automatically. Deployment costs are lower since applications can target different platforms more easily. Consequently, programmers spend a greater proportion of development time on application logic rather than infrastructure concerns.

Almost all modern programming languages use dynamic memory allocation. This allows objects to be allocated and deallocated even when their total size was not known at compile time, and when their lifetime may exceed that of the subroutine that allocated them. A dynamically allocated object is stored in a heap, rather than on the stack (in the activation record of the procedure that allocated it) or statically (where the name binds to a storage location known at compile time).

Heap allocation is particularly important because it allows the programmer to:

- Choose the size of new objects dynamically, avoiding program failure from exceeding hard-coded array limits
- Define and use recursive data structures such as lists, trees, and maps
- Return newly created objects to a parent procedure (enabling factory methods)
- Return a function as the result of another function (closures and suspensions in functional languages)

Heap-allocated objects are accessed through references. Typically, a reference is a pointer to the object (its memory address). However, a reference may alternatively refer to an object indirectly through a handle, which offers the advantage of allowing an object to be relocated by updating only its handle rather than every reference throughout the program.

---

## 1.2 The Problems with Explicit Deallocation

Any non-trivial program running in finite memory needs to recover storage used by objects no longer needed by the computation. Memory used by heap objects can be reclaimed using explicit deallocation (C's `free` or C++'s `delete`) or automatically by the runtime system using reference counting or tracing garbage collection. Manual reclamation risks programming errors that arise in two ways.

### Dangling Pointers

Memory may be freed prematurely while there are still references to it. Such a reference is called a **dangling pointer**. If the program subsequently follows a dangling pointer, the result is unpredictable. The runtime system may clear the space, allocate a new object there, or return the memory to the operating system. The best outcome is an immediate crash; more likely, the program continues for millions of cycles before crashing (making debugging difficult) or runs to completion producing incorrect results.

### Memory Leaks

The programmer may fail to free an object no longer required, leading to a **memory leak**. In small programs, leaks may be benign, but in large programs they lead to substantial performance degradation as the memory manager struggles to satisfy allocation requests, or to failure when the program runs out of memory. Often a single incorrect deallocation leads to both dangling pointers and memory leaks.

### The Fundamental Problem

Programming errors of this kind are particularly prevalent in the presence of sharing, when two or more subroutines hold references to an object. This is even more problematic for concurrent programming when multiple threads may reference an object. As Wilson [1994] points out, "liveness is a global property," whereas the decision to call `free` on a variable is a local one. Safe deallocation of an object is complex because determining whether any other part of the program still needs the object requires global knowledge that local code does not possess.

---

## 1.3 Benefits of Garbage Collection

Automatic dynamic memory management resolves many of these issues. Garbage collection prevents dangling pointers: an object is reclaimed only when there is no pointer to it from a reachable object. Conversely, in principle all garbage is guaranteed to be freed—any object that is unreachable will eventually be reclaimed by the collector—with two caveats. First, tracing collection uses a definition of "garbage" that is decidable and may not include all objects that will never be accessed again. Second, implementations may for efficiency reasons choose not to reclaim some objects.

Only the collector releases objects, so the double-free problem cannot arise. All reclamation decisions are deferred to the collector, which has global knowledge of the structure of objects in the heap and the threads that can access them. The problems of explicit deallocation were largely due to the difficulty of making a global decision in a local context. Automatic memory management finesses this problem.

Memory management is fundamentally a software engineering issue. Well-designed programs are built from components that are highly cohesive and loosely coupled. Increasing cohesion makes programs easier to maintain; ideally, a programmer should understand a module's behavior from that module alone. Reducing coupling means one module's behavior does not depend on another's implementation. Explicit memory management goes against sound software engineering principles of minimal communication between components. Garbage collection uncouples memory management from interfaces, improving reusability.

---

## 1.4 Comparing Garbage Collection Algorithms

Different collectors are designed with different workloads, hardware contexts, and performance requirements in mind. It is never possible to identify a "best" collector for all configurations—for every collector there is at least one benchmark that would run significantly faster with a different collector. The following metrics characterize and compare collectors.

### Safety

The prime consideration is that garbage collection should be **safe**: the collector must never reclaim the storage of live objects. Safety is the non-negotiable correctness criterion.

### Throughput

A common goal is that programs should run faster. The **mark/cons ratio** compares collector time (marking live objects) to mutator time (creating new objects). However, users want the application as a whole (mutator plus collector) to execute in as little time as possible. Since much more CPU time is typically spent in the mutator, it may be worthwhile trading some collector performance for increased mutator throughput.

### Completeness and Promptness

Ideally, garbage collection should be **complete**: eventually all garbage in the heap should be reclaimed. However, this is not always possible or desirable. Pure reference counting collectors cannot reclaim cyclic garbage. For performance reasons, it may be desirable not to collect the whole heap at every cycle—generational collectors segregate objects by age and concentrate effort on the youngest generation. **Promptness** refers to how quickly garbage is reclaimed after becoming unreachable; different algorithms vary in their promptness, leading to time/space trade-offs.

### Pause Time

An important requirement may be to minimize the collector's intrusion on program execution. Many collectors introduce **pauses** by stopping all mutator threads while collecting. Pauses should be as short as possible, especially for interactive applications or servers handling transactions. Mechanisms for limiting pause times include:

- **Generational collectors**: Frequently and quickly collect a small nursery region
- **Parallel collectors**: Stop the world but use multiple threads to reduce pause duration
- **Concurrent/incremental collectors**: Interleave collection work with mutator execution

Reporting pause times requires more than maximum or average values. **Minimum Mutator Utilisation (MMU)** and **Bounded Mutator Utilisation (BMU)** display concisely the minimum fraction of time spent in the mutator for any given time window, capturing both total GC time and maximum pause time.

### Space Overhead

Different memory managers impose different space overheads:

- **Per-object costs**: Reference counts, mark bits, forwarding pointers
- **Per-heap costs**: Copying collectors divide the heap into two semispaces, only one available to the mutator
- **Auxiliary data structures**: Mark stacks for traversal, bitmap tables for mark bits, remembered sets for concurrent or partitioned collectors

### Scalability and Portability

With multicore hardware ubiquitous, garbage collection must take advantage of parallel hardware. Some collection algorithms depend on operating system or hardware support (page protection, double mapping, specific atomic operations) which may not be portable.

---

## 1.5 Performance Considerations

A long-running criticism of garbage collection has been that it is slow compared to explicit memory management. While automatic memory management does impose a performance penalty, it is not as much as commonly assumed. Studies have measured that garbage collectors can match the execution time of explicit allocation provided they are given a sufficiently large heap (five times the minimum required). For more typical heap sizes, the garbage collection overhead averages around 17%.

Importantly, `malloc`/`free` also impose significant costs. The comparison is not between free automatic management and free manual management, but between the costs of each approach.

---

## 1.6 Experimental Methodology

Sound experimental practice requires that outcomes are valid even in the presence of bias. This requires repetitions and statistical comparison of results. Key considerations include:

- **Avoiding synthetic benchmarks**: Small-scale "toy" benchmarks do not reflect interactions in real programs
- **Distinguishing startup from steady state**: Managed runtimes have warm-up effects (class loading, JIT compilation)
- **Controlling for non-determinism**: Dynamic compilation is a major source of variation
- **Reporting distributions**: A single figure, even with confidence intervals, is insufficient because memory management involves space/time trade-offs
- **Varying heap sizes**: Results for a single heap size cannot be taken seriously; small configuration changes can cause large behavioral changes (the "chaotic" nature of GC)

---

## 1.7 Core Terminology

### The Heap

The **heap** is either a contiguous array of memory words or a set of discontiguous blocks. Key terms:

- **Granule**: Smallest unit of allocation (typically word or double-word)
- **Chunk**: Large contiguous group of granules
- **Cell**: Smaller contiguous group of granules (may be allocated, free, or unusable)
- **Object**: Cell allocated for use by the application
- **Field/Slot**: Subdivision of an object that may contain a reference or scalar value
- **Header**: Metadata stored with an object, commonly at its head
- **Block**: Aligned chunk of a particular size (usually power of two)
- **Card**: 2^k aligned chunk smaller than a page, used for remembering cross-space pointers

### The Mutator and Collector

Following Dijkstra et al [1976, 1978], a garbage-collected program divides into two semi-independent parts:

- **Mutator**: Executes application code, allocates new objects, mutates the object graph by changing reference fields. Reference fields may be in heap objects or in roots (static variables, thread stacks).
- **Collector**: Executes garbage collection code, discovers unreachable objects and reclaims their storage.

A program may have multiple mutator threads (collectively acting as a single actor over the heap) and one or more collector threads.

### Roots and Reachability

The **roots** are pointers held in storage directly accessible to the mutator without going through other objects—typically static/global storage and thread-local storage (stacks). Objects referred to directly by roots are **root objects**.

An object is **live** if it will be accessed at some time in the future. Unfortunately, liveness is undecidable. Instead, we use **reachability**: an object is reachable if it can be reached by following a chain of pointers from the roots.

More formally, define the points-to relation: M →f N if field f of M contains a pointer to N. An object N is **directly reachable** from M (written M → N) if some field of M points to N. The set of reachable objects is the transitive closure from Roots under this relation:

```
reachable = { N ∈ Nodes | (∃r ∈ Roots : r → N) ∨ (∃M ∈ reachable : M → N) }
```

Unreachable objects are certainly dead and can safely be reclaimed. Any reachable object may still be live and must be retained.

---

## 1.8 Mutator Operations

As mutator threads execute, they perform operations of interest to the collector:

### New Operation

Obtains a new heap object from the allocator:

```pseudo
New():
    return allocate()
```

### Read Operation

Accesses an object field and returns its value:

```pseudo
Read(src, i):
    return src[i]
```

### Write Operation

Modifies a particular location in memory:

```pseudo
Write(src, i, val):
    src[i] ← val
```

Specific memory managers may augment these basic operations with **barriers**—actions that result in synchronous or asynchronous communication with the collector. We distinguish **read barriers** and **write barriers**, which become important for concurrent and generational collectors.

---

## 1.9 Atomic Operations

In the face of concurrency between mutator threads, collector threads, and between mutator and collector, certain code sequences must appear to execute atomically. For example, stopping mutator threads makes garbage collection appear atomic: mutators never see intermediate collector states.

When running the collector concurrently with the mutator, New, Read, and Write operations may need to appear atomic with respect to the collector and/or other mutator threads. The keyword `atomic` marks operations whose steps must appear to execute indivisibly—other operations appear to execute either before or after, never interleaved.

---

## 1.10 The Four Fundamental Approaches

All garbage collection schemes are based on one of four fundamental approaches:

1. **Mark-Sweep**: Trace reachable objects and mark them; sweep the heap freeing unmarked objects
2. **Mark-Compact**: Like mark-sweep, but relocate live objects to eliminate fragmentation
3. **Copying Collection**: Copy live objects to a new space, leaving garbage behind
4. **Reference Counting**: Maintain counts of references to each object; free when count reaches zero

Different collectors combine these approaches—for example, collecting one region with one method and another with a different method. Generational collectors often use copying for the young generation and mark-sweep or mark-compact for the old generation.

---

## 1.11 Summary

Garbage collection is motivated by the difficulty of correct manual memory management in the presence of sharing and concurrency. Automatic memory management prevents dangling pointers and (mostly) memory leaks, while decoupling memory management from module interfaces. Collectors are compared by safety, throughput, completeness, pause time, space overhead, and scalability. The key abstraction is reachability: unreachable objects are garbage and can be reclaimed. The mutator performs New, Read, and Write operations that may be augmented with barriers to coordinate with the collector. All GC algorithms build on mark-sweep, mark-compact, copying, or reference counting, often in combination.
