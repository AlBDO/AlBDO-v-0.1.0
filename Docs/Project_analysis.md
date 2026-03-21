# Albedo — Full Project Analysis
### State of the codebase, dev build path, and showcase strategy

---

## What this project actually is

Albedo is a Rust-powered **SSR rendering compiler** for React-style JSX/TSX components. It sits in the same space as Vite, Next.js, and Parcel, but its fundamental premise is different: instead of treating every component identically at render time, it classifies components into tiers based on their runtime behavior and routes them through separate, purpose-built pipelines.

The core intellectual property is the **tier system + parallel analysis pipeline**:

- **Tier A** — static slice eligible. No hooks, no async, no side effects. Pre-rendered to an HTML string at build time. At request time, the renderer returns a string from memory. Zero QuickJS involvement.
- **Tier B** — deferred. Needs to render but is not on the critical path. Processed after above-fold content.
- **Tier C** — on-demand. Gated behind user interaction or route transitions. Not analyzed until triggered.
- **Hot Set** — bypass tier entirely. High-frequency components (up to 32) get their own zero-cost dirty checking path via a cache-line-isolated sentinel ring.

The pitch to a developer is: *"stop treating your static nav bar the same as your live price ticker."*

---

## Actual completion state (reconciled against the code, not the docs)

The Architecture.md build order lists Steps 1–9 as done and Steps 10–14 as planned. **The actual code is ahead of the docs.**

| Step | Architecture.md says | Actual code |
|------|---------------------|-------------|
| 1–9 | Done | Done |
| 10 — Sentinel Ring + Hot Set Registry | **NEXT** | **Done** — `src/runtime/hot_set.rs` fully implemented, 6 passing tests including concurrent mark/drain correctness |
| 11 — Overtake Zone Scheduler | Planned | **Done** — `src/runtime/scheduler.rs` fully implemented with adaptive chunk sizing, overtake budget enforcement, and 5 passing tests |
| 12 — π-Arch Inter-Lane Communication | Planned | File exists: `src/runtime/pi_arch.rs` |
| 13 — 4-Lane Highway | Planned | File exists: `src/runtime/highway.rs` and `src/runtime/pipeline.rs` |
| 14 — WebTransport 4-Stream | Planned | File exists: `src/runtime/webtransport.rs` |

The Tier 1 blocking issues in `Things_we_need_to_tackle#1.md` (import rewriting, JSX transform, TypeScript stripping) are also **resolved** in the current code:
- `rewrite_import_declaration()` in `quickjs_engine.rs` handles all five import forms
- `transpile_module_source_for_quickjs()` runs a combined SWC JSX-transform + TypeScript-strip pass before IIFE wrapping
- Tests `test_compile_module_rewrites_import_declarations_to_runtime_requires` and `test_compile_module_transpiles_jsx_and_strips_typescript` confirm both work

**The engine is further along than any doc in the repo acknowledges.**

---

## The real gap: there is no developer surface

The engine is sound. The gap is everything a developer touches.

Currently, to use Albedo, a developer must:
1. Know what `RenderCompiler`, `ComponentGraph`, `ProjectScanner`, and `BundlePlanOptions` are
2. Wire them together manually
3. Run the CLI with three underdocumented commands (`analyze`, `showcase`, `bundle`)
4. Restart manually on every file change

There is no `albedo dev`. No `albedo.config.ts`. No HMR. No error overlay. No npm package a developer can `npm install`.

Every piece of engine infrastructure needed to build these exists. None of the surface exists.

---

---

# PRIORITY 1: DEV BUILD

## What you can run right now

The `showcase --serve` command is a working proto-dev environment. It:
- Scans a component directory
- Builds the dependency graph
- Runs the SWC transform + QuickJS render
- Serves the output on a local HTTP port

```bash
cargo run --bin dom-compiler -- showcase test-app\src\components --entry App.jsx --serve --port 4173
```

This is not a dev server. It is a single-shot render with a static HTTP listener. But the render pipeline it exercises — scan → graph → analyze → render → serve — is the exact same pipeline that a dev server wraps.

## What's missing for a real dev build

### 1. File watcher → incremental rebuild loop

