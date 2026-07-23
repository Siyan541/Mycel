"""Mycel — Stage 2 canonical KB grounding.

Embed each concept, nearest-neighbour to a canonical KB entry (brute-force
cosine over a small seed KB; sqlite-vec is a later scale optimization), attach
canonical_id + link_score, then dedup nodes that resolve to the same entry.
Reuses the SAME fastembed model as provenance (bge-small, 384-d), so the space
is shared and the dimension stays locked. Graceful: any failure is a no-op —
grounding never breaks extraction. Code nodes are skipped (already canonical).
"""
import os, json, sqlite3, logging
logger = logging.getLogger(__name__)
_HERE = os.path.dirname(os.path.abspath(__file__))
SEED_PATH = os.path.join(_HERE, "kb_seed.json")
try:
    from backend.app.config import DATA_DIR
    KB_DB = str(DATA_DIR / "kb.db")
except Exception:
    KB_DB = os.path.join(_HERE, "kb.db")
CODE_TYPES = {"module","class","function","parameter","constant","variable","type","interface","test","decorator"}

def _get(o,k,d=None): return (o.get(k,d) if isinstance(o,dict) else getattr(o,k,d))
def _set(o,k,v):
    if isinstance(o,dict): o[k]=v
    else:
        try: setattr(o,k,v)
        except Exception: pass

def _enc(texts):
    """Encode with the shared provenance embedder (fastembed bge-small, 384-d), normalized."""
    try:
        from backend.app.services.media import _embedder, _encode
        emb=_embedder()
        if emb is None: return None
        import numpy as np
        v=np.asarray(_encode(emb, list(texts)), dtype="float32")
        nrm=(v*v).sum(1,keepdims=True)**0.5; nrm[nrm==0]=1.0
        return v/nrm
    except Exception as e:
        logger.warning("kb: embedder unavailable: %s", e); return None

def _conn():
    c=sqlite3.connect(KB_DB)
    c.execute("""CREATE TABLE IF NOT EXISTS kb_entries(canonical_id TEXT PRIMARY KEY,
        label TEXT, aliases TEXT, description TEXT, domain TEXT, dim INTEGER, embedding BLOB)""")
    return c

def seed_kb():
    """Embed + store any seed entries not yet in the KB. Idempotent."""
    try: entries=json.load(open(SEED_PATH))
    except Exception as e: logger.warning("kb: no seed (%s)", e); return 0
    c=_conn(); have=set(r[0] for r in c.execute("SELECT canonical_id FROM kb_entries"))
    todo=[e for e in entries if e.get("canonical_id") not in have]
    if not todo: c.close(); return 0
    V=_enc([(e.get("label","")+". "+e.get("description","")) for e in todo])
    if V is None: c.close(); return 0
    import numpy as np
    for e,vec in zip(todo,V):
        c.execute("INSERT OR REPLACE INTO kb_entries VALUES (?,?,?,?,?,?,?)",
            (e["canonical_id"], e.get("label",""), json.dumps(e.get("aliases",[])),
             e.get("description",""), e.get("domain",""), len(vec),
             np.asarray(vec,dtype="float32").tobytes()))
    c.commit(); n=len(todo); c.close(); logger.info("kb: seeded %d entries", n); return n

def _load_matrix():
    c=_conn(); rows=list(c.execute("SELECT canonical_id,label,description,domain,dim,embedding FROM kb_entries")); c.close()
    if not rows: return None
    import numpy as np
    meta=[]; vecs=[]
    for cid,label,desc,domain,dim,blob in rows:
        v=np.frombuffer(blob,dtype="float32")
        if dim and len(v)==dim: vecs.append(v); meta.append((cid,label,desc,domain))
    if not vecs: return None
    return np.vstack(vecs), meta

