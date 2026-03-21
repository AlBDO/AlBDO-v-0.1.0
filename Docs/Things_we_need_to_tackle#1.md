# Things We Need to Tackle #1
## Developer Experience — Blocking Issues, Friction Points, and Polish

> Derived from full codebase audit of `B:\beta-two\`. Every item below is traced to a specific file and line. Priority order is at the bottom.

---

## TIER 1 — Nothing Works Without These

These three items must be resolved before a developer can run a single realistic component. Until they are fixed, Albedo cannot be shown to anyone.

---

### 1. Import Statements Are Rejected at the Compiler Level

**File:** `src/runtime/quickjs_engine.rs`
**Location:** `compile_exporting_module()` → `ModuleDecl::Import` match arm

```rust
ModuleDecl::Import(_) => {
    return Err(RuntimeError::load(
        LoadErrorKind::UnsupportedSyntax,
        format!(
            "import declarations are not supported by QuickJS runtime loader in module '{specifier}'"
        ),
    ));
}
```

**What this means in practice:** Every developer writes components with `import` at the top. This is not optional or stylistic — it is the universal syntax for component dependencies. Hitting this error is guaranteed on the first realistic component.

**The fix:** The rewriter in `compile_module_script_for_quickjs` already parses modules with SWC and rewrites them into IIFE module records. Import declarations need one additional case: rewrite them into `__albedo_require` calls instead of rejecting them. The `__albedo_require` function is already injected into the render call. The machinery is complete. This is one new match arm.

```jsx
// Developer writes:
import Button from '../components/Button'
import { title } from './utils'
import styles from './Hero.module.css'

