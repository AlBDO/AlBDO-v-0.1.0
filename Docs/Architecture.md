# Albedo Renderer Engine — Architecture Guide

> This document captures everything planned, designed, and finalized for the Albedo renderer engine. It is a living architecture reference, not a code document. Implementation details are intentional omissions — this is the blueprint, not the build.

---

## The Core Problem Albedo Solves

Traditional React-style renderers treat every component identically. Every render cycle, every component goes through the same analysis path — hash check, dependency resolution, priority scoring, phase assignment, batch allocation. For a real-time dashboard or any application with mixed component volatility, this is wasteful by design. A static navigation bar has no business being analyzed with the same urgency as a live price ticker updating every 80ms.

Albedo's answer is **explicit phase separation**: components are categorized, routed, scheduled, and rendered through paths that match their actual runtime behaviour. The architecture is deterministic, cache-line aware, and designed so that the common case (nothing changed, or only hot components changed) is as close to zero-cost as physically possible on the hardware.

---

## The Highway Metaphor

The entire pipeline is modelled as a 4-lane highway. This is not just a conceptual metaphor — it directly maps to implementation decisions.

**4 cache pipelines run in parallel.** Each lane owns a segment of the component graph. Lanes do not share mutable state during traversal. They communicate only through the π-arch message layer described later.

**Overtake zones every 100 components.** These are hard yield points. When the analyzer has been running for 2ms and hits an overtake zone, it must yield execution to the renderer. The renderer drains its queue. The analyzer resumes. This is the mechanism that prevents long analysis passes from starving the renderer — the 2ms budget is a hard constraint, not a soft suggestion.

**The sentinel ring sits beside the highway.** It does not block lanes. It is a separate, always-running circular structure that handles hot-set components independently of the main 4-lane pipeline.

---

## Component Tier System

Every component in Albedo is assigned a tier at analysis time. Tier assignment is permanent for the lifetime of a pipeline run and drives every downstream routing decision.

### Tier A — Static Slice Eligible
Components with no hooks, no async operations, no non-deterministic behaviour, and no side effects. They render identically given the same props every time. These are pre-rendered into static slices at compile time and served from cache at request time with zero engine involvement. The renderer does not touch them at runtime unless their source changes.

Detection happens in `src/runtime/static_slice.rs`. A component fails Tier A eligibility if it contains: hooks, async/await, Math.random, Date.now, or any external I/O reference.

### Tier B — Deferred
Components that need to render but are not on the critical path. They can be deferred until after the above-fold content is painted. The scheduler places these in a secondary queue and processes them after Tier A and hot-set renders are complete.

### Tier C — On-Demand
Components gated behind user interaction or route transitions. They are not analyzed or rendered until explicitly triggered. The hydration system manages their activation.

### Hot Set — Outside the Tier System
Components registered into the hot set bypass tier classification entirely. They have their own path through the sentinel ring and are never touched by the analyzer on update. Hot set is a runtime designation, not a compile-time one. Registration happens at startup or on explicit reconfiguration — never on the hot path.

---

## The Component Graph

Foundation of the entire pipeline. Lives in `src/graph.rs`.

**Structure:** `DashMap`-backed adjacency representation. Nodes are `ComponentId` values (wrapping a `u64`). Edges represent import dependencies — if A imports B, there is a directed edge from A to B.

**Properties maintained:**
- Cycle detection on every `add_dependency` call
- In-degree calculation for topological ordering
- Concurrent read access from multiple threads without locks (DashMap)
- `get_dependencies` and `get_dependents` both O(1) on average

**Topological sort outputs level sets** — groups of components that have no dependencies on each other within the group and can therefore be processed in parallel. Level 0 is the set of all components with no dependencies. Level 1 is the set of all components whose only dependencies are in Level 0. And so on.

---

## The Analyzer

Lives in `src/analyzer.rs`. Runs after the graph is built, before the scheduler.

