# Flippie Figma MCP

Read-only MCP server for pulling Figma design data into Codex while working on Flippie.

## Token setup

Create a Figma personal access token with read access, then store it in macOS Keychain:

```sh
security add-generic-password -U -s codex-figma-token -a "$USER" -w "YOUR_FIGMA_TOKEN"
```

The server also supports `FIGMA_ACCESS_TOKEN`, but Keychain is preferred so secrets do not live in the repo or Codex config.

## Codex config

Add this to `~/.codex/config.toml`:

```toml
[mcp_servers.figma_flippie]
command = "/usr/bin/env"
args = ["node", "/Users/Wickone/Documents/iOS/Flippie/Tools/FigmaMCP/server.mjs"]
startup_timeout_sec = 30
```

Restart Codex after changing MCP config.

## Tools

- `figma_parse_url` extracts `fileKey` and `nodeId` from a Figma URL.
- `figma_get_file` reads file data.
- `figma_get_node` reads a specific node/frame.
- `figma_export_images` exports node image URLs.
- `figma_get_styles` lists published file styles.
- `figma_design_summary` returns a compact implementation-focused tree.
