import os, json, logging, httpx

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.config import LLM_PROVIDER, LLM_MODEL, TOGETHER_API_KEY, TOGETHER_MODEL

logger = logging.getLogger(__name__)

def chat(messages, json_schema=None, temperature=0.1, max_tokens=1500):
    if LLM_PROVIDER == "together":
        return _together(messages, json_schema, temperature, max_tokens)
    return _ollama(messages, json_schema, temperature, max_tokens)

def _ollama(messages, schema, temp, max_tok):
    import ollama as ol
    kw = {"model": LLM_MODEL, "messages": messages,
          "options": {"temperature": temp, "num_ctx": 4096, "num_predict": max_tok}}
    if schema: kw["format"] = schema
    return ol.chat(**kw).message.content

def _together(messages, schema, temp, max_tok):
    body = {"model": TOGETHER_MODEL, "messages": messages,
            "temperature": temp, "max_tokens": max_tok}
    if schema:
        body["response_format"] = {"type": "json_schema",
            "json_schema": {"name": "extraction", "schema": schema}}
    with httpx.Client(timeout=120) as c:
        r = c.post("https://api.together.xyz/v1/chat/completions",
            headers={"Authorization": f"Bearer {TOGETHER_API_KEY}", "Content-Type": "application/json"},
            json=body)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]
