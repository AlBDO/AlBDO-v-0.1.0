# Albedo: Current Development Priorities

**Status:** Engine complete. Product surface absent. The core runtime is built — the gap is everything a developer touches.

---

## The Core Problem

The engine can analyze, bundle, and render. No developer can use it yet without understanding its internals. A product requires a surface that hides the engine. That surface does not exist.

---

## Priority Items

### 1. Lock the Developer Contract *(Do this first — do not write code yet)*

Before any further development, one question must have a definitive answer: **what does a developer actually write to use Albedo?**

This means specifying, in writing:

- What a project directory looks like
- The config file format
- What commands the CLI exposes
- What the dev server invocation looks like

The `albedo-server` demo routes exist, but they are demo code — not a contract. Everything downstream depends on this decision being frozen first.

---

### 2. Dev Server (`albedo dev`)

This is the most critical missing piece for developer adoption. All existing engine capabilities — hot reload, incremental builds, the sentinel ring, the scheduler — must surface as **a single command a developer runs once and forgets.**

Requirements:

- Watch the component directory for file changes
- Feed changes into the incremental cache *(already built)*
- Re-run the analyzer on changed files only *(already built)*
- Push browser updates without a full page reload
- Surface meaningful errors in both the terminal and the browser

`walkdir` is already in `Cargo.toml`. The incremental cache is done. What is missing is the file watcher loop and a WebSocket/WebTransport channel to push updates to the browser.

---

### 3. Real JSX/TSX Support

This is the most significant technical gap. The current QuickJS engine executes component code, but real developer-authored components use JSX syntax that requires a transform step before execution. `ast_eval.rs` handles only simple cases today.

Real developers write:

```jsx
export default function Hero({ title }) {
  return <section><h1>{title}</h1></section>
}
```

The fix: run a JSX transform pass before handing code to QuickJS. **SWC is already in the dependency tree** (`swc_ecma_parser`, `swc_ecma_ast`, `swc_ecma_visit`). The JSX-to-function-call transform should be built on top of what is already imported.

---

### 4. React SSR Compatibility Shim

A developer bringing a React component hits a wall the moment they use `useState` or `useEffect`. The architecture document correctly calls this "a compatibility layer, not the center" — but it needs to actually exist.

The minimum viable shim for SSR: implement `useState`, `useEffect` (no-op on server), `useRef`, `createContext`, and `useContext` as thin stubs that produce correct SSR output. This is not a full React implementation. It needs to cover the 80% of component code that matters for server rendering.

This shim would be loaded via `preloaded_libraries` in `BootstrapPayload`, which already has the correct hook for it.

---

### 5. `albedo.config.ts` Surface

Developers need a configuration file. Based on current engine capabilities, it needs to cover:

- Entry point / component root
- Route definitions or auto-discovery rules
- Hot-set declarations (which components are high-frequency)
- Static slice opt-in / opt-out
- Server port and host

The Node bridge (`albedo-node`) is the right place to expose this — most developers live in a Node/npm ecosystem. The NAPI bridge is already compiled.

---

### 6. Benchmarks with Real Numbers

The architecture document contains a performance targets table explicitly marked "not yet benchmarked." **This must change before any public-facing claim.**

Numbers that matter for positioning:

| Metric | Comparison |
|--------|------------|
| Cold start time | vs. Next.js dev server |
| Hot reload latency | file change → browser update |
| Tier A component serve time | vs. Next.js static page |
| Build time (50-component app) | vs. Vite |

Without these numbers, the performance story is a claim. With them, it is a fact.

---

### 7. Error Experience

Errors currently surface as Rust error strings. For a developer product, errors must:

- Point to the exact file and line number
- Explain what went wrong in terms of the **developer's code**, not Albedo internals
- Suggest a fix where possible

`thiserror` is already in use throughout the codebase. What is missing is a presentation layer that formats errors for human consumption with full file context.

---

### 8. npm Distribution

The `albedo-node` crate produces a `.node` binary (`index.win32-x64-msvc.node` is already in the tree). To ship to developers:

- Build for all targets: `win32-x64`, `darwin-x64`, `darwin-arm64`, `linux-x64`
- Publish to npm with platform-specific optional dependencies
- Review `.github/workflows/albedo-node-release.yml` to confirm all targets are covered

`package.json` and `index.js` in `crates/albedo-node/` already have the right structure. The `scripts/smoke-test.cjs` file indicates this path has been thought through. What remains is a multi-platform build matrix in the release workflow.

---

## Execution Sequence

| Weeks | Task |
|-------|------|
| 1–2 | Lock the developer contract. Write the spec. No code yet. |
| 3–4 | JSX transform via SWC. Nothing is demonstrable without this. |
| 5–6 | Dev server with file watching and hot reload. This is the first demo-able milestone. |
| 7–8 | React SSR compatibility shim. Enough to render hooked components without crashing. |
| 9–10 | Benchmarks against Next.js on a real app. Publish numbers. |
| 11–12 | Multi-platform npm release. First public distribution. |

> **Documentation and error experience should be built incrementally alongside all of the above — not deferred to the end.**