export var PALETTES = {
  aurora: {
    name: "Aurora", bg: "#0B1120", surface: "#131B2E", border: "#1E2A45",
    text: "#E8ECF4", muted: "#8B95A8", dim: "#5A6478",
    dot: "#1E2A4518", hullFill: "#ffffff04", hullStroke: "#ffffff0C",
    types: {
      theory:    { a: "#B8B0FF", s: "#9890E8", b: "#6C5CE750" },
      principle: { a: "#9AA4E0", s: "#7B88C8", b: "#5B6ABF50" },
      definition:{ a: "#5EECD5", s: "#40C8B0", b: "#00B8A950" },
      method:    { a: "#63B3F3", s: "#4898D8", b: "#0984E350" },
      example:   { a: "#F0A08A", s: "#D88870", b: "#E1705550" },
      evidence:  { a: "#F7C463", s: "#D8A848", b: "#F39C1250" },
      argument:  { a: "#E87070", s: "#D05858", b: "#D6303150" },
      term:      { a: "#5EE8E4", s: "#40C8C4", b: "#00CEC950" },
      framework: { a: "#C8C3FF", s: "#A8A0E8", b: "#A29BFE50" },
      phenomenon:{ a: "#FEA8C8", s: "#E090B0", b: "#FD79A850" },
    },
    edges: {
      logical:      { color: "#A29BFE", w: 3.5, dash: "" },
      compositional:{ color: "#74B9FF", w: 3,   dash: "10 5" },
      pedagogical:  { color: "#FD79A8", w: 2.5, dash: "5 4" },
      causal:       { color: "#FDCB6E", w: 3.5, dash: "" },
      custom:       { color: "#55EFC4", w: 2.5, dash: "8 4" },
    },
  },
};

var EC = {
  logical: ["IMPLIES","REQUIRES","CONTRADICTS","EQUIVALENT","GENERALIZES","SPECIALIZES"],
  compositional: ["PART_OF","CONTAINS","INSTANCE_OF","DEFINED_BY"],
  pedagogical: ["PREREQUISITE_FOR","ILLUSTRATES","EXTENDS","CONTRASTS_WITH"],
  causal: ["CAUSES","ENABLES","CONSTRAINS","ANALOGOUS_TO"],
};

export var ARROW_CATS = new Set(["logical", "causal"]);

export function edgeCat(t) {
  for (var c in EC) if (EC[c].indexOf(t) >= 0) return c;
  return "custom";
}

export function typeColor(P, t) { return P.types[t] || P.types.term; }

// NEW: Importance score → font size mapping
// importance = normalized(degree * 0.6 + confidence * 0.4)
// Returns font size between 11 and 22
export function importanceFontSize(degree, confidence, maxDegree) {
  var d = degree || 0;
  var c = confidence || 0.5;
  var md = maxDegree || 5;
  var raw = (d / Math.max(md, 1)) * 0.6 + c * 0.4; // 0..1
  return Math.round(11 + raw * 11); // 11..22
}

// Description font size (smaller, also scales)
export function descFontSize(degree, confidence, maxDegree) {
  var d = degree || 0;
  var c = confidence || 0.5;
  var md = maxDegree || 5;
  var raw = (d / Math.max(md, 1)) * 0.6 + c * 0.4;
  return Math.round(9 + raw * 4); // 9..13
}
