import React, { useRef, useEffect, useMemo } from 'react';
import { typeColor } from '../utils/theme';

// Dynamic import — only loads when 3D view is activated
var ForceGraph3D = null;
try { ForceGraph3D = require('react-force-graph-3d').default; } catch(e) {}

export default function Graph3D(props) {
  var nodes = props.nodes || [];
  var edges = props.edges || [];
  var palette = props.palette;
  var onNodeClick = props.onNodeClick;
  var fgRef = useRef();

  var graphData = useMemo(function() {
    return {
      nodes: nodes.map(function(n) {
        var tc = typeColor(palette, n.concept_type);
        return {
          id: n.id,
          name: n.label,
          desc: n.description,
          type: n.concept_type,
          val: (n.confidence || 0.5) * 10 + (n._degree || 1) * 3,
          color: tc.a,
        };
      }),
      links: edges.map(function(e) {
        return {
          source: e.source,
          target: e.target,
          type: e.relation_type,
        };
      }),
    };
  }, [nodes, edges, palette]);

  if (!ForceGraph3D) {
    return React.createElement('div', {
      style: { flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', color: palette.dim }
    }, 'Install react-force-graph-3d: npm install react-force-graph-3d');
  }

  return React.createElement(ForceGraph3D, {
    ref: fgRef,
    graphData: graphData,
    backgroundColor: palette.bg,
    nodeLabel: function(n) { return n.name + ': ' + (n.desc || ''); },
    nodeColor: function(n) { return n.color; },
    nodeVal: function(n) { return n.val; },
    nodeOpacity: 0.9,
    linkColor: function() { return '#ffffff30'; },
    linkWidth: 1.5,
    linkOpacity: 0.4,
    linkDirectionalArrowLength: 4,
    linkDirectionalArrowRelPos: 1,
    onNodeClick: function(node) { if (onNodeClick) onNodeClick(node.id); },
    width: props.width,
    height: props.height,
  });
}