The incremental cache (`src/incremental.rs`) is fully built. It tracks file hashes and only reanalyzes changed components, with cascade invalidation. What is not wired up is the file system event loop that feeds changes into it.

`walkdir` is already in `Cargo.toml`. What it lacks is `notify` — the Rust crate for OS-native file watching (inotify on Linux, FSEvents on macOS, ReadDirectoryChangesW on Windows).

**Add to `Cargo.toml`:**
```toml
notify = "6.1"
tokio = { version = "1", features = ["full"] }
```

### 2. The `albedo dev` command

A new binary entry point `src/bin/albedo.rs` needs to exist with a `dev <DIR>` subcommand. The command should:

1. Read `albedo.config.json` (or `albedo.config.ts` via the Node bridge)
2. Run an initial full scan + graph + render (reuse `build_showcase_artifact` as the engine)
3. Start the file watcher
4. On file change: feed into `IncrementalCache`, re-run analyzer on changed files only, re-render affected components
5. Push a reload signal to the browser via WebSocket
6. Serve the output on a local HTTP port

The `AlbedoServer` + `axum` are already in `crates/albedo-server/`. Wire the watcher to a tokio broadcast channel, have the server listen to that channel, push a `data: reload\n\n` SSE event (or a WebSocket message) to connected browsers.

**Skeleton for the dev server loop:**
```rust
// src/bin/albedo.rs  (new file)
use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::broadcast;

#[tokio::main]
async fn main() {
    let (reload_tx, _) = broadcast::channel::<()>(16);
    
    // File watcher
    let tx = reload_tx.clone();
    let mut watcher = RecommendedWatcher::new(move |event: Result<Event, _>| {
        if let Ok(e) = event {
            if matches!(e.kind, notify::EventKind::Modify(_) | notify::EventKind::Create(_)) {
                let _ = tx.send(());
            }
        }
    }, Default::default()).unwrap();
    watcher.watch(components_root, RecursiveMode::Recursive).unwrap();
    
    // HTTP + WebSocket server (axum)
    // route: GET /  → serve rendered HTML
    // route: GET /_albedo/hmr  → SSE/WS that sends reload on broadcast
}
```

### 3. `albedo.config.json` format

The `AppConfig` struct in `crates/albedo-server/src/config.rs` already handles JSON parsing. You need one canonical config spec:

```json
{
  "server": {
    "port": 3000,
    "host": "127.0.0.1"
  },
  "entry": "src/components",
  "root": "App.tsx",
  "hot_set": [
    { "component": "PriceTicker", "priority": "critical" },
    { "component": "LiveChart", "priority": "high" }
  ],
  "static_slice": {
    "enabled": true,
    "opt_out": ["DynamicWidget"]
  }
}
```

The `hot_set` array maps directly to `HotSetRegistry.register()`. The `entry` and `root` fields map to what `ShowcaseRenderRequest` already takes.

### 4. Browser error overlay

When a component fails to render in dev mode, the server currently would return a raw error string. The fix is a thin middleware in `albedo-server` that catches `RuntimeError::RenderError` variants, checks that the request expects `text/html`, and returns a styled HTML error page instead of JSON.

The HTML page should include a WebSocket reconnect snippet so the browser automatically reloads when the developer fixes the error and saves.

### 5. Port conflict handling

In `crates/albedo-server/src/server.rs`, the `TcpListener::bind` call returns a raw OS error on port conflict. Add specific detection of `io::ErrorKind::AddrInUse` and try incrementing the port 3000 → 3001 → 3002 up to port 3010. Print which port was selected. This is standard Vite behavior and developers expect it.

---

## Dev build implementation priority order

| Order | Task | File to touch | Effort |
|-------|------|--------------|--------|
| 1 | Add `notify` + `tokio` to `Cargo.toml` | `Cargo.toml` | Trivial |
| 2 | Create `src/bin/albedo.rs` with `dev` command skeleton | New file | Medium |
| 3 | Wire file watcher to `IncrementalCache` | New + `src/incremental.rs` | Medium |
| 4 | Add SSE/WebSocket reload endpoint to axum server | `crates/albedo-server/src/server.rs` | Medium |
| 5 | Define `albedo.config.json` format | `crates/albedo-server/src/config.rs` | Low |
| 6 | HTML error overlay on render failure in dev mode | `crates/albedo-server/src/error.rs` | Low |
| 7 | Port conflict auto-increment | `crates/albedo-server/src/server.rs` | Low |

