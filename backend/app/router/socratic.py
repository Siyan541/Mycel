# backend/app/routes/socratic.py
# Conversational Socratic tutor endpoint.  Mount with: app.include_router(router)
import logging
from fastapi import APIRouter, Body

# adjust this import to match your project (same helper the extractor uses)
from backend.app.services.llm import chat

logger = logging.getLogger(__name__)
router = APIRouter()

SOC_SYSTEM = (
    "You are a Socratic tutor. You NEVER state facts, give answers, or ask the student "
    "to edit, click, or rearrange a diagram. You ask exactly ONE short, open question "
    "that pushes the student to reason about MEANING and UNDERSTANDING: why ideas relate, "
    "what assumptions they rest on, where a theory breaks, how they would explain or apply it, "
    "or what would change if something were false. Build on the student's previous answer. "
    "One question only, under 30 words, no preamble, no quotation marks."
)

FALLBACK = (
    "Explain, in your own words, why these ideas belong together — and what would be lost "
    "if you studied them separately?"
)


@router.post("/api/socratic")
async def socratic(body: dict = Body(...)):
    mp = body.get("map") or {}
    concepts = mp.get("concepts") or ""
    history = body.get("history") or []
    answer = body.get("answer") or ""

    convo_lines = []
    for h in history:
        q = (h.get("q") or "").strip()
        a = (h.get("a") or "").strip()
        if q:
            convo_lines.append("Q: " + q)
        if a:
            convo_lines.append("A: " + a)
    convo = "\n".join(convo_lines) or "(none yet)"

    user = (
        "Topic concepts: " + str(concepts) + "\n\n"
        "Dialogue so far:\n" + convo + "\n\n"
        "Student's latest answer: " + (answer or "(none yet)") + "\n\n"
        "Ask the next single Socratic question."
    )

    try:
        raw = chat(
            [{"role": "system", "content": SOC_SYSTEM},
             {"role": "user", "content": user}],
            temperature=0.6,
        )
        q = (raw or "").strip().strip('"').split("\n")[0].strip()
        if not q:
            raise ValueError("empty completion")
        return {"question": q}
    except Exception as e:
        logger.warning("socratic generation failed: %s", e)
        return {"question": FALLBACK}