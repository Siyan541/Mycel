from __future__ import annotations
from enum import Enum
from typing import Optional
from pydantic import BaseModel, Field

class RelationType(str, Enum):
    IMPLIES="IMPLIES"; REQUIRES="REQUIRES"; CONTRADICTS="CONTRADICTS"
    EQUIVALENT="EQUIVALENT"; GENERALIZES="GENERALIZES"; SPECIALIZES="SPECIALIZES"
    CAUSES="CAUSES"; ENABLES="ENABLES"; CONSTRAINS="CONSTRAINS"
    ANALOGOUS_TO="ANALOGOUS_TO"; PART_OF="PART_OF"; CONTAINS="CONTAINS"
    INSTANCE_OF="INSTANCE_OF"; DEFINED_BY="DEFINED_BY"
    PREREQUISITE_FOR="PREREQUISITE_FOR"; ILLUSTRATES="ILLUSTRATES"
    EXTENDS="EXTENDS"; CONTRASTS_WITH="CONTRASTS_WITH"

class ConceptType(str, Enum):
    THEORY="theory"; PRINCIPLE="principle"; DEFINITION="definition"
    METHOD="method"; EXAMPLE="example"; EVIDENCE="evidence"
    ARGUMENT="argument"; TERM="term"; FRAMEWORK="framework"; PHENOMENON="phenomenon"

class Section(BaseModel):
    id: str; title: str; level: int; page_start: int; page_end: int
    text: str; parent_id: Optional[str] = None; children_ids: list[str] = Field(default_factory=list)

class Skeleton(BaseModel):
    filename: str; total_pages: int; sections: list[Section]

class Concept(BaseModel):
    label: str = Field(description="2-6 word name")
    description: str = Field(description="One sentence explanation")
    concept_type: ConceptType
    abstraction_level: int = Field(ge=0, le=3)
    confidence: int = Field(ge=1, le=10)
    source_quote: str = Field(description="Brief phrase from source")

class ConceptResult(BaseModel):
    concepts: list[Concept]

class Relation(BaseModel):
    source_label: str; target_label: str; relation_type: RelationType
    justification: str; confidence: int = Field(ge=1, le=10)

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