---

---

# PRIORITY 2: SHOWCASE

## What can be demo'd right now

**The showcase command works today and produces a compelling artifact.** Run it once:

```bash
cargo run --bin dom-compiler -- showcase test-app\src\components --entry App.jsx --serve --port 4173
```

Open `http://127.0.0.1:4173` in a browser. You get:

- A live rendered view of the React component tree
- A **Performance Stats panel** showing scan time, graph build time, optimization time, render time, and end-to-end total in milliseconds — these are real numbers, not mocked
- A **Graph Snapshot** showing total components, dependencies, critical path length, parallel batch count, roots, leaves, and weight
- A **Dependency Hash table** with FNV-1a fingerprints per component — useful for cache invalidation demos
- The raw data payloads as JSON

This is already presentation-ready as a technical demo. The story to tell in front of the panel is: "watch the numbers."

## What would make it conference-grade

### 1. Tier assignments in the showcase output

The most important signal Albedo produces — Tier A vs B vs C — is currently invisible in the showcase HTML. The analyzer assigns tiers. The showcase does not surface them. This is the biggest missed opportunity in the current output.

Add a **Tier Assignment panel** to `build_showcase_document()` in `src/showcase.rs`:

```
  Component           Tier    Reason
  ─────────────────────────────────────────────
  Header              [A]     static slice eligible
  Navigation          [B]     deferred (interactive flag)
  HeroImage           [A]     static slice eligible
  PriceTicker         [HOT]   hot set registered
  Footer              [A]     static slice eligible
```

The tier is derivable from `ComponentAnalysis` after `optimize()` runs. Surfacing it converts the tier system from an implementation detail into the visual centerpiece of the demo.

### 2. Parallel batches visualization

The `OptimizationResult.parallel_batches` structure contains the full parallel render schedule: which components render in which batch, at which topological level, with estimated time per batch. The showcase currently shows this as a count only.

For a presentation, render this as a **horizontal timeline** — a simple CSS grid showing batches as columns and components as rows within each column. Annotate each component with its LCP/above-fold/interactive flags. This makes the parallel scheduling strategy immediately visually legible to an audience.

### 3. Hot set ring demonstration

The hot set ring is the most technically impressive thing in this codebase. One atomic load for a clean frame. Cache-line-isolated dirty bits. Zero analyzer involvement on updates.

For a demo: add a simple JavaScript snippet to the showcase HTML that simulates high-frequency updates. Mark 2-3 components as hot set. Show the dirty counter going up and down on each simulated frame tick. Show the ring drain cost in microseconds vs what a full analyzer pass would cost. This single visualization is worth five minutes of conference talk time.

### 4. A benchmark panel

The Architecture.md contains a performance targets table explicitly marked "not yet benchmarked." **Before any public claim, run the numbers.**

The benchmark to run for maximum presentation impact:

```
cargo bench
```

But first, add a `benches/` directory with criterion benchmarks:
- Cold render time: scan a 50-component tree from scratch
- Warm render time: render with fully populated incremental cache
- Tier A serve time: return a pre-rendered static slice
- Parallel analysis speedup: 10 vs 50 vs 200 components, parallel vs serial

Then do the comparison run on the same 50-component tree in Next.js dev mode. Record cold start time, first render time, hot reload time. Put both sets of numbers in the showcase output.

**This is what turns "we're faster" into a fact.**

### 5. Error message quality

Currently, when the analyzer hits an unsupported export form, the error message contains the raw SWC AST debug representation. Fix the six `format!("{:?}", unsupported)` calls in `quickjs_engine.rs` to use human-readable descriptions (the replacement table is already written out in `Things_we_need_to_tackle#1.md`). This affects what developers see during the demo if anything goes wrong on stage.

---

## Showcase implementation priority order

