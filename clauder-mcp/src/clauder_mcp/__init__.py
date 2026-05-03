from .server import main as _server_main
import asyncio


def main():
    """ClaudeR MCP Server - RStudio integration for AI assistants."""
    asyncio.run(_server_main())


if __name__ == "__main__":
    main()
