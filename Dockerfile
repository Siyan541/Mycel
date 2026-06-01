FROM python:3.11-slim
WORKDIR /app
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt httpx
COPY backend/ backend/
COPY entrypoint.sh .
RUN mkdir -p uploads data
RUN touch backend/__init__.py backend/app/__init__.py backend/app/pipeline/__init__.py backend/app/services/__init__.py
RUN chmod +x entrypoint.sh
CMD ["./entrypoint.sh"]