// Compiler rewrites to (inside the IIFE wrapper):
const Button = __albedo_require('../components/Button');
const { title } = __albedo_require('./utils');
const styles = __albedo_require('./Hero.module.css');
```

Specific import forms to handle:
- `import X from 'y'` → `const X = __albedo_require('y')`
- `import { a, b } from 'y'` → `const { a, b } = __albedo_require('y')`
- `import { a as b } from 'y'` → `const { a: b } = __albedo_require('y')`
- `import * as X from 'y'` → `const X = __albedo_require('y')`
- `import 'y'` (side-effect only) → `__albedo_require('y')`

**Dependency:** None. All required infrastructure exists.

---

### 2. JSX Is Parsed But Not Transformed

**File:** `src/runtime/quickjs_engine.rs`
**Location:** `compile_exporting_module()` → `slice_source()` calls throughout

**What is happening:** The SWC parser is configured with `jsx: true`, so JSX parses without error. However, `slice_source()` takes raw byte spans from the SWC AST and cuts them out of the **original source string verbatim** — JSX and all. The resulting IIFE script is handed to QuickJS containing raw JSX syntax, which QuickJS cannot execute. The developer gets a QuickJS syntax error with no pointer to where it came from.

```rust
// This gets the source text of an expression — but it's still JSX:
let expr_source = slice_source(source, default_expr.expr.span(), specifier)?;
statements.push(format!(
    "const __albedo_default_export__ = ({expr_source});"
    // ↑ this contains raw <div className="..."> syntax that QuickJS will reject
));
```

**The fix:** Run an SWC JSX transform pass over the entire source before the IIFE rewriting begins. SWC's transform visitor is already a transitive dependency. The JSX-to-function-call transform converts:

```jsx
<Button foo="bar">text</Button>
```

to:

```js
h(Button, { foo: "bar" }, "text")
```

The `h` function needs to be a lightweight shim installed in `BootstrapPayload.runtime_helpers_js`, which is already threaded through `init()`:

```js
// runtime_helpers_js shim — three lines
function h(type, props, ...children) {
  if (typeof type === 'function') return type({ ...props, children: children.length === 1 ? children[0] : children });
  const attrs = props ? Object.entries(props).map(([k, v]) => ` ${k}="${v}"`).join('') : '';
  const inner = children.flat().join('');
  return `<${type}${attrs}>${inner}</${type}>`;
}
```

This transform and the TypeScript strip (item 3 below) should be one combined pass, not two separate ones.

**Dependency:** Item 3 should be done in the same pass.

---

### 3. TypeScript Type Annotations Crash QuickJS

**File:** `src/runtime/quickjs_engine.rs`
**Location:** Same `slice_source` pattern as item 2

**What is happening:** SWC parses TypeScript correctly, but `slice_source` emits the original source bytes including all type annotations. QuickJS does not understand `: string`, `interface Props { ... }`, `<T>` generic syntax, or `as` casts. A `.tsx` or `.ts` component fails at load time with a raw QuickJS syntax error and no indication that the cause is TypeScript syntax.

**The fix:** SWC's TypeScript stripping is part of the same transform visitor infrastructure as the JSX transform. Run both in a single combined pass:

1. Strip all TypeScript type annotations, interface declarations, type aliases, and generic parameters
2. Transform JSX to `h()` calls

This is one SWC visitor pass. The output is plain JavaScript with no JSX and no TypeScript, which QuickJS can execute.

**Dependency:** Should be implemented as the same pass as item 2.

---

## TIER 2 — Developer Can Use It But Will Be Frustrated

These items do not prevent Albedo from running, but they will make a developer feel like they are fighting the tool rather than building with it. All five should be resolved before any public showing.

---

### 4. Silent Scan Failures Hide Broken Components

**File:** `src/scanner.rs`
**Location:** `scan_directory()` → error branch

```rust
match self.parser.parse_file(path) {
    Ok(mut comps) => components.append(&mut comps),
    Err(e) => {
        eprintln!("Warning: Failed to parse {:?}: {}", path, e);
    }
}
```

**What this means in practice:** A component that fails to parse is silently dropped from the graph. The developer sees no route, no error in the browser, and no indication of what happened. They navigate to their page, get a 404, and have no idea where to look.

**The fix:** Two-mode behaviour based on runtime context:

- **`albedo dev`:** Parse failure is a **hard error**. Stop startup. Print the exact file path, the parse error, and the relevant source lines (use SWC's span information to highlight the offending token). Do not start the server with a broken component graph.
- **`albedo start` (production):** Log the failure with full context and continue without the affected component, to avoid taking down a production server over one bad file.
- **During hot reload:** Surface the error as both a terminal message and an in-browser error overlay (see item 5).

The `scan_directory` signature should gain a `ScanMode` parameter (`Strict | Lenient`) so the calling context controls this behaviour.

---

### 5. Runtime Errors Reach the Browser as Raw JSON

**File:** `crates/albedo-server/src/error.rs`
**Location:** `RuntimeError::IntoResponse`

```rust
impl IntoResponse for RuntimeError {
    fn into_response(self) -> Response {
        let status = self.status_code();
        let message = self.to_string();
        let body = axum::Json(ErrorBody { error: message });
        (status, body).into_response()
    }
}
```

**What this means in practice:** When a component throws during render, the developer sees a browser tab displaying:

```json
{"error": "failed to render component 'src/pages/index.jsx': ReferenceError: foo is not defined"}
```

No HTML. No source context. No guidance. A developer who has only been using the tool for 20 minutes will not know what this means or how to fix it.

**The fix:** In `albedo dev` mode, the server's `dispatch` function should detect:
1. The request was for an HTML route (Content-Type `text/html` was expected)
2. The error originated in the renderer (`RendererFailure` or `LoadError` variants)

When both conditions are true, return a styled HTML error page instead of JSON:

```html
<!doctype html>
<html>
<head><title>Albedo — Render Error</title></head>
<body>
  <div style="font-family: monospace; padding: 2rem; max-width: 900px; margin: auto;">
    <h2 style="color: #c0392b;">⚠ Render Error</h2>
    <p><strong>Component:</strong> src/pages/index.jsx</p>
    <pre style="background: #f8f8f8; padding: 1rem; border-left: 4px solid #c0392b;">
ReferenceError: foo is not defined
  at Home (src/pages/index.jsx:7)
    </pre>
    <p style="color: #666;">Fix this error and save the file to reload.</p>
  </div>
  <script>
    // WebSocket reconnect for HMR — reconnects when dev server comes back up
    const ws = new WebSocket('ws://localhost:3000/_albedo/hmr');
    ws.onmessage = () => window.location.reload();
  </script>