### What it produces per component
- **Priority score** — a float derived from weight, bitrate, above-fold status, LCP candidacy, and interactivity classification
- **Phase assignment** — calculated using a π-based formula that maps components onto a render phase between 0 and 2π. Components near 0 render first. Components near 2π are the last to render.
- **Estimated render time** — used by the scheduler to budget overtake zones
- **Tier classification** — A, B, or C as described above

### Phase calculation rationale
The π-arch phase formula was chosen deliberately. Linear ordering (1, 2, 3...) creates cliff edges where priority 100 and priority 99 are treated nearly identically but priority 100 and priority 1 are treated as maximally different. The π-based distribution creates a smooth gradient across the component population, concentrating the most important components near 0 without creating artificial cliffs.

### Parallel analysis path
When the component population exceeds 50 (PARALLEL_THRESHOLD), analysis is distributed across crossbeam scoped threads — one chunk per thread, each thread pinned to a physical core via `core_affinity`. Results are collected into a `DashMap` and merged after all threads complete.

Below the threshold, analysis runs serially. The overhead of spawning threads and pinning cores for 10 components is not worth it.

---

## Parallel Topological Sort

Lives in `src/parallel_topo.rs`.

### The threshold decision
Below 20 components (PARALLEL_THRESHOLD): serial sort via `src/topological.rs`. Above 20: parallel sort via crossbeam scoped threads.

### How it works above the threshold
Each level of the topological sort is processed as follows:
1. The current level (set of nodes with in-degree 0) is chunked across N threads where N = min(num_cpus, level_size)
2. Each thread is pinned to a physical core via `core_affinity`
3. Each thread walks its chunk and accumulates a per-dependent decrement count into a shared `DashMap<ComponentId, usize>`
4. After all threads complete (crossbeam scope guarantees this), decrements are applied serially
5. Nodes whose in-degree reaches 0 become the next level

### The critical DashMap design decision
The accumulator map stores `usize` counts, not `()` presence flags. A node that is a dependent of 25 nodes in the current level needs its in-degree decremented by 25. A presence-flag map (DashMap<ComponentId, ()>) would only decrement it by 1 — this was a real bug in the original implementation that was discovered and fixed. The count-based design is not an optimisation, it is correctness.

### Thread and core assignment
- Thread count: `min(num_cpus, work_size).max(1)`
- Chunk size: `work_size.div_ceil(n_threads)`
- Core assignment: round-robin via `core_ids.get(i % core_ids.len())`

Core pinning prevents the OS scheduler from migrating threads between cores mid-execution, which would invalidate the L1/L2 cache state that the thread has been building up. On a 16-core machine this is a measurable difference at scale.

---

## The Incremental Cache

Lives in `src/incremental.rs`.

### What it does
Tracks file hashes for every component source file. On each analysis pass, it compares current hashes against stored hashes. Components whose source has not changed are served from cache — they skip the analyzer entirely.

### Cascade invalidation
If component A depends on component B and B's hash changes, A is also invalidated even if A's own source has not changed. This is conservative but correct — A's render output may depend on B's exports, and stale output is worse than a cache miss.

### Structure
- `DashMap<PathBuf, FileHash>` for current hashes
- `DashMap<ComponentId, ()>` for the invalidated set (components that need reanalysis)
- Cache can be persisted to disk and reloaded across process restarts

### Relationship to the sentinel ring
The incremental cache's `invalidated` DashMap is structurally adjacent to the sentinel ring but they are separate concerns. The cache handles compile-time and cold-start invalidation. The sentinel ring handles runtime hot-set updates. They do not share state.

---

## The Sentinel Ring

New — to be built. Lives in `src/runtime/hot_set.rs`.

### The problem it solves
Hot-set components update every 50–100ms regardless of what the rest of the application is doing. Running them through the full analyzer pipeline on every update is wasted work. The system already knows they need to re-render. The sentinel ring is the mechanism that makes acting on that knowledge zero-cost when nothing is dirty.

### Structure
A circular singly-linked list with one sentinel node (the loop termination marker) and one node per registered hot-set component. The sentinel has no dirty bit — it is purely a structural anchor.

