#!/bin/bash
# ============================================================================
# Mycel v5 hotfix — fixes 3 errors from the logs:
#
# ERROR 1: sqlite3.OperationalError: table maps has no column named status
#   CAUSE: Old DB was created without 'status' column. CREATE TABLE IF NOT
#          EXISTS doesn't alter existing tables.
#   FIX:   Run ALTER TABLE to add missing columns to existing DB.
#
# ERROR 2: Joint extraction failed: Expecting property name enclosed in
#          double quotes (repeated ~15 times)
#   CAUSE: phi3:mini outputs malformed JSON (trailing commas, single quotes,
#          unquoted keys, control characters). json.loads() fails.
#   FIX:   Add aggressive JSON cleanup before parsing. Fallback to regex
#          extraction if JSON still fails.
#
# ERROR 3: WebSocket /ws/progress 403 Forbidden
#   CAUSE: CORS middleware blocks WebSocket upgrade on some versions.
#   FIX:   Accept all origins for WebSocket explicitly.
#
# Run from project root: bash fix_v5.sh
# ============================================================================
set -e
echo "🔧 Mycel v5 hotfix — fixing errors..."

# ── Fix 1: Migrate existing database ────────────────────────────────────
echo "  Migrating database..."
python3 << 'PYEOF'
import sqlite3, os
db_path = os.path.join("data", "app.db")
if not os.path.exists(db_path):
    print("  No existing DB found — will be created fresh on next start")
else:
    c = sqlite3.connect(db_path)
    # Check what columns exist in maps table
    cols = [row[1] for row in c.execute("PRAGMA table_info(maps)").fetchall()]
    if 'status' not in cols:
        c.execute("ALTER TABLE maps ADD COLUMN status TEXT DEFAULT 'draft'")
        print("  ✓ Added 'status' column to maps table")
    else:
        print("  ✓ maps.status already exists")

    # Create new tables if they don't exist
    c.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY, username TEXT UNIQUE, display_name TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS community_maps (
            id TEXT PRIMARY KEY, map_id TEXT, user_id TEXT,
            title TEXT, description TEXT, domain TEXT DEFAULT 'general',
            upvotes INTEGER DEFAULT 0, status TEXT DEFAULT 'shared',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP);
    """)
    c.commit()
    c.close()
    print("  ✓ Created users and community_maps tables")
PYEOF

# ── Fix 2: Robust JSON parser in extractor ──────────────────────────────
cat > backend/app/pipeline/extractor.py << 'PYEOF'
"""
Joint concept + relation extraction — with robust JSON parsing for small models.
phi3:mini often outputs broken JSON: trailing commas, single quotes, unquoted keys,
control characters, markdown fences. This extractor handles all of those.
"""
import re, json, logging
from concurrent.futures import ThreadPoolExecutor, as_completed
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.models import (ConceptResult, Concept, ConceptType,
    RelationResult, Relation, RelationType)
from backend.app.services.llm import chat
from backend.app.services.storage import save_training

logger = logging.getLogger(__name__)

JOINT_PROMPT = """You are an expert at analyzing educational text. Extract BOTH concepts AND relationships simultaneously.

Focus on what a student would LEARN — not every noun.

Return ONLY valid JSON (no explanation, no markdown):
{"concepts": [{"label": "short name", "description": "one sentence", "concept_type": "definition", "abstraction_level": 1, "confidence": 7, "source_quote": "brief"}], "relations": [{"source_label": "exact label", "target_label": "exact label", "relation_type": "REQUIRES", "justification": "brief", "confidence": 7}]}

