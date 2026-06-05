import React, { useState, useEffect, useRef, useCallback, useMemo } from 'react';

// PDF.js will be loaded from CDN in index.html:
// <script src="https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js"></script>
// <script>pdfjsLib.GlobalWorkerOptions.workerSrc='https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';</script>

var h = React.createElement;

export default function PDFViewer(props) {
  var pdfUrl = props.pdfUrl;       // URL or blob URL of the uploaded PDF
  var pdfFile = props.pdfFile;     // File object (alternative to URL)
  var nodes = props.nodes || [];
  var edges = props.edges || [];
  var onSelectConcept = props.onSelectConcept;
  var selectedId = props.selectedId;
  var palette = props.palette;
  var onClose = props.onClose;
  var darkMode = props.darkMode;
  // panel: 'pdf' (PDF only), 'list' (concept list only), 'both' (side by side).
  // Back-compat: splitMode:true means PDF only.
  var panel = props.panel || (props.splitMode ? 'pdf' : 'both');

  var BG = darkMode ? '#0B1120' : '#F8F6F1';
  var SURF = darkMode ? '#131B2E' : '#FFFFFF';
  var BRD = darkMode ? '#1E2A45' : '#E0D8CC';
  var TXT = darkMode ? '#E8ECF4' : '#1A1510';
  var DIM = darkMode ? '#5A6478' : '#6B5E4D';

  var _pdf = useState(null), pdfDoc = _pdf[0], setPdfDoc = _pdf[1];
  var _pages = useState([]), pages = _pages[0], setPages = _pages[1];
  var _currentPage = useState(1), currentPage = _currentPage[0], setCurrentPage = _currentPage[1];
  var _scale = useState(1.2), scale = _scale[0], setScale = _scale[1];
  var _loading = useState(true), loading = _loading[0], setLoading = _loading[1];
  var _highlights = useState([]), highlights = _highlights[0], setHighlights = _highlights[1];
  var _hoveredNode = useState(null), hoveredNode = _hoveredNode[0], setHoveredNode = _hoveredNode[1];

  var pdfContainerRef = useRef(null);
  var canvasRefs = useRef({});

  // Load PDF
  useEffect(function() {
    if (panel === 'list') { setLoading(false); return; }
    if (typeof pdfjsLib === 'undefined') {
      console.error('pdf.js not loaded. Add the script tags to index.html');
      setLoading(false);
      return;
    }

    var loadPdf = function(source) {
      var loadingTask = pdfjsLib.getDocument(source);
      loadingTask.promise.then(function(pdf) {
        setPdfDoc(pdf);
        setLoading(false);
        // Render first few pages
        renderPages(pdf, 1, Math.min(pdf.numPages, 5));
      }).catch(function(err) {
        console.error('PDF load error:', err);
        setLoading(false);
      });
    };

    if (pdfFile) {
      var reader = new FileReader();
      reader.onload = function(e) {
        loadPdf({ data: new Uint8Array(e.target.result) });
      };
      reader.readAsArrayBuffer(pdfFile);
    } else if (pdfUrl) {
      loadPdf(pdfUrl);
    }
  }, [pdfUrl, pdfFile]);

  // Render pages to canvas
  var renderPages = function(pdf, startPage, endPage) {
    var newPages = [];
    var renderNext = function(pageNum) {
      if (pageNum > endPage || pageNum > pdf.numPages) {
        setPages(function(prev) { return prev.concat(newPages); });
        return;
      }
      pdf.getPage(pageNum).then(function(page) {
        var viewport = page.getViewport({ scale: scale });
        var canvas = document.createElement('canvas');
        canvas.width = viewport.width;
        canvas.height = viewport.height;
        var ctx = canvas.getContext('2d');
        page.render({ canvasContext: ctx, viewport: viewport }).promise.then(function() {
          newPages.push({
            pageNum: pageNum,
            dataUrl: canvas.toDataURL(),
            width: viewport.width,
            height: viewport.height,
          });
          renderNext(pageNum + 1);
        });
      });
    };
    renderNext(startPage);
  };

  // Load more pages on scroll
  var onScroll = useCallback(function() {
    if (!pdfContainerRef.current || !pdfDoc) return;
    var el = pdfContainerRef.current;
    var scrollBottom = el.scrollTop + el.clientHeight;
    var scrollHeight = el.scrollHeight;
    // Load more pages when near bottom
    if (scrollBottom > scrollHeight - 500 && pages.length < pdfDoc.numPages) {
      var nextStart = pages.length + 1;
      var nextEnd = Math.min(pages.length + 3, pdfDoc.numPages);
      renderPages(pdfDoc, nextStart, nextEnd);
    }
    // Track current page
    var pageEls = el.querySelectorAll('[data-page]');
    for (var i = 0; i < pageEls.length; i++) {
      var rect = pageEls[i].getBoundingClientRect();
      var containerRect = el.getBoundingClientRect();
      if (rect.top < containerRect.top + containerRect.height / 2 && rect.bottom > containerRect.top) {
        setCurrentPage(parseInt(pageEls[i].getAttribute('data-page')));
      }
    }
  }, [pdfDoc, pages.length, scale]);

  // Scroll to a specific page
  var scrollToPage = useCallback(function(pageNum) {
    if (!pdfContainerRef.current) return;
    var el = pdfContainerRef.current.querySelector('[data-page="' + pageNum + '"]');
    if (el) {
      el.scrollIntoView({ behavior: 'smooth', block: 'start' });
      setCurrentPage(pageNum);
    } else if (pdfDoc && pageNum <= pdfDoc.numPages) {
      // Page not rendered yet — render it first
      renderPages(pdfDoc, pages.length + 1, pageNum);
      setTimeout(function() {
        var el2 = pdfContainerRef.current.querySelector('[data-page="' + pageNum + '"]');
        if (el2) el2.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }, 1000);
    }
  }, [pdfDoc, pages.length]);

  // When a concept is selected, scroll to its source page
  useEffect(function() {
    if (!selectedId) { setHighlights([]); return; }
    var node = null;
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].id === selectedId) { node = nodes[i]; break; }
    }
    if (node && node.source_page) {
      scrollToPage(node.source_page);
      if (node.source_quote) {
        setHighlights([{ page: node.source_page, text: node.source_quote }]);
      }
    }
  }, [selectedId, nodes, scrollToPage]);

  // Build concept list grouped by page
  var conceptsByPage = useMemo(function() {
    var byPage = {};
    nodes.forEach(function(n) {
      var pg = n.source_page || 0;
      if (!byPage[pg]) byPage[pg] = [];
      byPage[pg].push(n);
    });
    return byPage;
  }, [nodes]);

  // RENDER
  return h('div', { style: { display: 'flex', height: '100%', background: BG } },

    // LEFT PANEL: PDF pages
    panel !== 'list' ?
    h('div', { style: { flex: panel === 'both' ? '0 0 50%' : 1, minWidth: 0, display: 'flex', flexDirection: 'column', borderRight: panel === 'both' ? '1px solid ' + BRD : 'none' } },
      // PDF toolbar
      h('div', { style: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '8px 14px', background: SURF, borderBottom: '1px solid ' + BRD } },
        h('div', { style: { display: 'flex', alignItems: 'center', gap: 8 } },
          h('button', { onClick: onClose, style: { padding: '6px 12px', background: 'transparent', border: '1px solid ' + BRD, borderRadius: 6, color: DIM, fontSize: 13, cursor: 'pointer' } }, '← Back'),
          h('span', { style: { fontSize: 13, color: DIM } },
            pdfDoc ? ('Page ' + currentPage + ' / ' + pdfDoc.numPages) : 'Loading...')
        ),
        h('div', { style: { display: 'flex', gap: 4 } },
          h('button', { onClick: function() { setScale(function(s) { return Math.max(0.5, s - 0.2); }); }, style: { padding: '4px 10px', background: 'transparent', border: '1px solid ' + BRD, borderRadius: 6, color: TXT, fontSize: 16, cursor: 'pointer' } }, '−'),
          h('span', { style: { fontSize: 12, color: DIM, padding: '4px 8px' } }, Math.round(scale * 100) + '%'),
          h('button', { onClick: function() { setScale(function(s) { return Math.min(3, s + 0.2); }); }, style: { padding: '4px 10px', background: 'transparent', border: '1px solid ' + BRD, borderRadius: 6, color: TXT, fontSize: 16, cursor: 'pointer' } }, '+')
        )
      ),
      // PDF pages container
      h('div', { ref: pdfContainerRef, onScroll: onScroll, style: { flex: 1, overflowY: 'auto', padding: 16, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12 } },
        loading
          ? h('div', { style: { padding: 40, textAlign: 'center', color: DIM } },
              h('div', { style: { fontSize: 16, marginBottom: 8 } }, 'Loading PDF...'),
              h('div', { style: { fontSize: 13 } }, 'Rendering pages...'))
          : pages.length === 0
            ? h('div', { style: { padding: 40, textAlign: 'center', color: DIM } },
                typeof pdfjsLib === 'undefined'
                  ? h('div', null,
                      h('div', { style: { fontSize: 15, marginBottom: 8 } }, 'PDF viewer requires pdf.js'),
                      h('div', { style: { fontSize: 12, lineHeight: 1.6 } },
                        'Add these script tags to frontend/index.html before the closing </head> tag:'),
                      h('pre', { style: { fontSize: 10, background: BG, padding: 12, borderRadius: 8, textAlign: 'left', marginTop: 8, overflowX: 'auto', color: TXT } },
                        '<script src="https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js"></script>\n<script>pdfjsLib.GlobalWorkerOptions.workerSrc="https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js";</script>'))
                  : 'No pages to display')
            : pages.map(function(page) {
                var isHighlighted = highlights.some(function(hl) { return hl.page === page.pageNum; });
                return h('div', { key: page.pageNum, 'data-page': page.pageNum, style: { position: 'relative', marginBottom: 8 } },
                  // Page number badge
                  h('div', { style: { position: 'absolute', top: 4, left: 4, background: SURF + 'DD', padding: '2px 8px', borderRadius: 4, fontSize: 11, color: DIM, zIndex: 2 } }, 'p.' + page.pageNum),
                  // Highlight border when concept selected
                  isHighlighted ? h('div', { style: { position: 'absolute', inset: -3, border: '3px solid #A29BFE', borderRadius: 8, zIndex: 1, pointerEvents: 'none' } }) : null,
                  // Page image
                  h('img', { src: page.dataUrl, style: { width: '100%', maxWidth: page.width, borderRadius: 4, boxShadow: '0 2px 12px rgba(0,0,0,0.15)' } }),
                  // Concept markers for this page
                  conceptsByPage[page.pageNum]
                    ? h('div', { style: { position: 'absolute', top: 4, right: 4, display: 'flex', flexDirection: 'column', gap: 2, zIndex: 2 } },
                        conceptsByPage[page.pageNum].map(function(n) {
                          var isActive = selectedId === n.id;
                          return h('div', {
                            key: n.id,
                            onClick: function() { if (onSelectConcept) onSelectConcept(n.id); },
                            style: {
                              padding: '3px 8px', borderRadius: 6, fontSize: 10, cursor: 'pointer',
                              background: isActive ? 'rgba(162,155,254,0.3)' : SURF + 'CC',
                              border: '1px solid ' + (isActive ? '#A29BFE' : BRD),
                              color: isActive ? '#A29BFE' : DIM,
                              maxWidth: 120, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap'
                            }
                          }, n.label);
                        })
                      )
                    : null
                );
              })
      )
    ) : null,

    // RIGHT PANEL: Concept list (organized by page)
    (panel === 'list' || panel === 'both') ?
    h('div', { style: { flex: panel === 'both' ? '0 0 50%' : 1, minWidth: 0, display: 'flex', flexDirection: 'column' } },
      // Panel header
      h('div', { style: { padding: '8px 14px', borderBottom: '1px solid ' + BRD, fontSize: 14, fontWeight: 600, color: TXT } }, 'Concepts'),
      // Concept list
      h('div', { style: { flex: 1, overflowY: 'auto', padding: 14 } },
        Object.keys(conceptsByPage).sort(function(a, b) { return parseInt(a) - parseInt(b); }).map(function(pageNum) {
          var pageNodes = conceptsByPage[pageNum];
          return h('div', { key: 'pg' + pageNum, style: { marginBottom: 16 } },
            parseInt(pageNum) > 0
              ? h('div', {
                  onClick: function() { scrollToPage(parseInt(pageNum)); },
                  style: { fontSize: 12, color: DIM, fontWeight: 600, marginBottom: 6, cursor: 'pointer', padding: '4px 8px', background: SURF, borderRadius: 6, border: '1px solid ' + BRD }
                }, '📄 Page ' + pageNum)
              : h('div', { style: { fontSize: 12, color: DIM, fontWeight: 600, marginBottom: 6 } }, 'Unlocated concepts'),
            pageNodes.map(function(n) {
              var isActive = selectedId === n.id;
              // Find connections for this node
              var nodeEdges = edges.filter(function(e) { return e.source === n.id || e.target === n.id; });
              var typeColor = palette && palette.types && palette.types[n.concept_type]
                ? palette.types[n.concept_type].a : '#A29BFE';

              return h('div', {
                key: n.id,
                onClick: function() {
                  if (onSelectConcept) onSelectConcept(n.id);
                  if (n.source_page) scrollToPage(n.source_page);
                },
                style: {
                  padding: '10px 12px', marginBottom: 6, borderRadius: 10, cursor: 'pointer',
                  background: isActive ? (darkMode ? 'rgba(162,155,254,0.1)' : 'rgba(162,155,254,0.08)') : 'transparent',
                  border: '1px solid ' + (isActive ? '#A29BFE40' : 'transparent'),
                  transition: 'all 0.15s'
                }
              },
                // Type dot + label
                h('div', { style: { display: 'flex', alignItems: 'center', gap: 6, marginBottom: 4 } },
                  h('div', { style: { width: 8, height: 8, borderRadius: '50%', background: typeColor, flexShrink: 0 } }),
                  h('div', { style: { fontSize: 14, fontWeight: 600, color: typeColor } }, n.label),
                  h('span', { style: { fontSize: 10, color: DIM, marginLeft: 'auto', textTransform: 'uppercase' } }, n.concept_type)
                ),
                // Description
                n.description
                  ? h('div', { style: { fontSize: 13, color: darkMode ? '#B0B8C8' : '#4A4035', lineHeight: 1.5, marginBottom: 4, paddingLeft: 14 } }, n.description)
                  : null,
                // Source quote
                n.source_quote
                  ? h('div', { style: { fontSize: 11, color: DIM, fontStyle: 'italic', paddingLeft: 14, marginBottom: 4 } }, '"' + n.source_quote + '"')
                  : null,
                // Connections
                nodeEdges.length > 0
                  ? h('div', { style: { paddingLeft: 14, marginTop: 4 } },
                      nodeEdges.slice(0, 3).map(function(e, i) {
                        var isSrc = e.source === n.id;
                        var otherId = isSrc ? e.target : e.source;
                        var other = null;
                        for (var j = 0; j < nodes.length; j++) { if (nodes[j].id === otherId) { other = nodes[j]; break; } }
                        return h('div', { key: i, style: { fontSize: 11, color: DIM, lineHeight: 1.4 } },
                          h('span', { style: { color: '#A29BFE', fontSize: 9, textTransform: 'uppercase' } },
                            (e.relation_type || '').replace(/_/g, ' ')),
                          ' ' + (isSrc ? '→' : '←') + ' ',
                          h('span', { style: { color: TXT } }, other ? other.label : '?')
                        );
                      }),
                      nodeEdges.length > 3
                        ? h('div', { style: { fontSize: 10, color: DIM } }, '+' + (nodeEdges.length - 3) + ' more')
                        : null
                    )
                  : null
              );
            })
          );
        })
      )
    ): null
  );
}

