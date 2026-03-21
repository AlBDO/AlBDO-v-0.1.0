# Albedo Developer Contract (v1)

This document freezes the `albedo run dev` contract.

Contract version: `1`

## 1. Supported config files

`albedo run dev` resolves config in this order:

1. `--config <PATH>` if provided.
2. `./albedo.config.json` if present.
3. `./albedo.config.ts` if present.
4. Built-in defaults if no config file exists.

If both `albedo.config.json` and `albedo.config.ts` exist in the same directory, command fails until one is removed or `--config` is passed.

## 2. Config schema

### 2.1 JSON shape

```json
{
  "contract_version": 1,
  "root": "src/components",
  "entry": "App.tsx",
  "server": {
    "host": "127.0.0.1",
    "port": 3000
  },
  "watch": {
    "debounce_ms": 75,
    "ignore": ["**/*.snap", "**/.git/**"]
  },
  "hmr": {
    "enabled": true,
    "transport": "sse"
  },
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

### 2.2 TypeScript shape

`albedo.config.ts` must export a static object:

```ts
export default {
  contract_version: 1,
  root: "src/components",
  entry: "App.tsx",
};
```

or:

```ts
export default defineConfig({
  contract_version: 1,
  root: "src/components",
  entry: "App.tsx",
});
```

Allowed TS values are static literals/objects/arrays (no computed keys, no spreads, no runtime expressions).

## 3. Defaults

If omitted:

- `contract_version`: `1`
- `root`: `"src/components"` (relative to project dir)
- `entry`: auto-detect `App.tsx`, `App.jsx`, `App.ts`, `App.js`
- `server.host`: `"127.0.0.1"`
- `server.port`: `3000`
- `watch.debounce_ms`: `75`
- `watch.ignore`: `[]`
- `hmr.enabled`: `true`
- `hmr.transport`: `"sse"`
- `hot_set`: `[]`
- `static_slice.enabled`: `true`
- `static_slice.opt_out`: `[]`

## 4. Validation rules

- `contract_version` must be `1`.
- `root` must resolve to an existing directory.
- `entry` must end with `.tsx`, `.ts`, `.jsx`, or `.js`.
- Resolved entry file must exist under resolved `root`.
- `server.host` must be a valid IP address.
- `server.port` must be `1..65535`.
- `watch.debounce_ms` must be `1..=5000`.
- `hot_set` max size is `32`.
- `hot_set.component` must be non-empty and unique.
- `static_slice.opt_out` entries must be non-empty and unique.

## 5. CLI flags

Usage:

```bash
albedo run dev [DIR] [OPTIONS]
```

Aliases:

```bash
albedo dev [DIR] [OPTIONS]
albedo build [DIR] [OPTIONS]    # equivalent to: albedo run dev --prod
```

Flags:

- `--config <FILE>`: explicit `albedo.config.json` or `albedo.config.ts`.
- `--entry <FILE>`: entry module override relative to root.
- `--host <IP>`: overrides `server.host`.
- `--port <PORT>`: overrides `server.port`.
- `--no-hmr`: forces `hmr.enabled = false`.
- `--strict`: strict dev behavior flag.
- `--verbose`, `-v`: verbose dev behavior flag.
- `--open`: open browser behavior flag.
- `--print-contract`: request resolved contract output.

## 6. Precedence

Final resolved values are merged with this priority:

1. CLI overrides
2. Config file values
3. Built-in defaults

## 7. Current runtime status

`albedo run dev` now starts a live dev runtime:

- serves the current document over HTTP
- watches files under `root`
- rebuilds on change (debounced)
- pushes browser reload events over SSE at `/_albedo/hmr`
- auto-increments port when preferred port is in use (up to +10)

`albedo build` runs the optimized production artifact pipeline and writes to `.albedo/dist`.
