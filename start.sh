#!/bin/bash
cd "$(dirname "$0")"
python -m uvicorn backend.app.main:app --reload --port 8000 --host 0.0.0.0
