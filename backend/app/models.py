from pydantic import BaseModel, Field
from enum import Enum
from typing import Optional

class ConceptType(str, Enum):
    theory="theory"; principle="principle"; definition="definition"
    method="method"; example="example"; evidence="evidence"
    argument="argument"; term="term"; framework="framework"
    phenomenon="phenomenon"


class CodeEntityType(str, Enum):
    MODULE="module"; CLASS="class"; FUNCTION="function"; TYPE="type"
    VARIABLE="variable"; PARAMETER="parameter"; CONSTANT="constant"
    INTERFACE="interface"; TEST="test"; DECORATOR="decorator"

class CodeRelationType(str, Enum):
    CALLS="CALLS"; INSTANTIATES="INSTANTIATES"; RETURNS="RETURNS"; THROWS="THROWS"; OVERRIDES="OVERRIDES"
    READS="READS"; WRITES="WRITES"; PASSES_TO="PASSES_TO"; DEPENDS_ON="DEPENDS_ON"
    DEFINES="DEFINES"; CONTAINS="CONTAINS"; IMPORTS="IMPORTS"; EXPORTS="EXPORTS"
    HAS_TYPE="HAS_TYPE"; IMPLEMENTS="IMPLEMENTS"; INHERITS="INHERITS"; CONSTRAINS="CONSTRAINS"; INSTANCE_OF="INSTANCE_OF"

class RelationType(str, Enum):
    IMPLIES="IMPLIES"; REQUIRES="REQUIRES"; DEFINED_BY="DEFINED_BY"
    CONTAINS="CONTAINS"; PART_OF="PART_OF"; CAUSES="CAUSES"
    ENABLES="ENABLES"; GENERALIZES="GENERALIZES"; SPECIALIZES="SPECIALIZES"
    ILLUSTRATES="ILLUSTRATES"; EXTENDS="EXTENDS"; CONSTRAINS="CONSTRAINS"
    CONTRADICTS="CONTRADICTS"; PREREQUISITE_FOR="PREREQUISITE_FOR"
    CONTRASTS_WITH="CONTRASTS_WITH"; INSTANCE_OF="INSTANCE_OF"
    EQUIVALENT="EQUIVALENT"; ANALOGOUS_TO="ANALOGOUS_TO"

class Section(BaseModel):
    id: str; title: str; level: int; page_start: int; page_end: int
    text: str = ""; parent_id: Optional[str] = None

class Skeleton(BaseModel):
    filename: str; total_pages: int; sections: list[Section]

class Chunk(BaseModel):
    id: str; section_id: str; section_title: str; text: str

# confidence is now a 0–1 float everywhere (was 1–10 int).
class Concept(BaseModel):
    label: str; description: str; concept_type: ConceptType
    abstraction_level: int = Field(ge=0, le=3, default=1)
    confidence: float = Field(ge=0.0, le=1.0, default=0.7)
    source_quote: str = ""
    in_text: bool = True                 # False = prerequisite / not defined here

class ConceptResult(BaseModel):
    concepts: list[Concept]

# repaired: single confidence field, no stray required source/target,
# relation_type back to the enum (matches GraphEdge).
class Relation(BaseModel):
    source_label: str
    target_label: str
    relation_type: RelationType = RelationType.REQUIRES
    justification: str = ""
    confidence: float = Field(ge=0.0, le=1.0, default=0.6)
    evidence: str = ""

class RelationResult(BaseModel):
    relations: list[Relation]

class GraphNode(BaseModel):
    canonical_id: str = ""       # KB grounding (Stage 2)
    link_score: float = 0.0      # 0-1 similarity to the canonical entry
    signature: str = ""; language: str = ""; file_path: str = ""; line: int = 0; kind_detail: str = ""
    id: str; label: str; description: str
    concept_type: str = "term"
    abstraction_level: int = 1
    cluster: str = ""
    confidence: float = 0.7              # 0–1, UI confidence filter
    source_page: int = 0                 # media.attach_provenance
    source_quote: str = ""               # verbatim definition sentence
    source_score: float = 0.0            # provenance match strength 0–1 (explainability)
    in_text: bool = True                 # False = prerequisite/inferred
    mentions: list = Field(default_factory=list)   # all ranked source sentences

class GraphEdge(BaseModel):
    id: str; source_id: str; target_id: str
    relation_type: RelationType | CodeRelationType
    justification: str = ""
    confidence: float                    # 0–1
    page: int = 0                        # media.attach_relation_provenance
    evidence: str = ""                   # verbatim relationship sentence

class KnowledgeGraph(BaseModel):
    document_name: str; nodes: list[GraphNode]; edges: list[GraphEdge]
    metadata: dict = Field(default_factory=dict)

# ── User & Credit models ──
class UserLevel(str, Enum):
    none="none"; beginner="beginner"; experienced="experienced"
    expert="expert"; professional="professional"; organizer="organizer"

LEVEL_THRESHOLDS = {"none":0,"beginner":1,"experienced":75,
                    "expert":300,"professional":1000,"organizer":5000}

def get_level(points):
    level="none"
    for name, threshold in LEVEL_THRESHOLDS.items():
        if points >= threshold: level = name
    return level
