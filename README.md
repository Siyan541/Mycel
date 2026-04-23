# Knowledge Graph Engine

Upload a textbook chapter → see concepts and how they connect → edit to train the AI.

## Quick Start (Local)

```bash
pip install -r backend/requirements.txt
ollama serve &
ollama pull qwen2.5:3b
bash start.sh          # Terminal 1: backend
cd frontend && npm install && npm run dev  # Terminal 2: frontend
```

Open http://localhost:5173

## Deploy to Web

See LAUNCH_GUIDE.md for Railway + Vercel deployment.