</body>
</html>
```

The dev/production distinction can be communicated via a `RunMode` value injected into the server state at startup — `AlbedoServerBuilder` already has a state struct (`RuntimeState`) where this can live.

---

### 6. Error Messages Expose SWC AST Internals

**File:** `src/runtime/quickjs_engine.rs`
**Location:** Multiple `format!` calls in `compile_exporting_module()`

```rust
format!(
    "unsupported module declaration '{:?}' in module '{specifier}'",
    unsupported
)
```

**What this means in practice:** `{:?}` on an SWC AST node produces output like:

```
ExportNamed(NamedExport { span: Span { lo: BytePos(45), hi: BytePos(72), ctxt: SyntaxContext(0) },
specifiers: [Named(ExportNamedSpecifier { span: Span { ... }, orig: Ident(...) })], src: None,
type_only: false, with: None })
```

This is not a developer-facing error message. It is a compiler debug dump. A developer reading this has no idea what they wrote that caused it or how to fix it.

**The fix:** Every error message currently containing `{:?}` on an AST node should be rewritten in terms of what the developer wrote. Full replacement list:

| Current message | Replacement |
|---|---|
| `"unsupported module declaration 'ExportNamed { ... }'"` | `"Re-exports ('export { X } from \"...\"') are not yet supported"` |
| `"namespace exports are not supported"` | `"Namespace re-exports ('export * as X from \"...\"') are not yet supported"` |
| `"unsupported export declaration '{:?}'"` | `"Class exports ('export class X {}') are not yet supported — use a function"` |
| `"unsupported export pattern in module"` | `"Destructured export bindings ('export const { a, b } = obj') are not yet supported"` |
| `"unsupported default export declaration"` | `"This default export form is not yet supported. Use 'export default function Name() {}'"` |

The pattern to follow: describe what the developer wrote, state that it is not yet supported, and where possible suggest the syntax that does work.

---

## TIER 3 — Polish That Makes It Feel Professional

These items do not block development but are the difference between a tool that feels rough and one that feels finished. They should be completed before a public launch.

---

### 7. Port Conflicts Give Raw OS Error Codes

**File:** `crates/albedo-server/src/server.rs`
**Location:** `AlbedoServer::run()` → `TcpListener::bind()`

```rust
let listener = TcpListener::bind(addr)
    .await
    .map_err(|err| RuntimeError::ServerStartup(err.to_string()))?;
```

**What developers see:**
- Windows: `"address already in use (os error 10048)"`
- Linux/macOS: `"Address already in use (os error 98)"`

**The fix:** Detect `io::ErrorKind::AddrInUse` specifically and emit a human message:

```
  ERROR  Port 3000 is already in use.
         Try: albedo dev --port 3001
         Or set server.port in albedo.config.json
```

For `albedo dev` specifically, consider auto-incrementing: try ports 3000 → 3001 → 3002 up to 3010, bind to the first free one, and print which port was selected. This is what Vite does and developers have come to expect it.

---

### 8. Tier Assignments Are Invisible to Developers

**Context:** The analyzer assigns every component to Tier A (static slice, zero QuickJS at request time), Tier B (deferred), or Tier C (on-demand). This is the single most important performance signal Albedo produces. It is currently completely invisible to developers.

**The fix:** Show tier assignments in `albedo dev` startup output and on every incremental rebuild:

**Startup:**
```
  Routes (4)
    GET /            src/pages/index.jsx       [A] static slice
    GET /about       src/pages/about.jsx       [B] deferred
    GET /users/[id]  src/pages/users/[id].jsx  [C] on-demand
    GET /api/health  src/pages/api/health.jsx  [API]
```

**On file change where tier changes:**
```
  ↺  src/pages/index.jsx changed
     tier changed: [A] → [B]  (hook usage detected)
     incremental rebuild in 8ms
