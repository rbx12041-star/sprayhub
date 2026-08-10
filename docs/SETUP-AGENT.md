# Set up your own agent to drive the game (recreate the build loop)

This repo was built by an agent running an in-game client through a local MCP bridge — the same toolchain an LLM can use to *run code in Roblox, read game state, decompile scripts, and click UI*, then iterate on `sprayhub.luau` live. To help the same way, each helper runs the full stack on their own machine.

> One sentence version: install Node + the bridge + an MCP-capable agent, paste the loadstring in your executor, and your agent can now execute code inside the connected game.

## 1. Prerequisites
- Node.js 18+ (22 works). A Roblox executor (any that supports `WebSocket.connect` or plain `request`/`http_request` — the connector has fallbacks). An MCP-capable agent (Claude Code, Cursor, Windsurf, Continue, …).

## 2. Install the bridge (roblox-executor-mcp)
It's the DexCodeSX fork on GitLab (`roblox-mcp-server` on npm, ~v3.8.4 at time of writing).
```bash
git clone https://gitlab.com/DexCodeSX/roblox-executor-mcp
cd roblox-executor-mcp
npm install
npm run build        # produces dist/index.js
```
Point your agent's MCP config at it. For Claude Code (`~/.claude/mcp.json`):
```json
{
  "mcpServers": {
    "roblox-executor-mcp": {
      "command": "node",
      "args": ["C:\\ABSOLUTE\\PATH\\TO\\roblox-executor-mcp\\dist\\index.js"]
    }
  }
}
```
(That upstream repo already ships per-client config files — `CLAUDE_MCP.md`, `CURSOR_MCP.md`, etc.)

## 3. Connect the game
1. Launch the bridge (it listens on `localhost:16384`, dashboard at `http://localhost:16384/`).
2. In Roblox "Spray Paint!", inject into your executor:
   ```lua
   loadstring(game:HttpGet("http://localhost:16384/script.luau"))()
   ```
   (This pulls the version-matched connector from the running bridge — safest. The old-client raw link also works.)
3. Ask your agent to run `list-clients` — your username should appear. First connect runs a full script-source map (~380 scripts) so `script-grep` works later.

## 4. The toolbelt (what actually works — verified 2026-08-10)
| Works | Notes |
|---|---|
| `hot-reload` / `execute` / `execute-file` | THE run channel. `hot-reload` returns `applied`/error and preserves `getgenv` STATE. |
| `get-data-by-code` | Live reads (attributes, parts). **Use for verification.** |
| `require()` of game modules | Works incl. obfuscated `Modules.Print.WarnModule`. |
| `search-instances` / `get-descendants-tree` / `get-script-content` | Instances + decompile of game client scripts and ModuleScripts. |

| Avoid / broken | Why |
|---|---|
| `screenshot-window` | Fine OS-level, but if the agent's model is **text-only** (e.g. `syn:large:text`) image inputs **400**. Verify via `get-data-by-code` instead. |
| `ensure-scanX` + scanX tools / `semantic-search-scripts` | scanX errors in current executor; semantic search needs an unconfigured OpenAI key. |
| `script-grep` | 0 hits until the initial script-source map finishes. |

## 5. The helper-agent cheat sheet (what made this fast)
- **Exposed hub API.** The loaded hub lives at `getgenv().__SprayHub` and exposes `runJob(blobList, opts)`, `build.fill/pattern/rainbow/spray/image`, `aimFrame()`, `applyBrush()`, `paintImage()`, `setPreview(v)`. An agent can trigger + test features directly, not just the UI.
- **Anticheat keys.** `require(game:GetService('ReplicatedStorage').Modules.Print.WarnModule)()` → `(key1, key2)`; pass to `ClientToServer.sendToServer`. Call fresh per flush. Don't reverse the VM.
- **Verify paint.** Count non-`Client` `BasePart`s under `workspace.PaintFolder[LocalPlayer.Name]`. The `PaintCount` attr is lifetime + lags — never trust a single early read.
- **Constraints (server-enforced):** within 40 studs of character; brush size ≤ account cap; effects need real gamepass.
- **State churn:** `getgenv` clears on re-inject/respawn (hub disappears; just reload). Tests must be self-contained in one execute/read pair, and always print which wall position you used (the player may move).

## 6. Reproduce the open bug (recommended first task)
Issue #1 (multi-color batch): single-color visible paint persists fully, a mixed-color batch → +1. Re-run the group-by-color-per-flush experiment in `docs/ISSUES.md`. Everything you need (engine, exposed API, decoder) is already in the repo.