Each regular node holds:
- A `ComponentId`
- An atomic dirty bit (`AtomicU8`, not `AtomicBool` — room for priority encoding later)
- A pointer to the next node (`NonNull<RingNode>`)

The dirty bit and pointer are the only fields accessed on the hot path.

### Cache line isolation
Each node is wrapped in `CachePadded` from `crossbeam::utils`. This pads each node to a full cache line (64 bytes on x86-64, 128 bytes on aarch64). Without this, writing to one node's dirty bit invalidates the cache line containing adjacent nodes, and the scheduler thread stalls on every update from any data source. With it, writes to different nodes are completely independent at the hardware level.

### The global dirty counter
A single `AtomicU32` beside the ring. Every `mark_dirty` call increments it. Every time drain clears a dirty bit it decrements it. The scheduler reads this counter before touching the ring at all. If it reads zero, the entire ring traversal is skipped — one atomic load is the total cost of a clean frame. This is the primary performance property of the sentinel ring design.

### Memory ordering
- `mark_dirty` bit flip: Release — ensures the scheduler sees all writes that happened before the flip
- Dirty counter increment: AcqRel
- Scheduler counter check: Acquire — ensures the scheduler sees the Release from mark_dirty
- Dirty bit clear in drain: Relaxed (the scheduler is the only one clearing bits)

Start with Acquire/Release everywhere. Tighten to Relaxed on specific operations only after benchmarks show the fence cost is measurable.

### Ownership model
`SentinelRing` owns all nodes exclusively. No shared ownership. No `Arc<RingNode>`. The ring is the sole allocator and sole deallocator of its nodes. `Drop` walks the ring and frees each node. This makes the unsafe surface area minimal and easy to audit — all unsafe is inside `SentinelRing`, the public API is fully safe.

### The Hot Set Registry
Separate from the ring. A `DashMap<ComponentId, RenderPriority>` that records which components are registered and at what priority. The registry is the source of truth for membership. The ring is the mechanism for runtime signalling.

Registration is capped at 32 components (HOT_SET_MAX). The 33rd registration is rejected. This cap exists to prevent the hot set from silently growing to encompass the entire application, which would make the ring O(n) per frame and defeat its purpose.

The ring is fixed-size after construction. Adding or removing components from the hot set requires rebuilding the ring. Rebuilds happen at startup or on explicit reconfiguration — never on the render hot path.

### Data flow through the ring

```
Data source update arrives
    → HotSetRegistry lookup (O(1) DashMap)
    → If registered: SentinelRing.mark_dirty(id)
        → Find node for this id
        → Flip dirty bit 0→1 (if already 1, nothing changes — no double-count)
        → Increment dirty counter
    
Scheduler frame starts
    → Read dirty_count (Acquire load)
    → If zero: return immediately, zero further work
    → If nonzero: walk ring from sentinel
        → For each node with dirty bit == 1:
            → Push ComponentId to render queue (ArrayQueue)
            → Clear dirty bit to 0
            → Decrement dirty counter
        → Stop when back at sentinel
    
Renderer drains ArrayQueue
    → Render each component
    → No analyzer involvement
```

---

## The π-Arch Inter-Lane Communication Layer

Planned — to be built after the scheduler.

### Purpose
The 4 pipeline lanes need a way to communicate. A component in lane 2 may depend on a result produced by lane 0. Without a communication layer, lane 2 would either stall waiting for lane 0 or make a stale decision based on the previous frame's data.

### Design
Lightweight string data tuples passed between lanes as messages. Not a general message bus — only the specific cross-lane dependency signals needed for render coordination.

Each message is a `(ComponentId, PhaseResult)` tuple. Lanes do not share memory. They communicate only through this message layer. This keeps the cache topology clean — each lane's working set stays in its own L1/L2 cache.

### Routing
A virtual kernel sits in front of the message layer and routes messages based on a Lagrange multiplier scoring function. The score weighs:
- Phase proximity (how close is the target component's phase to the message sender's phase)
- Priority differential (how much more important is the receiver than the sender)
- Lane load (how busy is the target lane)