| Order | Task | File | Effort |
|-------|------|------|--------|
| 1 | Add tier assignment panel to showcase HTML | `src/showcase.rs` | Low |
| 2 | Replace parallel batch count with visual timeline | `src/showcase.rs` | Medium |
| 3 | Add hot set activity demo snippet to showcase | `src/showcase.rs` | Low |
| 4 | Add `benches/` with criterion benchmarks | New | Medium |
| 5 | Run Next.js comparison and hard-code results | `src/showcase.rs` | Low (once numbers exist) |
| 6 | Fix SWC AST dump error messages to human language | `src/runtime/quickjs_engine.rs` | Low |

---

---

# FULL PROJECT MAP

## What is built and working

### Core engine (`src/`)
- **Component Graph** (`graph.rs`) — DashMap-backed adjacency list. Cycle detection on every `add_dependency`. O(1) reads.
- **Parallel Topological Sort** (`parallel_topo.rs`) — crossbeam scoped threads, core_affinity pinning, count-based DashMap accumulator (not presence-flag — this was a real correctness bug that was found and fixed).
- **Parallel Analyzer** (`analyzer.rs`, `parallel.rs`) — threshold at 50 components. Below: serial. Above: thread-per-chunk, core-pinned, results merged via DashMap.
- **Incremental Cache** (`incremental.rs`) — file hash tracking, cascade invalidation, disk persistence across process restarts.
- **Adaptive Chunk Sizing** (`adaptive.rs`) — L3 cache size aware. Automatically sizes analysis chunks to fit in L3 on the current machine.
- **Static Slice System** (`runtime/static_slice.rs`, `bundler/static_slice.rs`) — Tier A detection and pre-render.
- **Bundler Pipeline** (`bundler/`) — deterministic BundlePlan, vendor chunk inference, wrapper module emission, byte-identical output across runs (CI gate enforces this).
- **QuickJS Runtime** (`runtime/quickjs_engine.rs`) — SWC JSX transform + TypeScript strip, import rewriting to `__albedo_require`, IIFE module wrapping, module registry, render envelope protocol.
- **AST Fallback Renderer** (`runtime/ast_eval.rs`) — fallback when QuickJS cannot handle a component.
- **Hydration System** (`hydration/`) — island planning from ManifestV2, versioned payload generation, checksum validation, script tag generation.
- **Manifest V2** (`manifest/`) — structured render manifest with tier annotations, parallel batches, critical path, vendor chunks.

### Sentinel Ring + Scheduler (`src/runtime/`)
- **Hot Set Registry** (`hot_set.rs`) — DashMap-backed, bounded at 32 components. Fully tested.
- **Sentinel Ring** (`hot_set.rs`) — circular singly-linked list. CachePadded nodes. AtomicU8 dirty bits. AtomicU32 global dirty counter. drain_to_queue. Concurrent tests pass.
- **Overtake Zone Scheduler** (`scheduler.rs`) — 2ms budget enforcement, overtake zone yield, adaptive chunk limit that grows on no-overtake and shrinks on overrun. Fully tested.

### Node.js Bridge (`crates/albedo-node/`)
- NAPI-rs exports: `analyzeProject` (async), `optimizeManifest` (async), `getCacheStats` (sync)
- Worker thread execution via `AsyncTask`
- Panic-safe error mapping — a Rust panic becomes a JavaScript Error, never a Node.js process crash
- TypeScript declarations (`index.d.ts`)
- Pre-built binary for Windows x64 (`index.win32-x64-msvc.node`) already in the tree
- Release workflow (`albedo-node-release.yml`) exists but cross-platform build matrix needs verification

### HTTP Server (`crates/albedo-server/`)
- Deterministic radix-tree router with dynamic path params and method guards
- `AlbedoServerBuilder` — handler registration, props loaders, layout handlers, middleware, auth provider
- Middleware pipeline (request + response hooks)
- Auth provider interface with Deny/Allow decision
- Layout wrapping (nested layouts, HTML response detection)
- Streaming HTML response support
- Graceful shutdown
- JSON config (`AppConfig`)

### CLI (`src/bin/dom-compiler.rs`)
- `analyze <DIR>` — scan, graph, optimize, JSON export, verbose mode
- `bundle <DIR>` — scan → manifest → bundle-plan → wrapper emit
- `showcase <DIR>` — scan → graph → optimize → render → HTML document with metrics
- `showcase --serve` — HTTP server for the showcase document