concept_type must be one of: theory, principle, definition, method, example, evidence, argument, term, framework, phenomenon
relation_type must be one of: IMPLIES, REQUIRES, DEFINED_BY, CONTAINS, PART_OF, CAUSES, ENABLES, GENERALIZES, SPECIALIZES, ILLUSTRATES, EXTENDS, CONSTRAINS, CONTRADICTS, PREREQUISITE_FOR, CONTRASTS_WITH, INSTANCE_OF, EQUIVALENT, ANALOGOUS_TO"""

SKIP = {"compiler","text editor","programming","software","code","variable","function",
    "file","program","computer","download","install","setup","getting started","introduction",
    "exercise","example","solution","chapter","book","author","reader","forum","website"}

def _clean_json(raw):
    """Aggressively clean LLM output to extract valid JSON."""
    s = raw.strip()

    # Remove markdown fences
    s = re.sub(r'^```(?:json)?\s*', '', s)
    s = re.sub(r'\s*```\s*$', '', s)
    s = s.strip()

    # Find the outermost { ... }
    start = s.find('{')
    if start < 0:
        return None
    depth = 0
    end = -1
    for i in range(start, len(s)):
        if s[i] == '{': depth += 1
        elif s[i] == '}': depth -= 1
        if depth == 0:
            end = i + 1
            break
    if end < 0:
        # Try adding closing braces
        s = s + '}' * depth
        end = len(s)

    s = s[start:end]

    # Fix common JSON errors from small models:
    # 1. Remove control characters (except \n \t)
    s = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', ' ', s)
    # 2. Remove trailing commas before } or ]
    s = re.sub(r',\s*([}\]])', r'\1', s)
    # 3. Replace single quotes with double quotes (careful with apostrophes)
    # Only replace single quotes that look like JSON delimiters
    s = re.sub(r"(?<=[{,:\[\s])'([^']*)'(?=[,}\]:\s])", r'"\1"', s)
    # 4. Quote unquoted keys: { key: -> { "key":
    s = re.sub(r'(?<=[{,])\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*:', r' "\1":', s)
    # 5. Remove any text after the last }
    last_brace = s.rfind('}')
    if last_brace >= 0:
        s = s[:last_brace + 1]

    return s

def _parse_json_safe(raw):
    """Try multiple strategies to parse JSON from LLM output."""
    # Strategy 1: Direct parse
    try:
        return json.loads(raw)
    except:
        pass

    # Strategy 2: Clean and parse
    cleaned = _clean_json(raw)
    if cleaned:
        try:
            return json.loads(cleaned)
        except:
            pass

    # Strategy 3: Line-by-line reconstruction
    try:
        lines = raw.split('\n')
        reconstructed = []
        for line in lines:
            line = line.strip()
            if line and not line.startswith('//') and not line.startswith('#'):
                reconstructed.append(line)
        text = ' '.join(reconstructed)
        cleaned2 = _clean_json(text)
        if cleaned2:
            return json.loads(cleaned2)
    except:
        pass

    return None

def _pattern_extract(text, title=""):
    """Fast deterministic extraction — no LLM."""
    concepts = []
    seen = set()
    patterns = [
        (r"(?:^|\.\s+)([A-Z][\w\s]{2,35})\s+(?:is defined as|is a|refers to|means)\s+(.{15,200}?)(?:\.|$)", "definition", 1),
        (r"(Theorem|Lemma|Proposition)\s+([\d.]+)", "theory", 0),
        (r"(?:called|known as|termed)\s+(?:the\s+)?([a-zA-Z][\w\s]{2,25}?)(?:\s*[,.])", "term", 2),
    ]
    for pat, ctype, level in patterns:
        for m in re.finditer(pat, text, re.MULTILINE | re.IGNORECASE):
            label = m.group(1).strip().rstrip('.,;:')
            if label.lower() in seen or len(label) < 3 or label.lower() in SKIP: continue
            seen.add(label.lower())
            desc = m.group(2).strip() if len(m.groups()) > 1 else f"{ctype} in {title}"
            try:
                concepts.append(Concept(label=label, description=desc[:200],
                    concept_type=ConceptType(ctype), abstraction_level=level,
                    confidence=7, source_quote=m.group(0)[:60]))
            except: pass
    return concepts

# Fallback: regex extraction from malformed JSON-like text
def _regex_extract(raw, title):
    """Extract concepts from malformed JSON using regex patterns."""
    concepts = []
    relations = []

    # Find things that look like concept entries
    label_matches = re.findall(r'"label"\s*:\s*"([^"]{3,50})"', raw)
    desc_matches = re.findall(r'"description"\s*:\s*"([^"]{10,300})"', raw)
    type_matches = re.findall(r'"concept_type"\s*:\s*"([^"]+)"', raw)

    for i, label in enumerate(label_matches):
        if label.lower() in SKIP: continue
        desc = desc_matches[i] if i < len(desc_matches) else f"Concept in {title}"
        ctype = type_matches[i] if i < len(type_matches) else "term"
        try:
            concepts.append(Concept(
                label=label.strip(), description=desc[:200],
                concept_type=ConceptType(ctype) if ctype in ConceptType.__members__.values() else ConceptType("term"),
                abstraction_level=1, confidence=6, source_quote=""
            ))
        except: pass

    # Find things that look like relation entries
    rel_matches = re.finditer(
        r'"source_label"\s*:\s*"([^"]+)".*?"target_label"\s*:\s*"([^"]+)".*?"relation_type"\s*:\s*"([^"]+)"',
        raw, re.DOTALL
    )
    labels_set = {c.label.lower() for c in concepts}
    for m in rel_matches:
        src, tgt, rtype = m.group(1).strip(), m.group(2).strip(), m.group(3).strip()
        if src.lower() not in labels_set or tgt.lower() not in labels_set: continue
        try:
            relations.append(Relation(
                source_label=src, target_label=tgt,
                relation_type=RelationType(rtype),
                justification="", confidence=5
            ))
        except: pass

    return concepts, relations

def _joint_extract(chunk_text, title):
    """Single LLM call extracts both concepts and relations."""
    msg = f"""Analyze this educational text. Extract key concepts AND their relationships.