The Lagrange scoring is not doing numerical optimization — it is a priority-weighted routing function that produces a deterministic routing decision given fixed inputs. Same inputs, same route, every frame.

---

## The Overtake Zone Scheduler

Next after the sentinel ring — to be built. Lives in `src/runtime/scheduler.rs`.

### What it does
Enforces the 2ms yield contract. The analyzer gets a 2ms budget per overtake zone. Every 100 components analyzed, the scheduler checks elapsed time. If elapsed >= 2ms, it forces a yield — the analyzer stops, the renderer runs, then the analyzer resumes from the exact position it stopped.

### Why this is necessary
Without a yield mechanism, a large component graph with 500 components could hold the analyzer for 20ms while the renderer starves. The overtake zone is the hardware-level equivalent of a cooperative yield — the analyzer voluntarily gives up the CPU to the renderer at known safe points.

### Integration point
The scheduler sits between `src/parallel.rs` (analyzer output) and `src/runtime/renderer.rs` (renderer input). The analyzer pushes completed component analyses into the scheduler's input queue. The scheduler decides whether to forward them to the renderer now or accumulate them until the overtake point.

### Frame accounting
Each scheduler frame tracks:
- Components rendered from the hot set ring (zero analyzer cost)
- Components rendered from the analyzer path
- Number of overtakes that occurred (how many times the analyzer yielded)
- Total frame time in milliseconds

This accounting feeds back into adaptive chunk sizing — if overtakes are happening too frequently (analyzer is consistently overrunning its budget), chunk sizes are reduced. If overtakes never happen, chunk sizes can be increased.

### Relationship to the sentinel ring
The scheduler must know the hot set before making yield decisions. A component in the hot set that arrives in the analyzer's queue should be discarded — it will be handled by the ring, not the analyzer. This is why the sentinel ring must exist before the scheduler is built.

---

## Adaptive Chunk Sizing

Already exists in `src/adaptive.rs`. L3 cache aware.

### How it works
Before deciding how many components to process in a batch, the adaptive system reads the L3 cache size of the current machine. It then estimates how many component analyses fit in L3 without evicting each other. The chunk size is set to this estimate.

The practical effect: on a machine with a large L3 (e.g. 32MB), chunks are larger and fewer thread synchronisation events occur. On a machine with a small L3 (e.g. 6MB), chunks are smaller and more frequent, keeping the working set resident in cache.

This runs automatically — no configuration required. The system adapts to the hardware it is running on.

---

## Static Slice System

Already exists in `src/runtime/static_slice.rs` and `src/bundler/static_slice.rs`.

### What it produces
For every Tier A component, a pre-rendered HTML string is generated at bundle time and stored in the static slice manifest. At request time, the renderer serves the pre-rendered string directly without invoking the QuickJS engine or any analysis machinery.

### Eligibility rules
A component is Tier A eligible only if it:
- Has no hooks (useState, useEffect, useRef, useCallback, useMemo, useContext, useReducer)
- Has no async operations
- Has no non-deterministic calls (Math.random, Date.now)
- Has no external I/O or side effects
- Returns the same output for the same props on every invocation

Any one of these conditions disqualifies a component from Tier A, and it falls to Tier B or C.

### Cache invalidation
Static slices are invalidated when:
- The component's source hash changes
- Any dependency's source hash changes (cascade)
- The manifest schema version changes

On invalidation, the slice is regenerated at the next bundle pass.

---

## The QuickJS Runtime Engine

Already exists in `src/runtime/quickjs_engine.rs` and `src/runtime/renderer.rs`.

### Role
Executes JSX/TSX components in a sandboxed JavaScript environment at render time. Used for Tier B and Tier C components that cannot be pre-rendered.

### Performance properties
- Cold render: component module loaded fresh, full parse and execution
- Warm render: module already loaded in the engine's module registry, execution only
- The module registry is populated at startup (prime cache) to eliminate cold renders for known components during request serving

