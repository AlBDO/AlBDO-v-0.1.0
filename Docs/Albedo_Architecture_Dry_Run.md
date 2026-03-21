# Albedo Architecture (Full-State Dry Run)

Date: 2026-03-14
Assumption: all items from `Docs/Albedo_Development_Plan.md` and `Docs/Post Dev Plan.md` are implemented.

## 1) What This Document Is

This is a future-state architecture walkthrough that explains Albedo from start to finish as if the entire roadmap has shipped.

Goal:

- Show the full workflow as one coherent system.
- Explain where high-level DX and low-level performance connect.
- Provide a practical "dry run" from project creation to production traffic.

## 2) Product Shape (Steady-State)

Albedo is a Rust-first framework/runtime with four user-facing entry points:

1. `albedo init` (project bootstrap)
2. `albedo dev` (incremental development server)
3. `albedo build` (deterministic artifact generation)
4. `albedo start` (artifact-only production runtime)

Under the hood, all four entry points are thin clients over a persistent daemon that owns:

- canonical IR graph state,
- incremental delta indices,
- artifact cache,
- performance telemetry,
- correctness checks.

## 3) Core Architectural Pillars (Implemented)

### 3.1 Canonical IR as the Single Truth

All subsystems consume the same typed IR:

- parser front-end,
- effect analysis,
- tier/hydration planner,
- bundler/chunk planner,
- runtime module loader.

IR nodes use stable generational IDs and arena-backed storage for pointer stability and low churn.
Any artifact is keyed by IR hash, not by ad hoc local subsystem assumptions.

### 3.2 Effect-Semantic Tiering

Tiering and hydration are derived from effect analysis, not naming heuristics.

Effect lattice (conceptually):

- `Pure`
- `Hooks`
- `Async`
- `IO`
- `SideEffects`

Tier policies are computed from effect joins over dependency/call graphs, giving sound decisions for static slices, deferred render, and interactive hydration.

### 3.3 Delta-First Incremental Pipeline

The pipeline is recomputation-minimal:

- file edits produce IR deltas,
- deltas flow only to dependent operators,
- unaffected regions are not revisited.

This replaces broad invalidation passes with dependency-aware propagation.

### 3.4 Artifact-First Runtime

Production runtime executes sealed route packages:

- static slices,
- precompiled runtime modules,
- dependency closure and module order,
- hydration plans/payloads,
- integrity and schema checks.

Runtime does not require source tree access during request handling.

### 3.5 Unified Runtime Kernel

Hot set, scheduler, inter-lane routing, and stream muxing are one coherent kernel:

- typed messages,
- bounded queues,
- explicit backpressure,
- deterministic lane behavior.

Correctness is verified via model checks (`loom` tests + formal invariant model).

### 3.6 Persistent Daemon

Daemon process keeps graph and caches warm across commands:

- CLI requests are RPC calls,
- `dev`, `build`, `start`, and Node bridge share state,
- cold-start penalties are amortized.

## 4) High-Level Component Map

1. **CLI Layer**
- Parses command intent and forwards to daemon API.

2. **Daemon Control Plane**
- Session manager, workspace registry, cache and telemetry owner.

3. **Front-End Compiler Layer**
- Scanner/parser -> canonical IR builder.

4. **Semantic Analysis Layer**
- Effect engine, tier planner, hydration planner, dependency integrity checks.

5. **Incremental Engine**
- Delta graph propagation and memoized operator outputs.

6. **Bundle/Artifact Layer**
- Route packages, vendor chunks, precompiled runtime modules, manifests.

7. **Runtime Kernel**
- Hot-set sentinel ring, overtake scheduler, lane router, stream muxer.

8. **Serving Layer**
- HTTP dispatch, artifact loader, render execution, cache/revalidation.

9. **Observability and Perf Gates**
- Benchmarks, p50/p95 dashboards, CI regression blockers.

## 5) End-to-End Dry Run

## 5.1 `albedo init`

1. User runs `albedo init my-app`.
2. CLI asks daemon for scaffold template.
3. Daemon creates:
- config skeleton,
- route conventions,
- typed runtime contract stubs,
- benchmark config baseline.
4. Project starts with known schema versions and deterministic defaults.

Output:

- ready-to-run repository with zero manual bootstrapping.

## 5.2 First `albedo dev` Startup

1. CLI sends `dev.start(workspace)` to daemon.
2. Daemon scans source files and builds canonical IR.
3. Effect engine computes semantic classes and tier assignments.
4. Incremental engine stores operator states keyed by IR hash.
5. Bundler emits in-memory route packages for dev serving.
6. Runtime kernel warms:
- hot-set registry,
- scheduler queues,
- lane topology maps,
- precompiled module cache.
7. Dev server starts and exposes:
- app routes,
- diagnostics endpoint,
- HMR/reload channel.

