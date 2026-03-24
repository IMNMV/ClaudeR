FROM python:3.12-slim
RUN pip install clauder-mcp
CMD ["clauder-mcp"]