def link_concepts(nodes, min_score=0.55):
    """Attach canonical_id + link_score to concept nodes (skips code nodes)."""
    try:
        seed_kb()
        M=_load_matrix()
        if M is None: return nodes
        mat,meta=M
        targets=[n for n in nodes if _get(n,"concept_type") not in CODE_TYPES]
        if not targets: return nodes
        Q=_enc([((_get(n,"label","") or "")+". "+(_get(n,"description","") or "")) for n in targets])
        if Q is None: return nodes
        sims=Q @ mat.T
        best=sims.argmax(1); bestsc=sims.max(1)
        for n,bi,sc in zip(targets,best,bestsc):
            if float(sc)>=min_score:
                cid,label,desc,domain=meta[int(bi)]
                _set(n,"canonical_id",cid); _set(n,"link_score",round(float(sc),3))
                if domain: _set(n,"cluster",domain)
        if os.environ.get("KB_WIKIDATA","")=="1":
            import numpy as np, json as _json
            for n in targets:
                if _get(n,"canonical_id"): continue
                ent=fetch_wikidata(_get(n,"label","") or "")
                if not ent: continue
                ev=_enc([ent["label"]+". "+(ent.get("description","") or "")])
                if ev is None: continue
                c=_conn(); c.execute("INSERT OR REPLACE INTO kb_entries VALUES (?,?,?,?,?,?,?)",
                    (ent["canonical_id"],ent["label"],_json.dumps([]),ent.get("description",""),
                     ent.get("domain",""),len(ev[0]),np.asarray(ev[0],dtype="float32").tobytes()))
                c.commit(); c.close()
                q=_enc([((_get(n,"label","") or "")+". "+(_get(n,"description","") or ""))])
                if q is None: continue
                s2=float(q[0] @ ev[0])
                if s2>=min_score: _set(n,"canonical_id",ent["canonical_id"]); _set(n,"link_score",round(s2,3))
        return nodes
    except Exception as e:
        logger.warning("kb link: %s", e); return nodes

def dedup_by_canonical(graph):
    """Merge nodes that resolved to the same canonical_id; reroute edges."""
    try:
        nodes=graph.nodes; edges=graph.edges; groups={}
        for n in nodes:
            cid=_get(n,"canonical_id","")
            if cid: groups.setdefault(cid,[]).append(n)
        remap={}; drop=set()
        for cid,grp in groups.items():
            if len(grp)<2: continue
            grp.sort(key=lambda n:(_get(n,"confidence",0) or 0), reverse=True)
            kid=_get(grp[0],"id")
            for other in grp[1:]: remap[_get(other,"id")]=kid; drop.add(_get(other,"id"))
        if not drop: return graph
        graph.nodes=[n for n in nodes if _get(n,"id") not in drop]
        seen=set(); ne=[]
        for e in edges:
            s=remap.get(_get(e,"source_id"),_get(e,"source_id")); t=remap.get(_get(e,"target_id"),_get(e,"target_id"))
            if s==t: continue
            _set(e,"source_id",s); _set(e,"target_id",t)
            k=(s,t,_get(e,"relation_type"))
            if k in seen: continue
            seen.add(k); ne.append(e)
        graph.edges=ne; return graph
    except Exception as e:
        logger.warning("kb dedup: %s", e); return graph

def ground(graph, min_score=0.55):
    link_concepts(graph.nodes, min_score); dedup_by_canonical(graph); return graph

def fetch_wikidata(term, lang="en"):
    """Optional, network. Returns a KB-entry dict with a real wd:Q... id, or None."""
    try:
        import urllib.request, urllib.parse
        q=urllib.parse.urlencode({"action":"wbsearchentities","search":term,
            "language":lang,"format":"json","limit":1})
        with urllib.request.urlopen("https://www.wikidata.org/w/api.php?"+q, timeout=8) as r:
            data=json.load(r)
        hits=data.get("search",[])
        if not hits: return None
        h=hits[0]
        return {"canonical_id":"wd:"+h["id"],"label":h.get("label",term),
                "aliases":[], "description":h.get("description",""), "domain":""}
    except Exception as e:
        logger.warning("kb wikidata: %s", e); return None
