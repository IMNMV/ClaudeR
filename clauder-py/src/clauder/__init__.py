"""clauder: expose a live Python session to MCP agents.

    import clauder
    clauder.start()

Speaks the same protocol as the ClaudeR R addin, so one MCP bridge reaches
both an R session and a Python session, and an agent picks either by name.
"""

from .server import start, status, stop

__version__ = "0.1.1"
__all__ = ["start", "stop", "status"]
