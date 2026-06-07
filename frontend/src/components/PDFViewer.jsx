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
  var annotations = props.annotations || [];
  var onAnn = props.onAnn;  // setter: receives a function(prevArray) or array
  var focusEdge = props.focusEdge;  // {sourceLabel,targetLabel,source_page} to explain a relation

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
  var _ptext = useState({}), pageText = _ptext[0], setPageText = _ptext[1];
  var _annOn = useState(false), annOn = _annOn[0], setAnnOn = _annOn[1];
  var _annTool = useState('mark'), annTool = _annTool[0], setAnnTool = _annTool[1];
  var _annColor = useState('#FDCB6E'), annColor = _annColor[0], setAnnColor = _annColor[1];
  var _editAnn = useState(null), editAnn = _editAnn[0], setEditAnn = _editAnn[1];
  var _noteText = useState(''), noteText = _noteText[0], setNoteText = _noteText[1];

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
          // Capture text layer (fractional coords) for highlighting + auto-linking
          page.getTextContent().then(function(tc) {
            var items = [];
            for (var ti = 0; ti < tc.items.length; ti++) {
              var it = tc.items[ti];
              if (!it.str || !it.str.trim()) continue;
              var tx = pdfjsLib.Util.transform(viewport.transform, it.transform);
              var fh = Math.hypot(tx[2], tx[3]) || 10;
              var x = tx[4], yTop = tx[5] - fh, w = (it.width || 0) * viewport.scale;
              items.push({ str: it.str, fx: x / viewport.width, fy: yTop / viewport.height, fw: w / viewport.width, fh: fh / viewport.height });
            }
            setPageText(function(prev) { var n = Object.assign({}, prev); n[pageNum] = { items: items }; return n; });
          }).catch(function() {});
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

  var pageTextRef = useRef({});
  useEffect(function() { pageTextRef.current = pageText; }, [pageText]);

  // When a concept is selected: scroll to its page, then to the matched paragraph, and highlight it
  useEffect(function() {
    if (!selectedId) { setHighlights([]); return; }
    var node = null;
    for (var i = 0; i < nodes.length; i++) { if (nodes[i].id === selectedId) { node = nodes[i]; break; } }
    if (node && node.source_page) {
      scrollToPage(node.source_page);
      if (node.source_quote) setHighlights([{ page: node.source_page, text: node.source_quote }]);
      var pg = node.source_page;
      setTimeout(function() {
        var cont = pdfContainerRef.current; if (!cont) return;
        var pageEl = cont.querySelector('[data-page="' + pg + '"]'); if (!pageEl) return;
        var boxes = hlBoxes(pg);
        if (boxes.length) { var top = pageEl.offsetTop + boxes[0].fy * pageEl.clientHeight - cont.clientHeight * 0.33; cont.scrollTo({ top: Math.max(0, top), behavior: 'smooth' }); }
      }, 650);
    }
  }, [selectedId, nodes, scrollToPage]);

  // When a relation is focused: scroll to where its endpoints appear
  useEffect(function() {
    if (!focusEdge) return;
    var pg = focusEdge.source_page || (function() { for (var i = 0; i < nodes.length; i++) { } return null; })();
    // pick the first page that has any matching token
    var targetPage = focusEdge.source_page || null;
    if (!targetPage) { var keys = Object.keys(pageTextRef.current); for (var k = 0; k < keys.length; k++) { if (relBoxes(parseInt(keys[k])).length) { targetPage = parseInt(keys[k]); break; } } }
    if (targetPage) {
      scrollToPage(targetPage);
      setTimeout(function() {
        var cont = pdfContainerRef.current; if (!cont) return;
        var pageEl = cont.querySelector('[data-page="' + targetPage + '"]'); if (!pageEl) return;
        var boxes = relBoxes(targetPage);
        if (boxes.length) { var top = pageEl.offsetTop + boxes[0].fy * pageEl.clientHeight - cont.clientHeight * 0.33; cont.scrollTo({ top: Math.max(0, top), behavior: 'smooth' }); }
      }, 650);
    }
  }, [focusEdge, scrollToPage]);

  // Re-run the scroll-to-paragraph once the page's text layer is available
  useEffect(function() {
    if (!selectedId) return;
    var node = null;
    for (var i = 0; i < nodes.length; i++) { if (nodes[i].id === selectedId) { node = nodes[i]; break; } }
    if (!node || !node.source_page) return;
    var pg = node.source_page;
    if (!pageText[pg]) return;
    var cont = pdfContainerRef.current; if (!cont) return;
    var pageEl = cont.querySelector('[data-page="' + pg + '"]'); if (!pageEl) return;
    var boxes = hlBoxes(pg); if (!boxes.length) return;
    var top = pageEl.offsetTop + boxes[0].fy * pageEl.clientHeight - cont.clientHeight * 0.33;
    cont.scrollTo({ top: Math.max(0, top), behavior: 'smooth' });
  }, [pageText, selectedId]);

  // Add / toggle a highlight on a clicked text item
  var toggleAnnotation = function(pageNum, box) {
    if (!onAnn) return;
    onAnn(function(prev) {
      var hit = -1;
      for (var i = 0; i < prev.length; i++) { if (prev[i].page === pageNum && Math.abs(prev[i].fx - box.fx) < 0.005 && Math.abs(prev[i].fy - box.fy) < 0.01) { hit = i; break; } }
      if (hit >= 0) return prev.filter(function(a, idx) { return idx !== hit; });
      return prev.concat([{ id: 'ann_' + Date.now() + '_' + Math.floor(Math.random() * 999), page: pageNum, kind: (annTool === 'underline' ? 'underline' : 'mark'), fx: box.fx, fy: box.fy, fw: box.fw, fh: box.fh, color: annColor, note: '', concept: selectedId || null }]);
    });
  };
  // Drop a free note pin on empty space (comment)
  var addPin = function(pageNum, fx, fy) {
    if (!onAnn) return;
    var id = 'note_' + Date.now() + '_' + Math.floor(Math.random() * 999);
    onAnn(function(prev) { return prev.concat([{ id: id, page: pageNum, kind: 'note', fx: fx, fy: fy, fw: 0.02, fh: 0.02, color: annColor, note: '' }]); });
    setTimeout(function() { setEditAnn({ id: id, note: '' }); setNoteText(''); }, 0);
  };
  // Live-update a note as the user types (auto-save)
  var liveNote = function(id, text) {
    setNoteText(text);
    if (onAnn) onAnn(function(prev) { return prev.map(function(a) { return a.id === id ? Object.assign({}, a, { note: text }) : a; }); });
  };

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

  // ── Explainable highlighting ──────────────────────────────
  var STOP = { the:1,a:1,an:1,of:1,to:1,in:1,on:1,and:1,or:1,is:1,are:1,was:1,were:1,be:1,by:1,for:1,with:1,as:1,at:1,it:1,its:1,this:1,that:1,these:1,those:1,from:1,which:1,we:1,can:1,will:1,not:1,but:1,if:1,then:1,so:1,such:1,into:1,than:1,also:1,may:1,each:1,any:1,all:1,one:1,two:1,their:1,they:1,has:1,have:1,had:1,where:1,when:1,how:1,what:1,more:1,most:1,some:1,other:1,using:1,used:1,use:1,between:1,within:1,about:1 };
  var sigTokens = function(s) { var out = []; (s || '').toLowerCase().split(/[^a-z0-9]+/).forEach(function(w) { if (w.length >= 4 && !STOP[w]) out.push(w); }); return out; };
  // Find the run of items that spans a quote phrase (so we highlight the sentence, not "the")
  var quoteSpan = function(pt, quote) {
    if (!quote) return [];
    var norm = quote.toLowerCase().replace(/\s+/g, ' ').trim();
    var probe = norm.slice(0, Math.min(norm.length, 50));
    var concat = '', map = [];
    for (var i = 0; i < pt.items.length; i++) { var s = pt.items[i].str.toLowerCase(); for (var c = 0; c < s.length; c++) { concat += s[c]; map.push(i); } concat += ' '; map.push(i); }
    var idx = concat.indexOf(probe);
    if (idx < 0) return [];
    var endChar = Math.min(idx + Math.max(probe.length, norm.length) - 1, map.length - 1);
    var a = map[idx], b = map[endChar], boxes = [];
    for (var k = a; k <= b && k < pt.items.length; k++) boxes.push(pt.items[k]);
    return boxes;
  };
  // Boxes for the selected concept: prefer its quoted sentence, else its significant label words
  var hlBoxes = function(pageNum) {
    if (!selectedId) return [];
    var node = null;
    for (var i = 0; i < nodes.length; i++) { if (nodes[i].id === selectedId) { node = nodes[i]; break; } }
    if (!node) return [];
    var pt = pageText[pageNum]; if (!pt) return [];
    if (node.source_quote) { var span = quoteSpan(pt, node.source_quote); if (span.length) return span; }
    var toks = sigTokens(node.label); if (!toks.length) return [];
    var out = [];
    pt.items.forEach(function(it) { var w = it.str.trim().toLowerCase().replace(/[^a-z0-9]/g, ''); if (w.length >= 4 && toks.indexOf(w) >= 0) out.push(it); });
    return out;
  };
  // Boxes for a focused relation: where its two endpoints' significant words appear
  var relBoxes = function(pageNum) {
    if (!focusEdge) return [];
    var pt = pageText[pageNum]; if (!pt) return [];
    var toks = sigTokens(focusEdge.sourceLabel).concat(sigTokens(focusEdge.targetLabel));
    if (!toks.length) return [];
    var out = [];
    pt.items.forEach(function(it) { var w = it.str.trim().toLowerCase().replace(/[^a-z0-9]/g, ''); if (w.length >= 4 && toks.indexOf(w) >= 0) out.push(it); });
    return out;
  };
  // Auto-link: only whole significant label words are clickable (not "the")
  var linkBoxes = function(pageNum) {
    var pt = pageText[pageNum]; if (!pt) return [];
    var pageNodes = nodes.filter(function(n) { return (n.source_page || 0) === pageNum; });
    if (!pageNodes.length) return [];
    var toksByNode = pageNodes.map(function(n) { return { id: n.id, toks: sigTokens(n.label) }; });
    var out = [];
    pt.items.forEach(function(it) {
      var w = it.str.trim().toLowerCase().replace(/[^a-z0-9]/g, ''); if (w.length < 4) return;
      for (var i = 0; i < toksByNode.length; i++) { if (toksByNode[i].toks.indexOf(w) >= 0) { out.push({ fx: it.fx, fy: it.fy, fw: it.fw, fh: it.fh, nodeId: toksByNode[i].id }); break; } }
    });
    return out;
  };

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
        h('div', { style: { display: 'flex', gap: 4, alignItems: 'center' } },
          onAnn ? h('button', { title: 'Annotation tools', onClick: function() { setAnnOn(!annOn); }, style: { padding: '4px 10px', background: annOn ? 'rgba(253,203,110,0.18)' : 'transparent', border: '1px solid ' + (annOn ? '#FDCB6E' : BRD), borderRadius: 6, color: annOn ? '#FDCB6E' : DIM, fontSize: 12, cursor: 'pointer', fontWeight: 600 } }, annOn ? 'Annotating' : 'Annotate') : null,
          (onAnn && annOn) ? h('div', { style: { display: 'flex', border: '1px solid ' + BRD, borderRadius: 6, overflow: 'hidden' } }, [['mark', 'Highlight'], ['underline', 'Underline']].map(function(tt) { return h('button', { key: tt[0], onClick: function() { setAnnTool(tt[0]); }, style: { padding: '4px 8px', border: 'none', background: annTool === tt[0] ? 'rgba(253,203,110,0.22)' : 'transparent', color: annTool === tt[0] ? '#FDCB6E' : DIM, fontSize: 11, cursor: 'pointer' } }, tt[1]); })) : null,
          (onAnn && annOn) ? ['#FDCB6E', '#FF8FA3', '#7DE2D1', '#A29BFE'].map(function(c) { return h('div', { key: c, onClick: function() { setAnnColor(c); }, style: { width: 16, height: 16, borderRadius: '50%', background: c, cursor: 'pointer', outline: annColor === c ? '2px solid ' + TXT : 'none', outlineOffset: 1 } }); }) : null,
          (onAnn && annOn) ? h('span', { style: { fontSize: 10, color: DIM } }, 'click text to mark · click blank for a note') : null,
          (onAnn && annOn) ? ['#FDCB6E', '#FF8FA3', '#7DE2D1', '#A29BFE'].map(function(c) { return h('div', { key: c, onClick: function() { setAnnColor(c); }, style: { width: 16, height: 16, borderRadius: '50%', background: c, cursor: 'pointer', outline: annColor === c ? '2px solid ' + TXT : 'none', outlineOffset: 1 } }); }) : null,
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
                  h('img', { src: page.dataUrl, style: { width: '100%', maxWidth: page.width, borderRadius: 4, boxShadow: '0 2px 12px rgba(0,0,0,0.15)', display: 'block' } }),
                  // Text-layer overlay: concept/relation highlights + clickable terms + user annotations
                  h('div', { onClick: function(e) { if (annOn && e.target === e.currentTarget) { var r = e.currentTarget.getBoundingClientRect(); addPin(page.pageNum, (e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height); } }, style: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0, zIndex: 2, pointerEvents: annOn ? 'auto' : 'none', cursor: annOn ? 'crosshair' : 'default' } },
                    // concept highlight (selected concept's sentence/words)
                    hlBoxes(page.pageNum).map(function(b, i) { return h('div', { key: 'h' + i, style: { position: 'absolute', left: (b.fx * 100) + '%', top: (b.fy * 100) + '%', width: (b.fw * 100) + '%', height: (b.fh * 100) + '%', background: 'rgba(162,155,254,0.30)', borderBottom: '2px solid #A29BFE', borderRadius: 2, pointerEvents: 'none' } }); }),
                    // relation highlight (focused link's endpoints)
                    relBoxes(page.pageNum).map(function(b, i) { return h('div', { key: 'r' + i, style: { position: 'absolute', left: (b.fx * 100) + '%', top: (b.fy * 100) + '%', width: (b.fw * 100) + '%', height: (b.fh * 100) + '%', background: 'rgba(0,184,169,0.26)', borderBottom: '2px solid #00B8A9', borderRadius: 2, pointerEvents: 'none' } }); }),
                    // user annotations: marks (bands) + note pins
                    annotations.filter(function(a) { return a.page === page.pageNum; }).map(function(a) {
                      if (a.kind === 'note') return h('div', { key: a.id, title: a.note || 'Note', onClick: function(e) { e.stopPropagation(); setEditAnn(a); setNoteText(a.note || ''); }, style: { position: 'absolute', left: (a.fx * 100) + '%', top: (a.fy * 100) + '%', width: 18, height: 18, marginLeft: -9, marginTop: -9, borderRadius: '50% 50% 50% 2px', background: a.color, cursor: 'pointer', pointerEvents: 'auto', boxShadow: '0 1px 4px rgba(0,0,0,0.3)' } });
                      var underline = a.kind === 'underline';
                      return h('div', { key: a.id, title: a.note ? a.note : (a.concept ? 'Linked concept — click to open' : 'Click to add a note'), onClick: function(e) { e.stopPropagation(); if (!annOn && a.concept && onSelectConcept) { onSelectConcept(a.concept); return; } setEditAnn(a); setNoteText(a.note || ''); }, style: { position: 'absolute', left: (a.fx * 100) + '%', top: (a.fy * 100) + '%', width: (a.fw * 100) + '%', height: (a.fh * 100) + '%', background: underline ? 'transparent' : (a.color + '66'), borderBottom: '2px solid ' + a.color, borderRadius: 2, cursor: 'pointer', pointerEvents: 'auto' } }, a.note ? h('div', { style: { position: 'absolute', top: -5, right: -5, width: 8, height: 8, borderRadius: '50%', background: a.color, border: '1px solid ' + SURF } }) : null);
                    }),
                    // annotate mode: click a word to highlight it
                    annOn ? (pageText[page.pageNum] ? pageText[page.pageNum].items : []).map(function(it, i) { return h('div', { key: 'w' + i, onClick: function(e) { e.stopPropagation(); toggleAnnotation(page.pageNum, it); }, style: { position: 'absolute', left: (it.fx * 100) + '%', top: (it.fy * 100) + '%', width: (it.fw * 100) + '%', height: (it.fh * 100) + '%', cursor: 'pointer', pointerEvents: 'auto' } }); }) : null,
                    // auto-link: significant concept labels found in the page are clickable
                    !annOn ? linkBoxes(page.pageNum).map(function(b, i) { return h('div', { key: 'a' + i, title: 'Open this concept', onClick: function(e) { e.stopPropagation(); if (onSelectConcept) onSelectConcept(b.nodeId); }, style: { position: 'absolute', left: (b.fx * 100) + '%', top: (b.fy * 100) + '%', width: (b.fw * 100) + '%', height: (b.fh * 100) + '%', borderBottom: '2px dashed rgba(0,184,169,0.6)', cursor: 'pointer', pointerEvents: 'auto' } }); }) : null),
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

    // Note editor for a clicked highlight
    editAnn ? h('div', { style: { position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 60 }, onClick: function() { setEditAnn(null); } },
      h('div', { onClick: function(e) { e.stopPropagation(); }, style: { width: 300, background: SURF, border: '1px solid ' + BRD, borderRadius: 14, padding: 16 } },
        h('div', { style: { fontSize: 13, fontWeight: 600, marginBottom: 8, color: TXT } }, 'Note (saves automatically)'),
        h('textarea', { value: noteText, autoFocus: true, placeholder: 'Type your comment…', rows: 4, onChange: function(e) { liveNote(editAnn.id, e.target.value); }, style: { width: '100%', padding: 8, background: BG, border: '1px solid ' + BRD, borderRadius: 8, color: TXT, fontSize: 13, fontFamily: 'inherit', resize: 'vertical', marginBottom: 8 } }),
        h('div', { style: { display: 'flex', gap: 6 } },
          h('button', { onClick: function() { setEditAnn(null); }, style: { flex: 2, padding: '8px 0', background: 'rgba(162,155,254,0.15)', border: '1px solid rgba(162,155,254,0.4)', borderRadius: 8, color: '#A29BFE', fontSize: 13, cursor: 'pointer', fontFamily: 'inherit' } }, 'Done'),
          h('button', { onClick: function() { var id = editAnn.id; if (onAnn) onAnn(function(prev) { return prev.filter(function(a) { return a.id !== id; }); }); setEditAnn(null); }, style: { flex: 1, padding: '8px 0', background: 'transparent', border: '1px solid ' + BRD, borderRadius: 8, color: '#FF6B6B', fontSize: 13, cursor: 'pointer', fontFamily: 'inherit' } }, 'Delete'))
      )
    ) : null,

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