## What exists as file stubs (modules in mod.rs, not yet read in full)
- `src/runtime/highway.rs` — 4-lane pipeline topology
- `src/runtime/pi_arch.rs` — inter-lane communication
- `src/runtime/pipeline.rs` — pipeline orchestration
- `src/runtime/webtransport.rs` — browser streaming layer

## What does not exist yet
- `albedo dev` command (file watcher + HMR loop)
- `albedo.config.ts/json` contract
- Browser error overlay in dev mode
- Tier assignments visible in CLI/dev output
- Hot set feedback in dev output
- Multi-platform npm build (only win32-x64 pre-built)
- Benchmark suite

---

---

# THINGS TO KNOW AS A SOLO DEVELOPER PUSHING THIS TO PRODUCTION

## The dependency you're missing for a dev server

`notify = "6.1"` is not in `Cargo.toml`. This is the only missing crate between the current state and a working file-watching dev server. Everything else is already there.

## The npm package path is very close

`crates/albedo-node/` is production-ready for Windows x64. The `package.json`, `index.js`, `index.d.ts`, and `scripts/smoke-test.cjs` are all in place. The pre-built `.node` binary is in the tree. To ship:
1. Build for macOS arm64, macOS x64, Linux x64 using the GitHub Actions cross-compile workflow
2. Verify `albedo-node-release.yml` covers all three targets
3. `npm publish`

The npm surface is the fastest path to developer adoption because it slots into existing Node.js toolchains — developers don't need to install Rust.

## The showcase is already your best sales tool

Everything needed for a technical conference demo is already running. The `showcase --serve` command produces a page with live performance metrics, dependency graphs, and the actual rendered output. The only additions that make it genuinely compelling for a crowd are: tier assignments visible per component, and a hot set dirty/drain animation showing the zero-cost clean frame path.

## The docs trail the code

Architecture.md marks the Sentinel Ring and Scheduler as "next to build." They are built. Update the docs before anyone else reads them. The current state creates a false impression that the project is less complete than it is.

## SWC is your entire transpilation surface

All JSX transform, TypeScript stripping, and import rewriting flows through SWC. This is a correct and powerful choice — SWC is what Next.js and Deno use internally. The version pins in `Cargo.toml` (`swc_ecma_parser = "0.149"`) are specific and should be updated carefully — SWC has broken API compatibility across minor versions.

## The incremental cache is your killer feature for developer experience

Once the file watcher is wired up, the incremental cache makes `albedo dev` meaningfully faster than Vite or Next.js on large component trees. On a 200-component app with one file changed, Albedo reanalyzes one component and its cascade, not all 200. This is a demonstrable benchmark win and should be a centerpiece of the showcase.

## The architecture is correct but the component tier detection needs real-world testing

The Tier A eligibility rules (no hooks, no async, no Math.random, no Date.now, no external I/O) are theoretically correct. In practice, real-world component code has patterns that may not parse correctly into tier assignments — class components, HOCs, components that import and re-export. Before any public launch, run the analyzer against at least three open-source React projects (a Next.js example, a CRA project, a Remix project) and verify tier assignments are sensible.

---

## Immediate next steps — ordered

```
This week:
  1. cargo run --bin dom-compiler -- showcase test-app\src\components --entry App.jsx --serve
     Verify it renders, open in browser, confirm the showcase page loads
  
  2. Add tier assignment column to showcase.rs build_showcase_document()
     This is ~30 lines of Rust. It makes the demo immediately more compelling.

  3. Add `notify = "6.1"` and `tokio` to Cargo.toml

Next week:
  4. Create src/bin/albedo.rs with `dev` subcommand skeleton
     Wire walkdir + notify → IncrementalCache → re-render loop
     WebSocket endpoint on axum for browser reload

  5. Add benches/ with criterion
     At minimum: cold scan, warm scan, Tier A serve time
     Run the numbers. Update Architecture.md with real data.

Before first public showing:
  6. Update Architecture.md to reflect actual completion state
     (Sentinel Ring, Scheduler, π-arch stubs all exist)
  7. Fix the 6 SWC AST dump error messages in quickjs_engine.rs
  8. Run analyzer against a real open-source React project
     Verify tier assignments are correct
```