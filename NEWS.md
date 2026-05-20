# ClaudeR News

## Unreleased

- Added optional async job progress reporting through `clauder_progress(stage, message = NULL, percent = NULL)` and MCP `get_async_result` progress text.
- Hardened Windows multi-session stale discovery cleanup by replacing `tools::pskill(pid, signal = 0)` liveness probing with a read-only PID check.
- Added regression coverage for async progress sidecar helpers, MCP bridge progress text, and Windows-safe cleanup.