Output:

- first page served with deterministic artifacts and profiling headers.

## 5.3 Editing a File During `dev`

Example: `src/components/Hero.tsx` changed.

1. File watcher emits change event.
2. Front-end parser updates only affected IR nodes.
3. Delta engine computes precise dependent set.
4. Effect engine recomputes only impacted semantic joins.
5. Tier/hydration decisions are updated only where needed.
6. Bundler regenerates only impacted route package segments.
7. Runtime kernel receives targeted cache invalidation:
- affected route package version incremented,
- static slice entries evicted selectively,
- unchanged modules stay hot.
8. Browser gets minimal reload/hydration patch signal.

Output:

- low-latency edit cycle, minimal recomputation, stable behavior.

## 5.4 `albedo build`

1. CLI sends `build.release(workspace, profile)` to daemon.
2. Daemon validates:
- IR integrity,
- schema compatibility,
- deterministic ordering constraints.
3. Artifact layer emits sealed route packages and manifests.
4. Build metadata includes:
- IR hash roots,
- artifact checksums,
- benchmark stamps,
- compatibility version.
5. CI perf gate compares current run against baseline envelope.
6. Build fails if correctness or perf thresholds regress.

Output:

- deployment-ready artifact set with reproducibility guarantees.

## 5.5 `albedo start`

1. CLI starts runtime with artifact directory only.
2. Runtime loads manifests, verifies checksums and schema.
3. Runtime kernel initializes bounded queues and lane contexts.
4. Module registry loads precompiled scripts and static slices.
5. Server begins listening with health and metrics endpoints.

Output:

- source-independent production runtime, fast warm path.

## 5.6 Request Lifecycle (Production)

Example request: `GET /dashboard`.

1. Router resolves route target and artifact package.
2. Runtime checks static slice cache key:
- if hit: shell HTML returns immediately.
- if miss: proceeds with kernel scheduling.
3. Kernel stages work:
- hot-set dirty drain,
- lane assignment by phase,
- overtake budget enforcement,
- inter-lane dependency message routing.
4. QuickJS path executes only for non-static segments using precompiled module scripts.
5. Stream muxer emits shell/deferred/hydration chunks on dedicated streams.
6. Response metadata records module cache hits/misses and render timings.

Output:

- deterministic streamed response with bounded tail latency.

## 5.7 Revalidation and Runtime Mutation

1. App triggers `revalidatePath` or `revalidateTag`.
2. Runtime invalidates only matching route package versions.
3. Next request regenerates from artifact-backed execution path.
4. Unrelated routes remain warm and untouched.

Output:

- fine-grained cache invalidation without global cache flushes.

## 5.8 Node Bridge and Toolchain Integration

1. External tooling calls `@albedo/node`.
2. Bridge forwards to daemon RPC rather than spawning isolated compile flows.
3. Tooling receives:
- manifest and diagnostics,
- cache stats,
- reproducible plan outputs.

Output:

- consistent behavior between CLI and ecosystem integrations.

## 6) Correctness Model

Correctness is enforced at four layers:

1. **Type-Level Pipeline Safety**
- typestate enforces valid stage transitions at compile time.

2. **Deterministic Data Contracts**
- canonical IR and artifact schemas are versioned and validated.

3. **Concurrency Invariants**
- lock-free hot paths are tested via `loom` and formal invariant specs.

4. **Runtime Contract Checks**
- route package checksums, schema versions, and dependency closure checks at load time.

## 7) Performance Model

Primary performance strategy:

- avoid work first,
- specialize hot paths second,
- parallelize only where bounded and measurable.

Key implementation levers:

- delta-only recomputation,
- arena/pointer-stable IR memory layout,
- hot-set zero-work clean-frame fast path,
- bounded lock-free queues with backpressure,
- precompiled runtime modules,
- zero-copy and reduced allocation in stream path.

## 8) Observability and Release Gates

Every release is blocked unless:

- correctness suite passes,
- benchmark harness passes defined p50/p95 envelopes,
- determinism checks pass on repeated artifact emission,
- no perf regression beyond configured tolerance.

Runtime emits:

- render timings,
- module cache hit/miss counters,
- scheduler overtake counters,
- lane and queue pressure metrics.

## 9) Mental Model Summary

Albedo in this full state behaves like:

- a compiler pipeline with strict semantic IR contracts,
- an incremental dataflow system for development speed,
- a kernel-style runtime for bounded, deterministic serving.

Developer experience remains simple at the surface (`init/dev/build/start`), while internals stay low-level, auditable, and performance-first.

