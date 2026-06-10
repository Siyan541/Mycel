from pydantic import BaseModel, Field
from enum import Enum
from typing import Optional

class ConceptType(str, Enum):
    theory="theory"; principle="principle"; definition="definition"
    method="method"; example="example"; evidence="evidence"
    argument="argument"; term="term"; framework="framework"
    phenomenon="phenomenon"

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

class Concept(BaseModel):
    label: str; description: str; concept_type: ConceptType
    abstraction_level: int = Field(ge=0, le=3)
    confidence: int = Field(ge=1, le=10)
    source_quote: str = ""

class ConceptResult(BaseModel):
    concepts: list[Concept]

class Relation(BaseModel):
    source_label: str; target_label: str
    relation_type: RelationType
    justification: str = ""; confidence: int = Field(ge=1, le=10)
    page: int = 0
    evidence: str = ""

class RelationResult(BaseModel):
    relations: list[Relation]

class GraphNode(BaseModel):
    id: str; label: str; description: str; concept_type: ConceptType
    abstraction_level: int; confidence: float
    cluster: str = ""; source_page: int = 0

class GraphEdge(BaseModel):
    id: str; source_id: str; target_id: str; relation_type: RelationType
    justification: str; confidence: float

class KnowledgeGraph(BaseModel):
    document_name: str; nodes: list[GraphNode]; edges: list[GraphEdge]
    metadata: dict = Field(default_factory=dict)

# ── User & Credit models ──
class UserLevel(str, Enum):
    none = "none"
    beginner = "beginner"
    experienced = "experienced"
    expert = "expert"
    professional = "professional"
    organizer = "organizer"

LEVEL_THRESHOLDS = {
    "none": 0, "beginner": 1, "experienced": 75,
    "expert": 300, "professional": 1000, "organizer": 5000
}

# Professional requires: 1000+ pts, 10+ confirmed maps, 50+ community upvotes
# Organizer requires: 5000+ pts, 25+ confirmed maps, admin approval
# These are checked in storage.py get_effective_level()

def get_level(points):
    level = "none"
    for name, threshold in LEVEL_THRESHOLDS.items():
        if points >= threshold:
            level = name
    return level
