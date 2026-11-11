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

Every session needs its own name, because that is how the agent tells them
apart. `clauder.start()` uses `default`, which is also the name the R addin
fills in. If an R or another Python session already holds it, you will see

```
RuntimeError: Session name 'default' is already owned by a live or unknown process
```

Start this one with a name of its own, as above, and tell the agent to
connect to that name.
