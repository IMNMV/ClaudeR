from .server import serve
import asyncio


def main():
    """ClaudeR MCP Server - RStudio integration for AI assistants."""
    asyncio.run(serve())


if __name__ == "__main__":
    main()
