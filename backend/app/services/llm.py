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
    """Local, free. Tries structured outputs (Ollama >= 0.5); falls back to
    format='json', then plain — so older Ollama versions still work."""
    import ollama as ol
    opts = {"temperature": temp, "num_ctx": 4096, "num_predict": max_tok}
    if schema:
        try:
            return ol.chat(model=LLM_MODEL, messages=messages,
                           format=schema, options=opts).message.content
        except Exception as e:
            logger.warning("ollama schema format failed (%s); retrying format=json", e)
            try:
                return ol.chat(model=LLM_MODEL, messages=messages,
                               format="json", options=opts).message.content
            except Exception as e2:
                logger.warning("ollama json format failed (%s); plain call", e2)
    return ol.chat(model=LLM_MODEL, messages=messages, options=opts).message.content

def _together(messages, schema, temp, max_tok):
    body = {"model": TOGETHER_MODEL, "messages": messages,
            "temperature": temp, "max_tokens": max_tok}
    if schema:
        body["response_format"] = {"type": "json_schema",
            "json_schema": {"name": "extraction", "schema": schema}}
    with httpx.Client(timeout=120) as c:
        r = c.post("https://api.together.xyz/v1/chat/completions",
            headers={"Authorization": f"Bearer {TOGETHER_API_KEY}",
                     "Content-Type": "application/json"},
            json=body)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]
