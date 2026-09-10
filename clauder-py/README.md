# clauder

Expose a live Python session to MCP-based AI agents. The Python half of
[ClaudeR](https://github.com/IMNMV/ClaudeR).

```python
import clauder
clauder.start()
```

The agent then executes code in this session, where your loaded data and
fitted models already are, and sees the figures it draws. Every line it runs
is logged and attributed. Works in Positron, Jupyter, VS Code, and a bare
REPL.

```python
clauder.start(session_name = "analysis", port = 8790)
clauder.status()
clauder.stop()
```