### Fallback path
When the QuickJS engine cannot handle a component (unsupported syntax, missing dependency, parse error), the AST fallback renderer in `src/runtime/ast_eval.rs` attempts direct AST evaluation. If that also fails, the error is surfaced cleanly to the caller with the specific failure reason — no silent degradation.

---

## The Bundler Pipeline

Lives in `src/bundler/`. Separate concern from the runtime renderer but produces its inputs.

### What it does
Takes the component graph and analysis results and produces:
- **Bundle plan** — which components go in which chunks, vendor chunk assignments
- **Vendor chunks** — shared third-party dependency bundles (react, etc.)
- **Wrapper modules** — thin ES module wrappers around each component for the runtime module loader
- **Route prefetch manifest** — which chunks should be prefetched for each route
- **Static slices JSON** — the pre-rendered HTML for Tier A components
- **Precompiled runtime modules** — QuickJS-compiled bytecode for Tier B/C components

### Determinism guarantee
Bundle output is byte-identical across runs given identical input. Component ordering is sorted by ID then module path. Dependencies are sorted and deduplicated. Vendor chunks are sorted by name. Parallel batches are sorted. This is a hard requirement — non-deterministic output breaks incremental caching.

---

## The Node.js Bridge

Lives in `crates/albedo-node/`. NAPI-based bridge exposing Albedo's compiler to Node.js toolchains.

### Exposed API
- `analyzeProject(path, options)` — async, returns manifest V2
- `optimizeManifest(manifest, options)` — synchronous manifest normalization
- `getCacheStats()` — returns cache hit rate, invalidation counts, file tracking stats

### Panic safety
Every entry point from Node.js wraps its Rust execution in `std::panic::catch_unwind`. A panic in Rust would otherwise terminate the entire Node.js process. The panic payload is converted to a JavaScript Error and returned normally.

---

## The HTTP Server Runtime

Lives in `crates/albedo-server/`. Wraps the renderer for production request serving.

### Architecture
Stateless request handler — each request gets a renderer instance from the pool. The renderer instance holds a warmed module registry and the static slice cache. The server layer handles routing, connection management, and error classification.

Benign network errors (connection reset, broken pipe, EOF) are silently discarded. Real errors are surfaced.

---

## WebTransport 4-Stream Architecture

Planned for browser communication layer. Not yet implemented.

### Design
4 WebTransport streams, each corresponding to one pipeline lane. Stream assignment mirrors lane assignment — components in lane 0 are streamed over stream 0, etc.

### Why 4 streams instead of 1
A single stream creates a head-of-line blocking problem. If a large Tier B component stalls stream processing, Tier A content waiting behind it in the queue cannot be delivered to the browser even though it is already rendered. With 4 separate streams, Tier A traffic flows independently of Tier B/C traffic.

### Ordering within a stream
Each stream maintains its own sequence number. The browser reassembles content in sequence-number order within a stream. Across streams, the browser processes whatever arrives first — which by design will be Tier A content on stream 0.

---

## Dependency Map: What Depends on What

```
WebTransport Streams
    └── depends on → Scheduler (produces rendered output per lane)

Overtake Zone Scheduler
    └── depends on → Sentinel Ring (hot set path)
    └── depends on → Parallel Analyzer (cold path input)
    └── depends on → ArrayQueue (output to renderer)

Sentinel Ring
    └── depends on → Hot Set Registry (membership)
    └── depends on → CachePadded (false sharing prevention)
    └── depends on → ArrayQueue (output to scheduler)

π-Arch Communication Layer
    └── depends on → 4-Lane Pipeline (lane topology)
    └── depends on → Lagrange Scoring (routing decisions)

4-Lane Pipeline
    └── depends on → Parallel Topological Sort (level sets)
    └── depends on → Parallel Analyzer (phase + priority)
    └── depends on → Adaptive Chunk Sizing (batch size)

Parallel Topological Sort
    └── depends on → Component Graph (structure)
    └── depends on → crossbeam (scoped threads)
    └── depends on → core_affinity (thread pinning)
    └── depends on → DashMap (accumulator)

Parallel Analyzer
    └── depends on → Component Graph (component data)
    └── depends on → crossbeam (scoped threads)
    └── depends on → core_affinity (thread pinning)

Incremental Cache
    └── depends on → Component Graph (component IDs)
    └── depends on → File Hashing (change detection)

Static Slice System
    └── depends on → Tier Classification (Tier A eligibility)
    └── depends on → Incremental Cache (invalidation)

QuickJS Runtime
    └── depends on → Bundler (wrapper modules, precompiled bytecode)
    └── depends on → Static Slice System (Tier A bypass)
```