```

This converts the tier system from an internal implementation detail into an active feedback loop that developers use to guide decisions. A developer who adds `useState` to a Tier A page and immediately sees `tier changed: [A] → [B]` understands the cost of that decision instantly.

The tier is available in `ComponentAnalysis` after the analyzer runs. Surfacing it is a presentation-layer change with no engine work required.

---

### 9. The `hot_set` Has No Feedback Mechanism

**Context:** `hot_set` in `albedo.config.json` registers components in the sentinel ring for zero-cost dirty checking. The ring is capped at 32 components (`HOT_SET_MAX`). A 33rd registration is silently rejected. There is currently no feedback to the developer that their hot set registrations succeeded, failed, or are approaching the cap.

**The fix — three specific additions:**

**On startup:** Print the hot set with registration status:
```
  Hot set (2/32)
    ✓  src/components/Header.jsx     [registered]
    ✓  src/components/Nav.jsx        [registered]
```

**At 28+ entries:** Emit a capacity warning:
```
  WARN  Hot set at 28/32 capacity.
        Registrations beyond 32 are silently dropped.
        Consider removing lower-frequency components.
```

**In dev verbose mode (`albedo dev --verbose`):** Show hot set activity in real time:
```
  ↺  Header (hot set)  dirty → re-rendered in 0.4ms
  ↺  Nav    (hot set)  dirty → re-rendered in 0.2ms
```

---

### 10. Config File Format Has No Comment Support

**File:** `crates/albedo-server/src/config.rs`
**Location:** `AppConfig::load_from_file()`

```rust
let mut config: AppConfig =
    serde_json::from_str(&contents).map_err(|err| RuntimeError::ConfigParse { ... })?;
```

**What this means in practice:** A developer who wants to document why specific components are in their `hot_set`, or what a middleware is doing, cannot. Comments in JSON cause a parse error. Config files accumulate unexplained entries with no way to annotate them.

**Two fixes at different levels of effort:**

**JSONC support (easy, ~20 lines):** Strip `//` line comments and `/* */` block comments from the config file before passing it to `serde_json::from_str`. This is a pre-processing step, not a parser change.

```rust
fn strip_jsonc_comments(source: &str) -> String {
    // strip // line comments and /* */ block comments
    // preserving string literals correctly
}
```

**`albedo.config.ts` via the Node bridge (higher effort, high value):** If an `albedo.config.ts` exists at the project root, execute it with Node, capture the default export as JSON, and load that. The Node bridge (`albedo-node`) is already compiled. This gives developers full TypeScript types and autocomplete for config values, and the ability to compute config dynamically (environment variables, reading `package.json`, composing route arrays).

---

## Priority Order for Implementation

### Do These First — Nothing Works Without Them

| # | Item | File | Effort |
|---|---|---|---|
| 1 | Import statement rewriting | `src/runtime/quickjs_engine.rs` | Medium |
| 2 | JSX transform pass via SWC | `src/runtime/quickjs_engine.rs` | Medium |
| 3 | TypeScript type stripping (same pass as #2) | `src/runtime/quickjs_engine.rs` | Low (combined with #2) |

### Do These Second — Usable But Frustrating Without Them

| # | Item | File | Effort |
|---|---|---|---|
| 4 | Scan failures as hard errors in dev mode | `src/scanner.rs` | Low |
| 5 | Browser HTML error overlay for render failures | `crates/albedo-server/src/error.rs`, `server.rs` | Medium |
| 6 | Error messages rewritten from AST dumps to developer language | `src/runtime/quickjs_engine.rs` | Low |

### Do These Third — Makes It Feel Finished

| # | Item | File | Effort |
|---|---|---|---|
| 7 | Port conflict detection with clear message + auto-increment | `crates/albedo-server/src/server.rs` | Low |
| 8 | Tier assignments visible in dev output with change notifications | `src/bin/albedo.rs` (new) | Low |
| 9 | Hot set feedback: registration status, capacity warnings, activity log | `src/bin/albedo.rs` (new) | Low |
| 10 | JSONC comment support in config | `crates/albedo-server/src/config.rs` | Low |

---

## Summary

Items 1, 2, and 3 are the line between "crashes on hello world" and "runs real components." They are all in the same file (`quickjs_engine.rs`) and the required infrastructure (SWC, the IIFE rewriter, `__albedo_require`) is already present. The work is connecting existing pieces, not building new ones.

Items 4, 5, and 6 are the line between "runs but makes you feel like something is broken" and "gives clear feedback when things go wrong." None require engine changes.

Items 7–10 are what make a developer feel like the tool was built by someone who has used developer tools before.