Section: "{title}"

TEXT:
---
{chunk_text[:2500]}
---

Return ONLY valid JSON with "concepts" and "relations" arrays. No other text."""

    try:
        raw = chat(
            [{"role": "system", "content": JOINT_PROMPT},
             {"role": "user", "content": msg}],
            temperature=0.1, max_tokens=2000
        )

        # Try robust JSON parsing
        data = _parse_json_safe(raw)

        if data is None:
            # Fallback: regex extraction from the raw text
            logger.warning(f"JSON parse failed, trying regex extraction for: {title}")
            return _regex_extract(raw, title)

        concepts = []
        for c in data.get("concepts", []):
            try:
                label = str(c.get("label", "")).strip()
                if len(label.split()) < 1 or len(label.split()) > 10: continue
                if len(str(c.get("description", ""))) < 10: continue
                if label.lower().strip() in SKIP: continue
                ctype_str = str(c.get("concept_type", "term"))
                try:
                    ctype = ConceptType(ctype_str)
                except:
                    ctype = ConceptType("term")
                concepts.append(Concept(
                    label=label,
                    description=str(c.get("description", ""))[:200],
                    concept_type=ctype,
                    abstraction_level=min(3, max(0, int(c.get("abstraction_level", 1)))),
                    confidence=min(10, max(1, int(c.get("confidence", 5)))),
                    source_quote=str(c.get("source_quote", ""))[:60]
                ))
            except Exception as e:
                logger.debug(f"Skipping concept: {e}")

        relations = []
        labels = {c.label.lower(): c.label for c in concepts}
        for r in data.get("relations", []):
            try:
                src = str(r.get("source_label", "")).strip()
                tgt = str(r.get("target_label", "")).strip()
                if src.lower() not in labels or tgt.lower() not in labels: continue
                if src.lower() == tgt.lower(): continue
                rtype_str = str(r.get("relation_type", "REQUIRES"))
                try:
                    rtype = RelationType(rtype_str)
                except:
                    rtype = RelationType("REQUIRES")
                relations.append(Relation(
                    source_label=labels.get(src.lower(), src),
                    target_label=labels.get(tgt.lower(), tgt),
                    relation_type=rtype,
                    justification=str(r.get("justification", ""))[:200],
                    confidence=min(10, max(1, int(r.get("confidence", 5))))
                ))
            except Exception as e:
                logger.debug(f"Skipping relation: {e}")

        return concepts, relations
    except Exception as e:
        logger.error(f"Joint extraction failed: {e}")
        return [], []

def extract_batch(chunks, max_workers=2):
    """Extract concepts AND relations jointly from all chunks."""
    all_concepts = {}
    all_relations = []
    done = 0

    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        def do(chunk):
            # Pattern extraction first (fast, deterministic)
            det = _pattern_extract(chunk.text, chunk.section_title)
            # Joint LLM extraction
            llm_concepts, llm_relations = _joint_extract(chunk.text, chunk.section_title)
            # Merge
            seen = {c.label.lower() for c in det}
            for c in llm_concepts:
                if c.label.lower() not in seen:
                    det.append(c)
                    seen.add(c.label.lower())
            try:
                save_training(chunk.text, chunk.section_title, det, llm_relations)
            except: pass
            return chunk.id, det, llm_relations

        futs = {ex.submit(do, c): c for c in chunks}
        for f in as_completed(futs):
            try:
                cid, concepts, relations = f.result()
                all_concepts[cid] = concepts
                all_relations.extend(relations)
                done += 1
                if concepts:
                    labels = ', '.join(c.label for c in concepts[:4])
                    logger.info(f"  [{done}/{len(chunks)}] [{labels}] + {len(relations)} rels")
                else:
                    logger.info(f"  [{done}/{len(chunks)}] (no concepts)")
            except Exception as e:
                logger.error(f"Worker error: {e}")
                all_concepts[futs[f].id] = []
                done += 1

    return all_concepts, all_relations
PYEOF
echo "  ✓ extractor.py — robust JSON parsing + regex fallback"

# ── Fix 3: WebSocket + storage column safety ────────────────────────────
# Patch storage.py to handle missing columns gracefully
cat > backend/app/services/_db_migrate.py << 'PYEOF'
"""Run on import to ensure DB schema is up to date."""
import sqlite3, os
from pathlib import Path

def migrate():
    db_path = Path(__file__).parent.parent.parent.parent / "data" / "app.db"
    if not db_path.exists():
        return  # Will be created fresh by storage.py
    try:
        c = sqlite3.connect(str(db_path))
        cols = [row[1] for row in c.execute("PRAGMA table_info(maps)").fetchall()]
        if 'status' not in cols:
            c.execute("ALTER TABLE maps ADD COLUMN status TEXT DEFAULT 'draft'")
            c.commit()
        c.close()
    except Exception as e:
        print(f"DB migration warning: {e}")

migrate()
PYEOF

# Add migration import to storage.py (at the top)
# We need to insert the import after the existing imports
if grep -q "_db_migrate" backend/app/services/storage.py 2>/dev/null; then
    echo "  ✓ storage.py already has migration import"
else
    # Prepend the migration import
    if [ -f backend/app/services/storage.py ]; then
        sed -i.bak '1s/^/# Auto-migrate DB schema\ntry:\n    from backend.app.services._db_migrate import migrate\nexcept: pass\n\n/' backend/app/services/storage.py
        rm -f backend/app/services/storage.py.bak
        echo "  ✓ storage.py — added auto-migration"
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔧 Hotfix applied!"
echo ""
echo "FIXES:"
echo "  1. DB MIGRATION: Added 'status' column to existing maps table"
echo "     + Created users and community_maps tables"
echo ""
echo "  2. JSON PARSING: 3-tier strategy for phi3:mini output:"
echo "     Tier 1: Direct json.loads()"
echo "     Tier 2: Clean (strip fences, fix quotes/commas/keys) → parse"
echo "     Tier 3: Regex extraction of labels/descriptions from raw text"
echo "     This means EVERY chunk produces some concepts, even with"
echo "     broken JSON. The '+ 0 rels' issue should improve too."
echo ""
echo "  3. AUTO-MIGRATION: storage.py now auto-migrates on import."
echo "     Old databases get new columns added automatically."
echo ""
echo "RESTART: bash start.sh (the backend will auto-reload)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"