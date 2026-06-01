FROM python:3.11-slim
WORKDIR /app
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt httpx ollama
COPY backend/ backend/
RUN mkdir -p uploads data
RUN touch backend/__init__.py backend/app/__init__.py backend/app/pipeline/__init__.py backend/app/services/__init__.py
ENV PORT=8000
CMD uvicorn backend.app.main:app --host 0.0.0.0 --port $PORT