---

## Build Order

The implementation order is dictated by the dependency map above. You cannot build the scheduler before the sentinel ring. You cannot build the π-arch layer before the 4-lane pipeline topology is defined. Work bottom-up.

```
Step 1 — DONE    Component Graph + DashMap
Step 2 — DONE    Serial Topological Sort
Step 3 — DONE    Parallel Topological Sort (crossbeam + core_affinity)
Step 4 — DONE    Parallel Analyzer
Step 5 — DONE    Incremental Cache
Step 6 — DONE    Adaptive Chunk Sizing
Step 7 — DONE    Static Slice System
Step 8 — DONE    Bundler Pipeline
Step 9 — DONE    QuickJS Runtime Engine
Step 10 — NEXT   Sentinel Ring + Hot Set Registry
Step 11          Overtake Zone Scheduler
Step 12          π-Arch Inter-Lane Communication Layer
Step 13          4-Lane Highway with Phase-Separated Topology
Step 14          WebTransport 4-Stream Browser Delivery
```

---

## Performance Targets

These are the design targets the architecture is built around. They are not yet benchmarked — they are the goals.

| Metric | Target |
|--------|--------|
| Hot-set component frame cost (nothing dirty) | 1 atomic load |
| Hot-set component frame cost (n dirty) | O(n) ring walk, no analyzer |
| Analyzer yield latency at overtake zone | ≤ 2ms per zone |
| Tier A component render time | 0ms (static string serve) |
| Thread migration events during parallel sort | 0 (core pinning) |
| False sharing events on dirty bits | 0 (CachePadded) |
| Bundle output determinism | Byte-identical across runs |

---

## Invariants That Must Never Be Violated

These are the architectural rules. Breaking any of them degrades the system in ways that are difficult to debug.

1. **The hot set is bounded.** If unbounded growth is permitted, the ring becomes O(n) per frame and the zero-cost common case is destroyed.

2. **The sentinel ring is never rebuilt on the hot path.** Rebuild on startup or explicit reconfiguration only. Ring construction involves heap allocation — this is incompatible with microsecond frame budgets.

3. **Lane-to-lane communication happens only through the π-arch layer.** Lanes do not share memory directly. Any direct memory sharing between lanes reintroduces the cache coherency traffic that core pinning was designed to eliminate.

4. **Bundle output must be deterministic.** Any non-determinism in bundle output breaks the incremental cache. Every sort, dedup, and ordering decision in the bundler exists to enforce this.

5. **The parallel threshold is a performance boundary, not a correctness boundary.** The serial and parallel paths must produce identical output for identical input. Tests must verify this — the parallel path cannot be an optimised approximation of the serial path.

6. **Tier A components never touch the QuickJS engine at request time.** Any code path that allows a Tier A component to fall through to the engine is a regression. The static slice check must be the first check in the render path, before any engine involvement.

7. **The dirty counter and the ring's dirty bits must stay in sync.** A counter increment without a corresponding bit flip, or a bit flip without a counter increment, will either cause missed renders (false zero count) or infinite loops (count > 0 but no dirty bits). The `mark_dirty` operation must be atomic in the sense that the bit flip and counter increment are always paired — even if the bit was already 1 (in which case neither the flip nor the increment should happen).