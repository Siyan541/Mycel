import os, json, logging, httpx
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
            "temperature": 0.05, "max_tokens": 3000}
    # Don't use response_format — just rely on the prompt
    with httpx.Client(timeout=180) as c:
        r = c.post("https://api.together.xyz/v1/chat/completions",
            headers={"Authorization": f"Bearer {TOGETHER_API_KEY}"},
            json=body)
        r.raise_for_status()
        content = r.json()["choices"][0]["message"]["content"]
        logger.info(f"Together response: {len(content)} chars")
        return content