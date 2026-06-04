import React,{useState,useMemo,useCallback,useRef,useEffect,useReducer} from"react";
import{uploadPDF,getMaps,getMap,deleteMap,submitCorrection,confirmMap,unconfirmMap,shareMap,getCommunityMaps,upvoteCommunityMap,register,login,getMe,getActivity,getLeaderboard,exportMap,postComment,getComments,postFeedback,updateProfile}from"./api";
import PDFViewer from'./components/PDFViewer.jsx';
import{PALETTES,edgeCat,typeColor,ARROW_CATS}from"./utils/theme";
import{organicLayout,edgePath,sPath,wrap,nSize,convexHull,hullPath,getNeighbors}from"./utils/layout";

/* ── History reducer ── */
function histR(s,a){
  switch(a.type){
    case'SET':var p=s.past.concat([s.present]);if(p.length>40)p=p.slice(-40);return{past:p,present:a.data,future:[]};
    case'UNDO':if(!s.past.length)return s;return{past:s.past.slice(0,-1),present:s.past[s.past.length-1],future:[s.present].concat(s.future).slice(0,40)};
    case'REDO':if(!s.future.length)return s;return{past:s.past.concat([s.present]),present:s.future[0],future:s.future.slice(1)};
    case'INIT':return{past:[],present:a.data,future:[]};
    default:return s;
  }
}

/* ── Helpers ── */
var h=React.createElement;
function B(c,bg){return{padding:"8px 16px",background:bg||"rgba(162,155,254,0.12)",border:"1px solid "+(c?c+"40":"rgba(162,155,254,0.3)"),borderRadius:8,color:c||"#A29BFE",fontSize:13,fontWeight:500,cursor:"pointer",fontFamily:"inherit"};}
function fmtDate(d){if(!d)return'';try{var dt=new Date(d+'Z');return dt.toLocaleDateString()+' '+dt.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});}catch(e){return d||'';}}
function apiUrl(){return(typeof import.meta!=="undefined"&&import.meta.env&&import.meta.env.VITE_API_URL)||"http://localhost:8000";}

/* ── Concept shapes ── */
function shapeForType(t){
  if(t==='theory'||t==='principle')return'ellipse';
  if(t==='definition'||t==='term')return'rect';
  if(t==='argument'||t==='evidence')return'diamond';
  if(t==='framework')return'hexagon';
  if(t==='method')return'pill';
  if(t==='example')return'rounded';
  if(t==='phenomenon')return'cloud';
  return'rect';
}
function poly(pts){var s='';for(var i=0;i<pts.length;i++){s+=(i?' ':'')+pts[i][0]+','+pts[i][1];}return s;}
/* Returns the box multipliers needed so rectangular text fits inside a shape */
function shapeBox(shape,w,hh){
  if(shape==='diamond')return{w:w*1.5+30,h:hh*1.5+22};
  if(shape==='hexagon')return{w:w*1.35+30,h:hh*1.15+20};
  if(shape==='ellipse'||shape==='cloud')return{w:w*1.22+26,h:hh*1.3+20};
  return{w:w+28,h:hh+20};
}
function shapeEl(shape,w,hh,attrs){
  var p=Object.assign({strokeLinejoin:'round'},attrs||{});
  if(shape==='ellipse'||shape==='cloud')return h('ellipse',Object.assign({cx:0,cy:0,rx:w/2,ry:hh/2},p));
  if(shape==='pill')return h('rect',Object.assign({x:-w/2,y:-hh/2,width:w,height:hh,rx:hh/2},p));
  if(shape==='rounded')return h('rect',Object.assign({x:-w/2,y:-hh/2,width:w,height:hh,rx:18},p));
  if(shape==='diamond')return h('polygon',Object.assign({points:poly([[0,-hh/2],[w/2,0],[0,hh/2],[-w/2,0]])},p));
  if(shape==='hexagon'){var ins=w*0.22;return h('polygon',Object.assign({points:poly([[-w/2+ins,-hh/2],[w/2-ins,-hh/2],[w/2,0],[w/2-ins,hh/2],[-w/2+ins,hh/2],[-w/2,0]])},p));}
  return h('rect',Object.assign({x:-w/2,y:-hh/2,width:w,height:hh,rx:8},p));
}
var REL_TYPES=["IMPLIES","REQUIRES","CONTRADICTS","EQUIVALENT","GENERALIZES","SPECIALIZES","PART_OF","CONTAINS","INSTANCE_OF","DEFINED_BY","PREREQUISITE_FOR","ILLUSTRATES","EXTENDS","CONTRASTS_WITH","CAUSES","ENABLES","CONSTRAINS","ANALOGOUS_TO"];

/* ════════════════════════════════════════════════════════════════ */
export default function App(){
  /* ── Core data ── */
  var hr=useReducer(histR,{past:[],present:{nodes:[],edges:[],drawings:[]},future:[]});
  var hist=hr[0],dispatch=hr[1];
  var D=hist.present,nodes=D.nodes,edges=D.edges,drawings=D.drawings||[];
  var setData=useCallback(function(fn){dispatch({type:'SET',data:typeof fn==='function'?fn(hist.present):fn});},[hist.present]);
  var undo=useCallback(function(){dispatch({type:'UNDO'});},[]);
  var redo=useCallback(function(){dispatch({type:'REDO'});},[]);

  /* ── UI state ── */
  var _v=useState("home"),view=_v[0],setView=_v[1];
  var _sel=useState(null),selId=_sel[0],setSel=_sel[1];
  var _hov=useState(null),hovId=_hov[0],setHov=_hov[1];
  var _mid=useState(null),mapId=_mid[0],setMapId=_mid[1];
  var _maps=useState([]),maps=_maps[0],setMaps=_maps[1];
  var _upl=useState(false),uploading=_upl[0],setUpl=_upl[1];
  var _prog=useState(null),prog=_prog[0],setProg=_prog[1];
  var _coll=useState(new Set()),collapsed=_coll[0],setColl=_coll[1];
  var _ef=useState(null),editField=_ef[0],setEf=_ef[1];
  var _ev=useState(''),editVal=_ev[0],setEv=_ev[1];
  var _cam=useState({x:0,y:0,z:0.75}),cam=_cam[0],setCam=_cam[1];
  var _drag=useState(null),dragState=_drag[0],setDrag=_drag[1];
  var _tool=useState('select'),tool=_tool[0],setTool=_tool[1];
  var _dp=useState(null),drawPath=_dp[0],setDrawPath=_dp[1];
  var _dc=useState('#A29BFE'),drawColor=_dc[0],setDrawColor=_dc[1];
  var _user=useState(null),user=_user[0],setUser=_user[1];
  var _cmaps=useState([]),cmaps=_cmaps[0],setCmaps=_cmaps[1];
  var _shareM=useState(null),shareModal=_shareM[0],setShareM=_shareM[1];
  var _shareDom=useState("general"),shareDom=_shareDom[0],setShareDom=_shareDom[1];
  var _commDom=useState("all"),commDom=_commDom[0],setCommDom=_commDom[1];
  var _authMode=useState("login"),authMode=_authMode[0],setAuthMode=_authMode[1];
  var _authU=useState(""),authU=_authU[0],setAuthU=_authU[1];
  var _authP=useState(""),authP=_authP[0],setAuthP=_authP[1];
  var _onboard=useState(!localStorage.getItem("mycel_onboarded")),showOnboard=_onboard[0],setOnboard=_onboard[1];
  var _fbCat=useState("general"),fbCat=_fbCat[0],setFbCat=_fbCat[1];
  var _fbText=useState(""),fbText=_fbText[0],setFbText=_fbText[1];
  var _fbSent=useState(false),fbSent=_fbSent[0],setFbSent=_fbSent[1];
  var _leaders=useState([]),leaders=_leaders[0],setLeaders=_leaders[1];
  var _palName=useState(localStorage.getItem("mycel_palette")||"aurora"),palName=_palName[0],setPalName=_palName[1];
  var _refer=useState(false),referMode=_refer[0],setRefer=_refer[1];
  var _upFile=useState(null),uploadedFile=_upFile[0],setUpFile=_upFile[1];
  var _showSettings=useState(false),showSettings=_showSettings[0],setShowSettings=_showSettings[1];
  /* ── Render-style settings (persisted) ── */
  var _shapesOn=useState(localStorage.getItem("mycel_shapes")!=="0"),shapesOn=_shapesOn[0],setShapesOn=_shapesOn[1];
  var _lineMode=useState(localStorage.getItem("mycel_linemode")||"category"),lineMode=_lineMode[0],setLineMode=_lineMode[1];
  var _arrowsOn=useState(localStorage.getItem("mycel_arrows")!=="0"),arrowsOn=_arrowsOn[0],setArrowsOn=_arrowsOn[1];
  var _fontScale=useState(parseFloat(localStorage.getItem("mycel_fontscale"))||1),fontScale=_fontScale[0],setFontScale=_fontScale[1];
  /* ── Connection-drawing state ── */
  var _linkFrom=useState(null),linkFrom=_linkFrom[0],setLinkFrom=_linkFrom[1];
  var _linkPos=useState(null),linkPos=_linkPos[0],setLinkPos=_linkPos[1];

  /* ── Theme (from palette, no separate darkMode) ── */
  var P=PALETTES[palName]||PALETTES.aurora;
  var isDark=P.mode==='dark';
  var BG=P.bg,SURF=P.surface,BRD=P.border,TXT=P.text,DIM=P.dim,MUT=P.muted;
  var cRef=useRef(null);

  /* ── Effects ── */
  useEffect(function(){var uid=localStorage.getItem("mycel_uid");if(uid)getMe().then(function(d){if(d.user)setUser(d.user);}).catch(function(){});},[]);
  useEffect(function(){
    if(view==="library")getMaps().then(function(d){setMaps(d.maps||[]);}).catch(function(){});
    if(view==="community"){getCommunityMaps("all").then(function(d){setCmaps(d.maps||[]);}).catch(function(){});getLeaderboard().then(function(d){setLeaders(d.users||[]);}).catch(function(){});}
  },[view]);
  useEffect(function(){
    function fn(e){
      if(e.target.tagName==='INPUT'||e.target.tagName==='TEXTAREA'||e.target.tagName==='SELECT')return;
      if((e.metaKey||e.ctrlKey)&&e.key==='z'&&!e.shiftKey){e.preventDefault();undo();}
      if((e.metaKey||e.ctrlKey)&&(e.key==='y'||(e.key==='z'&&e.shiftKey))){e.preventDefault();redo();}
      if(e.key==='Escape'){setSel(null);setTool('select');setEf(null);setLinkFrom(null);setLinkPos(null);}
      if(e.key==='Delete'&&selId&&!editField){setData(function(dd){return{nodes:dd.nodes.filter(function(n){return n.id!==selId;}),edges:dd.edges.filter(function(ed){return ed.source!==selId&&ed.target!==selId;}),drawings:dd.drawings};});setSel(null);}
      if(e.key==='v'||e.key==='V')setTool('select');
      if(e.key==='h'||e.key==='H')setTool('hand');
      if(e.key==='m'||e.key==='M')setTool('magnify');
      if(e.key==='d'||e.key==='D')setTool('draw');
      if(e.key==='e'||e.key==='E')setTool('eraser');
      if(e.key==='l'||e.key==='L')setTool('link');
    }
    window.addEventListener('keydown',fn);return function(){window.removeEventListener('keydown',fn);};
  },[undo,redo,selId,editField,setData]);

  /* ── Core functions ── */
  var fit=useCallback(function(nl){
    if(!cRef.current||!nl||!nl.length)return;var rc=cRef.current.getBoundingClientRect();
    var ax=1e9,ay=1e9,bx=-1e9,by=-1e9;
    for(var i=0;i<nl.length;i++){var r=nl[i].r||60;ax=Math.min(ax,nl[i].x-r);ay=Math.min(ay,nl[i].y-r);bx=Math.max(bx,nl[i].x+r);by=Math.max(by,nl[i].y+r);}
    var gw=bx-ax+120,gh=by-ay+120,z=Math.min(rc.width/gw,rc.height/gh,1.4);
    setCam({x:-(ax-60)*z+(rc.width-gw*z)/2,y:-(ay-60)*z+(rc.height-gh*z)/2,z:z});
  },[]);

  var zoomTo=function(nid){var n=nm[nid];if(!n||!cRef.current)return;var rc=cRef.current.getBoundingClientRect();setCam({x:-n.x*2.5+rc.width/2,y:-n.y*2.5+rc.height/2,z:2.5});setSel(nid);};

  var handleUpload=function(file){
    if(!file)return;setUpFile(file);
    setUpl(true);setProg({stage:'uploading',progress:0,message:'Uploading...'});
    uploadPDF(file).then(function(r){
      if(r.nodes){
        var edgesN=r.edges.map(function(e){return Object.assign({},e,{source:e.source_id||e.source,target:e.target_id||e.target});});
        var laid=organicLayout(r.nodes,edgesN);dispatch({type:'INIT',data:{nodes:laid,edges:edgesN,drawings:[]}});
        setMapId(r.map_id);setView('graph');setColl(new Set());setTimeout(function(){fit(laid);},80);
        setProg({stage:'done',progress:1,message:r.node_count+' concepts, '+r.edge_count+' relations'});
      }else{setProg({stage:'error',progress:0,message:r.error||'Upload failed'});}
      setUpl(false);
    }).catch(function(e){setProg({stage:'error',progress:0,message:e.message||'Failed'});setUpl(false);});
  };

  var loadMap=function(id){getMap(id).then(function(r){if(r.nodes){
    var edgesN=r.edges.map(function(e){return Object.assign({},e,{source:e.source_id||e.source,target:e.target_id||e.target});});
    var laid=organicLayout(r.nodes,edgesN);dispatch({type:'INIT',data:{nodes:laid,edges:edgesN,drawings:[]}});
    setMapId(id);setView('graph');setColl(new Set());setTimeout(function(){fit(laid);},80);
  }});};

  var addNode=function(){if(!cRef.current)return;var cx=(cRef.current.clientWidth/2-cam.x)/cam.z,cy=(cRef.current.clientHeight/2-cam.y)/cam.z;
    var nn={id:'n_'+Date.now(),label:'New Concept',description:'Click to edit',concept_type:'term',abstraction_level:1,confidence:0.5,cluster:'custom',x:cx,y:cy};
    Object.assign(nn,nSize(nn));setData(function(d){return{nodes:d.nodes.concat([nn]),edges:d.edges,drawings:d.drawings};});setSel(nn.id);};

  var createEdge=function(a,b){if(!a||!b||a===b)return;setData(function(dd){
    var dup=dd.edges.some(function(e){return(e.source===a&&e.target===b)||(e.source===b&&e.target===a);});
    if(dup)return dd;
    var ne={id:'e_'+Date.now(),source:a,target:b,relation_type:'IMPLIES',confidence:0.6};
    return Object.assign({},dd,{edges:dd.edges.concat([ne])});});};

  /* ── Derived data ── */
  var nm=useMemo(function(){var m={};nodes.forEach(function(n){m[n.id]=n;});return m;},[nodes]);
  var ch=useMemo(function(){var c={};edges.forEach(function(e){if(!c[e.source])c[e.source]=[];c[e.source].push(e.target);});return c;},[edges]);
  var deg=useMemo(function(){var d={};edges.forEach(function(e){d[e.source]=(d[e.source]||0)+1;d[e.target]=(d[e.target]||0)+1;});return d;},[edges]);
  var maxDeg=useMemo(function(){var m=1;Object.values(deg).forEach(function(v){if(v>m)m=v;});return m;},[deg]);
  var visIds=useMemo(function(){if(!collapsed.size)return new Set(nodes.map(function(n){return n.id;}));var hidden=new Set();collapsed.forEach(function(cid){var q=(ch[cid]||[]).slice();while(q.length){var id=q.shift();if(!hidden.has(id)){hidden.add(id);if(!collapsed.has(id))(ch[id]||[]).forEach(function(c2){q.push(c2);});}}});return new Set(nodes.filter(function(n){return!hidden.has(n.id);}).map(function(n){return n.id;}));},[nodes,collapsed,ch]);
  var vn=useMemo(function(){return nodes.filter(function(n){return visIds.has(n.id);});},[nodes,visIds]);
  var ve=useMemo(function(){return edges.filter(function(e){return visIds.has(e.source)&&visIds.has(e.target);});},[edges,visIds]);
  var hulls=useMemo(function(){var g={};vn.forEach(function(n){var c=n.cluster||'x';if(!g[c])g[c]=[];g[c].push(n);});return Object.keys(g).filter(function(k){return g[k].length>=2;}).map(function(k){return{key:k,d:hullPath(convexHull(g[k].map(function(n2){return{x:n2.x,y:n2.y};})),45)};});},[vn]);
  var ep=useMemo(function(){var p={};ve.forEach(function(e){var k=[e.source,e.target].sort().join('|');if(!p[k])p[k]=[];p[k].push(Object.assign({},e,{idx:p[k].length}));});return p;},[ve]);
  var s2w=useCallback(function(sx,sy){return{x:(sx-cam.x)/cam.z,y:(sy-cam.y)/cam.z};},[cam]);
  var w2s=useCallback(function(wx,wy){return{x:wx*cam.z+cam.x,y:wy*cam.z+cam.y};},[cam]);
  var impSize=function(nid,base){return Math.round(base+(deg[nid]||0)/Math.max(maxDeg,1)*16);};
  var selN=selId?nm[selId]:null;
  var connE=selN?ve.filter(function(e){return e.source===selId||e.target===selId;}):[];
  var showD=cam.z>0.4;
  var stages={uploading:"Uploading",extract:"Extracting",validate:"Validating",done:"Complete",parse:"Parsing",chunk:"Chunking"};
  var cursor=tool==='draw'?'crosshair':tool==='eraser'?'cell':tool==='magnify'?'zoom-in':tool==='link'?'crosshair':tool==='hand'?(dragState?'grabbing':'grab'):'default';

  /* ── Pointer handlers ── */
  var onDown=useCallback(function(e){
    if(e.button!==0)return;var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;
    var sx=e.clientX-rc.left,sy=e.clientY-rc.top,w=s2w(sx,sy);
    if(tool==='hand'){setDrag({t:'p',sx:sx,sy:sy,cx:cam.x,cy:cam.y});e.preventDefault();return;}
    if(tool==='draw'){setDrawPath({color:drawColor,points:[{x:w.x,y:w.y}],width:2});e.preventDefault();return;}
    if(tool==='eraser'){setData(function(dd){return Object.assign({},dd,{drawings:dd.drawings.filter(function(dr){return!dr.points.some(function(pt){return Math.abs(pt.x-w.x)<20&&Math.abs(pt.y-w.y)<20;});})});});return;}
    var hit=null;for(var i=0;i<vn.length;i++){var dx=w.x-vn[i].x,dy=w.y-vn[i].y;if(dx*dx+dy*dy<vn[i].r*vn[i].r){hit=vn[i];break;}}
    if(tool==='link'){if(hit){if(!linkFrom){setLinkFrom(hit.id);setSel(hit.id);}else{createEdge(linkFrom,hit.id);setLinkFrom(null);setLinkPos(null);}}else{setLinkFrom(null);setLinkPos(null);}e.preventDefault();return;}
    if(tool==='magnify'){if(hit){zoomTo(hit.id);}else{setCam(function(c){var cx=rc.width/2,cy=rc.height/2;var nz=Math.min(5,c.z*1.5);return{x:cx-(cx-c.x)*(nz/c.z),y:cy-(cy-c.y)*(nz/c.z),z:nz};});}e.preventDefault();return;}
    if(hit){var nbrs=getNeighbors(hit.id,edges);var offsets={};Object.keys(nbrs).forEach(function(id){offsets[id]={dx:(nm[id]?nm[id].x:0)-hit.x,dy:(nm[id]?nm[id].y:0)-hit.y};});setDrag({t:'c',nid:hit.id,nbrs:nbrs,sx:sx,sy:sy,ox:hit.x,oy:hit.y,off:offsets});e.preventDefault();}
    else{setDrag({t:'p',sx:sx,sy:sy,cx:cam.x,cy:cam.y});}
  },[vn,s2w,cam,nm,edges,tool,drawColor,setData,linkFrom]);

  var onMove=useCallback(function(e){
    var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;
    var sx=e.clientX-rc.left,sy=e.clientY-rc.top;
    if(tool==='link'&&linkFrom){var wl=s2w(sx,sy);setLinkPos({x:wl.x,y:wl.y});return;}
    if(drawPath){var w=s2w(sx,sy);setDrawPath(function(p){return Object.assign({},p,{points:p.points.concat([{x:w.x,y:w.y}])});});return;}
    if(!dragState){if(tool==='select'){var w2=s2w(sx,sy);var hit2=null;for(var i=0;i<vn.length;i++){var dx=w2.x-vn[i].x,dy=w2.y-vn[i].y;if(dx*dx+dy*dy<vn[i].r*vn[i].r){hit2=vn[i];break;}}setHov(hit2?hit2.id:null);}return;}
    var ddx=sx-dragState.sx,ddy=sy-dragState.sy;
    if(dragState.t==='p'){setCam(function(c){return{x:dragState.cx+ddx,y:dragState.cy+ddy,z:c.z};});}
    else if(dragState.t==='c'){var nx=dragState.ox+ddx/cam.z,ny=dragState.oy+ddy/cam.z;setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(n){if(n.id===dragState.nid)return Object.assign({},n,{x:nx,y:ny});if(dragState.off[n.id])return Object.assign({},n,{x:nx+dragState.off[n.id].dx,y:ny+dragState.off[n.id].dy});return n;})});});}
  },[dragState,cam,vn,s2w,drawPath,tool,setData,linkFrom]);

  var onUp=useCallback(function(){if(drawPath&&drawPath.points.length>2){setData(function(dd){return Object.assign({},dd,{drawings:dd.drawings.concat([drawPath])});});}setDrawPath(null);setDrag(null);},[drawPath,setData]);
  var onWheel=useCallback(function(e){e.preventDefault();var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;var sx=e.clientX-rc.left,sy=e.clientY-rc.top,f=e.deltaY>0?0.9:1.1;setCam(function(c){var nz=Math.max(0.15,Math.min(5,c.z*f));return{x:sx-(sx-c.x)*(nz/c.z),y:sy-(sy-c.y)*(nz/c.z),z:nz};});},[]);
  var onDbl=useCallback(function(e){var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;var w=s2w(e.clientX-rc.left,e.clientY-rc.top);var hit=null;for(var i=0;i<vn.length;i++){var dx=w.x-vn[i].x,dy=w.y-vn[i].y;if(dx*dx+dy*dy<vn[i].r*vn[i].r){hit=vn[i];break;}}if(hit){setColl(function(prev){var n2=new Set(prev);if(n2.has(hit.id))n2.delete(hit.id);else n2.add(hit.id);return n2;});}else{fit(nodes);}},[vn,s2w,fit,nodes]);

  /* ════════════════════════════════════════════════════ */
  /*                    BUILD VIEWS                      */
  /* ════════════════════════════════════════════════════ */

  /* ── Onboarding overlay ── */
  var onboardView=showOnboard?h("div",{key:"ob",style:{position:"fixed",inset:0,background:"rgba(0,0,0,0.7)",display:"flex",alignItems:"center",justifyContent:"center",zIndex:200},onClick:function(){setOnboard(false);localStorage.setItem("mycel_onboarded","1");}},
    h("div",{onClick:function(e){e.stopPropagation();},style:{width:400,background:SURF,border:"1px solid "+BRD,borderRadius:20,padding:28,textAlign:"center"}},
      h("div",{style:{fontSize:36,marginBottom:8}},"✦"),
      h("h2",{style:{fontSize:20,fontWeight:700,marginBottom:10,background:"linear-gradient(135deg,#6C5CE7,#00B8A9)",WebkitBackgroundClip:"text",WebkitTextFillColor:"transparent"}},"Welcome to Mycel"),
      h("div",{style:{fontSize:14,color:MUT,lineHeight:1.8,marginBottom:16,textAlign:"left"}},
        "1. Upload a PDF on the ",h("b",null,"Home")," tab",h("br",null),
        "2. AI extracts concepts → mindmap appears",h("br",null),
        "3. Click concepts to edit, drag to rearrange",h("br",null),
        "4. ",h("b",null,"V"),"=select ",h("b",null,"H"),"=hand ",h("b",null,"M"),"=magnify ",h("b",null,"D"),"=draw",h("br",null),
        "5. Confirm + share maps with the community"),
      h("button",{onClick:function(){setOnboard(false);localStorage.setItem("mycel_onboarded","1");},style:Object.assign({width:"100%"},B())},"Get Started"))
  ):null;

  /* ── Header ── */
  var tabs=["home","graph","library","community","help","palace","account"];
  var headerView=h("header",{key:"hd",style:{display:"flex",alignItems:"center",justifyContent:"space-between",padding:"8px 16px",background:SURF,borderBottom:"1px solid "+BRD,flexShrink:0,height:44}},
    h("div",{style:{display:"flex",alignItems:"center",gap:8}},
      h("span",{onClick:function(){setView('home');},style:{fontSize:16,fontWeight:700,cursor:'pointer',background:"linear-gradient(135deg,#6C5CE7,#00B8A9)",WebkitBackgroundClip:"text",WebkitTextFillColor:"transparent"}},"✦ Mycel"),
      h("nav",{style:{display:"flex",gap:2}},tabs.map(function(k){return h("button",{key:k,onClick:function(){setView(k);},style:{padding:"4px 10px",borderRadius:6,border:"none",cursor:"pointer",background:view===k?BG:"transparent",color:view===k?TXT:DIM,fontSize:13,fontWeight:500}},k.charAt(0).toUpperCase()+k.slice(1));}))),
    view==='graph'?h("div",{style:{display:"flex",gap:2,alignItems:"center"}},
      h("span",{style:{fontSize:11,color:linkFrom?"#A29BFE":DIM,marginRight:6}},linkFrom?"click target…":(tool==='link'?"click a node…":vn.length+"·"+ve.length)),
      [{k:'select',l:'↖',t:'Select (V)'},{k:'hand',l:'✋',t:'Pan (H)'},{k:'magnify',l:'🔍',t:'Zoom (M)'},{k:'link',l:'🔗',t:'Connect (L)'},{k:'draw',l:'✎',t:'Draw (D)'},{k:'eraser',l:'⌫',t:'Erase (E)'}].map(function(b){return h("button",{key:b.k,title:b.t,onClick:function(){setTool(b.k);if(b.k!=='link'){setLinkFrom(null);setLinkPos(null);}},style:{padding:"3px 7px",borderRadius:5,border:tool===b.k?"1px solid "+TXT+"30":"1px solid transparent",background:tool===b.k?BG:"transparent",color:tool===b.k?TXT:DIM,fontSize:14,cursor:"pointer"}},b.l);}),
      tool==='draw'?["#A29BFE","#5EECD5","#F0A08A","#FDCB6E","#FD79A8"].map(function(c){return h("div",{key:c,onClick:function(){setDrawColor(c);},style:{width:14,height:14,borderRadius:"50%",background:c,cursor:"pointer",outline:drawColor===c?"2px solid "+TXT:"none",outlineOffset:1,marginLeft:1}});}):null,
      h("div",{style:{width:1,height:14,background:BRD,margin:"0 4px"}}),
      h("button",{title:"Add node",onClick:addNode,style:{padding:"3px 7px",borderRadius:5,border:"1px solid "+BRD,background:"transparent",color:TXT,fontSize:12,cursor:"pointer"}},"+"),
      h("button",{title:"Undo",onClick:undo,style:{padding:"3px 7px",borderRadius:5,border:"1px solid "+BRD,background:"transparent",color:hist.past.length?TXT:DIM,fontSize:12,cursor:"pointer",opacity:hist.past.length?1:0.4}},"↩"),
      h("button",{title:"Redo",onClick:redo,style:{padding:"3px 7px",borderRadius:5,border:"1px solid "+BRD,background:"transparent",color:hist.future.length?TXT:DIM,fontSize:12,cursor:"pointer",opacity:hist.future.length?1:0.4}},"↪"),
      h("div",{style:{width:1,height:14,background:BRD,margin:"0 4px"}}),
      h("button",{title:"Export JSON",onClick:function(){if(mapId)window.open(apiUrl()+"/api/maps/"+mapId+"/export","_blank");},style:{padding:"3px 7px",borderRadius:5,border:"1px solid "+BRD,background:"transparent",color:DIM,fontSize:12,cursor:"pointer"}},"↓"),
      h("button",{title:"PDF split view",onClick:function(){setRefer(!referMode);},style:{padding:"3px 7px",borderRadius:5,border:referMode?"1px solid #A29BFE":"1px solid "+BRD,background:referMode?"rgba(162,155,254,0.12)":"transparent",color:referMode?"#A29BFE":DIM,fontSize:12,cursor:"pointer"}},"📖"),h("button",{title:"Settings",onClick:function(){setShowSettings(!showSettings);},style:{padding:"3px 7px",borderRadius:5,border:showSettings?"1px solid #A29BFE":"1px solid "+BRD,background:showSettings?"rgba(162,155,254,0.12)":"transparent",color:showSettings?"#A29BFE":DIM,fontSize:12,cursor:"pointer"}},"⚙")
    ):null,
    h("div",{style:{display:"flex",alignItems:"center",gap:6}},
      h("button",{onClick:function(){var next=isDark?'notion':'aurora';setPalName(next);localStorage.setItem("mycel_palette",next);},style:{padding:"3px 7px",borderRadius:5,border:"1px solid "+BRD,background:"transparent",color:DIM,fontSize:12,cursor:"pointer"}},isDark?"☀":"🌙"),
      user?h("span",{style:{fontSize:12,color:"#A29BFE",cursor:"pointer"},onClick:function(){setView('account');}},user.display_name+" · "+user.points+"pts"):null)
  );

  /* ── Home ── */
  var homeView=view==='home'?h("div",{key:"hm",style:{flex:1,display:"flex",alignItems:"center",justifyContent:"center",flexDirection:"column",gap:20,padding:"40px 20px"}},
    h("h1",{style:{fontSize:28,fontWeight:700,background:"linear-gradient(135deg,#6C5CE7,#00B8A9)",WebkitBackgroundClip:"text",WebkitTextFillColor:"transparent"}},"Mycel"),
    h("p",{style:{fontSize:15,color:MUT,lineHeight:1.7,maxWidth:420,textAlign:"center"}},"Upload a textbook. AI extracts concepts and shows how they connect."),
    h("div",{onClick:function(){if(!uploading){var el=document.getElementById('fi');if(el)el.click();}},style:{width:"100%",maxWidth:460,border:"2px dashed "+BRD,borderRadius:14,padding:"28px 20px",textAlign:"center",cursor:uploading?"wait":"pointer"}},
      h("input",{id:"fi",type:"file",accept:".pdf,.docx,.txt,.md,.epub",style:{display:"none"},disabled:uploading,onChange:function(e){handleUpload(e.target.files?e.target.files[0]:null);}}),
      prog&&prog.stage!=='done'?h("div",null,h("div",{style:{fontSize:15,fontWeight:600,marginBottom:4}},stages[prog.stage]||'Processing...'),h("div",{style:{fontSize:12,color:DIM}},prog.message)):
      h("div",null,h("div",{style:{fontSize:15,fontWeight:500,marginBottom:4}},"Drop a file or click to upload"),h("div",{style:{fontSize:12,color:DIM}},"PDF, DOCX, TXT, MD, EPUB"),!user?h("div",{style:{fontSize:11,color:DIM,marginTop:6}},"Log in to save maps"):null)),
    h("button",{onClick:function(){setView('library');},style:B(DIM,"transparent")},"Browse library")
  ):null;

  /* ── Library ── */
  var libraryView=view==='library'?h("div",{key:"lb",style:{flex:1,padding:24,overflowY:"auto"}},
    h("h2",{style:{fontSize:18,fontWeight:600,marginBottom:16}},"Your Library"),
    !user?h("div",{style:{textAlign:"center",padding:40,color:DIM}},"Log in to see your maps.",h("br",null),h("br",null),h("button",{onClick:function(){setView('account');},style:B()},"Go to Account")):
    maps.length===0?h("div",{style:{textAlign:"center",padding:40,color:DIM}},"No maps yet."):
    h("div",{style:{display:"grid",gridTemplateColumns:"repeat(auto-fill,minmax(280px,1fr))",gap:12}},maps.map(function(m){return h("div",{key:m.id,style:{padding:16,background:SURF,border:"1px solid "+BRD,borderRadius:12}},
      h("div",{style:{display:"flex",alignItems:"center",gap:6,marginBottom:6}},h("div",{style:{fontSize:15,fontWeight:600,flex:1}},m.title||m.filename),h("span",{style:{fontSize:10,padding:"3px 10px",borderRadius:8,background:m.status==='confirmed'?'rgba(81,207,102,0.15)':'rgba(90,100,120,0.2)',color:m.status==='confirmed'?'#51CF66':DIM}},m.status==='confirmed'?'Confirmed':'Draft')),
      h("div",{style:{fontSize:12,color:DIM,marginBottom:10}},fmtDate(m.created_at)),
      h("div",{style:{display:"flex",gap:4,flexWrap:"wrap"}},
        h("button",{onClick:function(){loadMap(m.id);},style:B()},"Open"),
        h("button",{onClick:function(){exportMap(m.id);},style:B(DIM,"transparent")},"Export"),
        m.status!=='confirmed'?h("button",{onClick:function(){confirmMap(m.id).then(function(){getMaps().then(function(d){setMaps(d.maps||[]);});});},style:B("#51CF66","rgba(81,207,102,0.1)")},"✓ Confirm"):h("button",{onClick:function(){unconfirmMap(m.id).then(function(){getMaps().then(function(d){setMaps(d.maps||[]);});});},style:B(DIM,"transparent")},"Unconfirm"),
        m.status==='confirmed'?h("button",{onClick:function(){setShareM({id:m.id,title:m.title||m.filename});},style:B("#A29BFE","rgba(162,155,254,0.1)")},"Share"):null,
        h("button",{onClick:function(){if(confirm('Delete?'))deleteMap(m.id).then(function(){getMaps().then(function(d){setMaps(d.maps||[]);});});},style:B("#FF6B6B","rgba(255,107,107,0.1)")},"Delete"))
    );})),
    shareModal?h("div",{style:{position:"fixed",inset:0,background:"rgba(0,0,0,0.5)",display:"flex",alignItems:"center",justifyContent:"center",zIndex:100},onClick:function(){setShareM(null);}},h("div",{onClick:function(e){e.stopPropagation();},style:{width:360,background:SURF,border:"1px solid "+BRD,borderRadius:16,padding:24}},
      h("h3",{style:{fontSize:16,fontWeight:600,marginBottom:10}},"Share to Community"),
      h("div",{style:{display:"flex",gap:4,flexWrap:"wrap",marginBottom:14}},["general","mathematics","physics","cs","biology","history"].map(function(d){return h("button",{key:d,onClick:function(){setShareDom(d);},style:{padding:"4px 12px",borderRadius:6,fontSize:11,cursor:"pointer",background:shareDom===d?"rgba(162,155,254,0.2)":"transparent",border:shareDom===d?"1px solid rgba(162,155,254,0.4)":"1px solid "+BRD,color:shareDom===d?"#A29BFE":DIM}},d);})),
      h("div",{style:{display:"flex",gap:6}},h("button",{onClick:function(){shareMap(shareModal.id,shareModal.title,'',shareDom).then(function(){setShareM(null);});},style:Object.assign({flex:1},B())},"Share"),h("button",{onClick:function(){setShareM(null);},style:Object.assign({flex:1},B(DIM,"transparent"))},"Cancel")))):null
  ):null;

  /* ── Community ── */
  var communityView=view==='community'?h("div",{key:"cm",style:{flex:1,padding:24,overflowY:"auto"}},
    h("h2",{style:{fontSize:18,fontWeight:600,marginBottom:16}},"Community"),
    h("div",{style:{display:"flex",gap:4,flexWrap:"wrap",marginBottom:16}},["all","general","mathematics","physics","cs","biology","history"].map(function(d){return h("button",{key:d,onClick:function(){setCommDom(d);getCommunityMaps(d).then(function(r){setCmaps(r.maps||[]);});},style:{padding:"5px 12px",borderRadius:6,fontSize:12,cursor:"pointer",background:commDom===d?"rgba(162,155,254,0.15)":"transparent",border:"1px solid "+(commDom===d?"rgba(162,155,254,0.3)":BRD),color:commDom===d?"#A29BFE":DIM}},d.charAt(0).toUpperCase()+d.slice(1));})),
    cmaps.length===0?h("div",{style:{textAlign:"center",padding:40,color:DIM}},"No community maps yet."):
    h("div",{style:{display:"grid",gridTemplateColumns:"repeat(auto-fill,minmax(280px,1fr))",gap:12}},cmaps.map(function(m){return h("div",{key:m.id,style:{padding:16,background:SURF,border:"1px solid "+BRD,borderRadius:12}},
      h("div",{style:{fontSize:15,fontWeight:600,marginBottom:4}},m.title),
      h("div",{style:{fontSize:11,color:DIM,marginBottom:8}},(m.domain||'')+" · "+(m.user_id||'anon')+" · "+fmtDate(m.created_at)),
      h("div",{style:{display:"flex",gap:4}},h("button",{onClick:function(){upvoteCommunityMap(m.id).then(function(){getCommunityMaps(commDom).then(function(r){setCmaps(r.maps||[]);});});},style:B("#FDCB6E","rgba(253,203,110,0.1)")},"↑ "+(m.upvotes||0)),h("button",{onClick:function(){loadMap(m.map_id);},style:B("#5EECD5","rgba(94,236,213,0.1)")},"Open")));})),
    leaders.length>0?h("div",{style:{marginTop:24}},h("h3",{style:{fontSize:16,fontWeight:600,marginBottom:10}},"Top Contributors"),h("div",{style:{display:"flex",gap:6,flexWrap:"wrap"}},leaders.slice(0,10).map(function(u2,i){return h("div",{key:u2.id,style:{padding:8,background:SURF,border:"1px solid "+BRD,borderRadius:8,display:"flex",alignItems:"center",gap:8,fontSize:12}},h("span",{style:{fontWeight:600,color:i<3?"#FDCB6E":DIM}},i+1),h("span",null,u2.display_name),h("span",{style:{color:DIM}},u2.points+"pts"));}))):null
  ):null;

  /* ── Help ── */
  var helpView=view==='help'?h("div",{key:"hp",style:{flex:1,padding:24,overflowY:"auto",maxWidth:560,margin:"0 auto"}},
    h("h2",{style:{fontSize:18,fontWeight:600,marginBottom:16}},"Help & Feedback"),
    [["How do I create a mindmap?","Upload a PDF on the Home tab. AI extracts concepts automatically."],["How do I edit?","Click a concept, then click the label or description to type."],["How do I connect concepts?","Pick the 🔗 tool (or 'Link' in a concept card), click the source node, then click the target. Change a relation's type or remove it from the concept card's Connections list."],["Tools?","↖ Select, ✋ Hand (pan), 🔍 Magnify, 🔗 Connect, ✎ Draw, ⌫ Erase."],["Styling?","Open ⚙ Settings: toggle concept shapes, switch line style (by type / solid / dashed), arrows, and text size."],["Credits?","Upload +5, Confirm +10, Share +15, Edit +1, Upvote +3."],["Shortcuts?","V=select H=hand M=magnify L=link D=draw E=erase Ctrl+Z=undo Del=remove"]].map(function(qa,i){return h("div",{key:i,style:{marginBottom:8,padding:12,background:SURF,border:"1px solid "+BRD,borderRadius:8}},h("div",{style:{fontSize:14,fontWeight:600,marginBottom:2}},qa[0]),h("div",{style:{fontSize:13,color:MUT,lineHeight:1.5}},qa[1]));}),
    h("h3",{style:{fontSize:16,fontWeight:600,margin:"20px 0 10px"}},"Feedback"),
    fbSent?h("div",{style:{padding:16,background:"rgba(81,207,102,0.1)",borderRadius:8,color:"#51CF66",textAlign:"center"}},"Thank you!"):
    h("div",null,h("select",{value:fbCat,onChange:function(e){setFbCat(e.target.value);},style:{width:"100%",padding:8,background:BG,border:"1px solid "+BRD,borderRadius:6,color:TXT,fontSize:13,marginBottom:6}},["general","bug","feature","other"].map(function(c){return h("option",{key:c,value:c},c);})),
      h("textarea",{value:fbText,onChange:function(e){setFbText(e.target.value);},placeholder:"Your feedback...",rows:3,style:{width:"100%",padding:8,background:BG,border:"1px solid "+BRD,borderRadius:6,color:TXT,fontSize:13,resize:"vertical",marginBottom:6}}),
      h("button",{onClick:function(){if(fbText.trim())postFeedback(fbCat,fbText).then(function(){setFbSent(true);});},style:Object.assign({width:"100%"},B())},"Submit"))
  ):null;

  /* ── Palace ── */
  var palaceView=view==='palace'?h("div",{key:"pl",style:{flex:1,display:"flex",alignItems:"center",justifyContent:"center",flexDirection:"column",gap:16}},
    h("div",{style:{fontSize:48}},"🏛️"),h("h2",{style:{fontSize:20,fontWeight:600}},"Memory Palace"),
    h("p",{style:{fontSize:14,color:DIM,maxWidth:380,textAlign:"center",lineHeight:1.6}},"Walk through your knowledge in 3D. Coming soon."),
    h("div",{style:{fontSize:12,color:DIM,padding:"8px 16px",border:"1px solid "+BRD,borderRadius:8}},"Under development")):null;

  /* ── Account ── */
  var accountView=view==='account'?h("div",{key:"ac",style:{flex:1,padding:28,maxWidth:480,margin:"0 auto",overflowY:"auto"}},
    user?h("div",null,
      h("h2",{style:{fontSize:18,fontWeight:600,marginBottom:14}},"Account"),
      h("div",{style:{padding:16,background:SURF,borderRadius:12,border:"1px solid "+BRD,marginBottom:14}},
        h("div",{style:{fontSize:16,fontWeight:600}},user.display_name),
        h("div",{style:{fontSize:12,color:DIM,marginBottom:10}},"@"+user.username),
        h("div",{style:{display:"flex",gap:20}},h("div",null,h("div",{style:{fontSize:24,fontWeight:700,color:"#A29BFE"}},user.points||0),h("div",{style:{fontSize:11,color:DIM}},"Points")),h("div",null,h("div",{style:{fontSize:24,fontWeight:700,color:"#5EECD5"}},user.level||"beginner"),h("div",{style:{fontSize:11,color:DIM}},"Level")))),
      h("div",{style:{padding:16,background:SURF,borderRadius:12,border:"1px solid "+BRD,marginBottom:14}},
        h("h3",{style:{fontSize:15,fontWeight:600,marginBottom:10}},"Settings"),
        h("div",{style:{display:"flex",justifyContent:"space-between",alignItems:"center",marginBottom:10}},h("span",{style:{fontSize:13}},"Theme"),h("button",{onClick:function(){var n=isDark?'notion':'aurora';setPalName(n);localStorage.setItem("mycel_palette",n);},style:B(DIM,"transparent")},isDark?"☀ Light":"🌙 Dark")),
        h("div",{style:{fontSize:13,marginBottom:6}},"Palette"),
        h("div",{style:{display:"flex",gap:4,flexWrap:"wrap",marginBottom:10}},Object.keys(PALETTES).map(function(k){var p=PALETTES[k];return h("div",{key:k,onClick:function(){setPalName(k);localStorage.setItem("mycel_palette",k);},style:{padding:"4px 8px",borderRadius:6,background:palName===k?p.bg:"transparent",border:palName===k?"2px solid "+p.types.theory.a:"1px solid "+BRD,cursor:"pointer",display:"flex",alignItems:"center",gap:6}},h("div",{style:{width:12,height:12,borderRadius:"50%",background:p.types.theory.a}}),h("span",{style:{fontSize:11,color:palName===k?p.text:DIM}},p.name));})),
        h("div",{style:{display:"flex",justifyContent:"space-between",alignItems:"center"}},h("span",{style:{fontSize:13}},"Onboarding"),h("button",{onClick:function(){setOnboard(true);},style:B(DIM,"transparent")},"Show again"))),
      h("div",{style:{padding:16,background:SURF,borderRadius:12,border:"1px solid "+BRD,marginBottom:14}},
        h("h3",{style:{fontSize:15,fontWeight:600,marginBottom:8}},"Credits"),
        h("div",{style:{fontSize:12,color:MUT,lineHeight:1.8}},"Upload +5 · Confirm +10 · Share +15 · Edit +1 · Upvote +3",h("br",null),"Beginner → Experienced (75) → Expert (300) → Pro (1000) → Org (5000)")),
      h("button",{onClick:function(){localStorage.removeItem("mycel_uid");setUser(null);},style:B("#FF6B6B","rgba(255,107,107,0.1)")},"Log out")
    ):h("div",null,
      h("h2",{style:{fontSize:18,fontWeight:600,marginBottom:14}},authMode==="login"?"Log In":"Create Account"),
      h("input",{value:authU,placeholder:"Username",onChange:function(e){setAuthU(e.target.value);},style:{width:"100%",padding:"10px 14px",background:BG,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:14,marginBottom:8}}),
      h("input",{value:authP,placeholder:"Password",type:"password",onChange:function(e){setAuthP(e.target.value);},style:{width:"100%",padding:"10px 14px",background:BG,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:14,marginBottom:12}}),
      h("button",{onClick:function(){(authMode==="login"?login:register)(authU,authP).then(function(d){if(d.user){localStorage.setItem("mycel_uid",d.user.id);setUser(d.user);}else if(d.user_id){localStorage.setItem("mycel_uid",d.user_id);getMe().then(function(r){if(r.user)setUser(r.user);});}else alert(d.error||"Failed");});},style:Object.assign({width:"100%",marginBottom:8},B())},authMode==="login"?"Log In":"Create Account"),
      h("button",{onClick:function(){setAuthMode(authMode==="login"?"register":"login");},style:Object.assign({width:"100%"},B(DIM,"transparent"))},authMode==="login"?"Need an account? Register":"Have an account? Log in"))
  ):null;

  /* ── Graph (with split mode) ── */
  var graphGuts=view==='graph'?[
    h("div",{key:"dots",style:{position:"absolute",inset:0,zIndex:0,pointerEvents:"none",backgroundImage:"radial-gradient(circle,"+P.dot+" 1px,transparent 1px)",backgroundSize:Math.max(16,26*cam.z)+"px "+Math.max(16,26*cam.z)+"px",backgroundPosition:(cam.x%(26*cam.z))+"px "+(cam.y%(26*cam.z))+"px"}}),
    h("svg",{key:"svg",style:{position:"absolute",inset:0,width:"100%",height:"100%",zIndex:1,overflow:"visible"}},
      h("defs",null,h("marker",{id:"ah",viewBox:"0 0 12 12",refX:"11",refY:"6",markerWidth:"7",markerHeight:"7",orient:"auto"},h("path",{d:"M1 2L10 6L1 10",fill:"none",stroke:"context-stroke",strokeWidth:"1.5",strokeLinecap:"round"}))),
      drawings.map(function(dr,i){if(dr.points.length<2)return null;var d2='M'+dr.points[0].x+' '+dr.points[0].y;for(var j=1;j<dr.points.length;j++)d2+='L'+dr.points[j].x+' '+dr.points[j].y;return h("path",{key:"dr"+i,d:d2,fill:"none",stroke:dr.color,strokeWidth:dr.width/cam.z,opacity:0.7,strokeLinecap:"round",transform:"translate("+cam.x+","+cam.y+") scale("+cam.z+")"});}),
      drawPath&&drawPath.points.length>1?(function(){var d2='M'+drawPath.points[0].x+' '+drawPath.points[0].y;for(var j=1;j<drawPath.points.length;j++)d2+='L'+drawPath.points[j].x+' '+drawPath.points[j].y;return h("path",{key:"adp",d:d2,fill:"none",stroke:drawPath.color,strokeWidth:drawPath.width/cam.z,opacity:0.7,strokeLinecap:"round",transform:"translate("+cam.x+","+cam.y+") scale("+cam.z+")"});})():null,
      hulls.map(function(hl){return h("path",{key:hl.key,d:hl.d,fill:P.hullFill,stroke:P.hullStroke,strokeWidth:1,transform:"translate("+cam.x+","+cam.y+") scale("+cam.z+")"});}),
      Object.keys(ep).map(function(k){return ep[k];}).reduce(function(a,b){return a.concat(b);},[]).map(function(e,i){var s=nm[e.source],t=nm[e.target];if(!s||!t)return null;var cat=edgeCat(e.relation_type),st=P.edges[cat]||P.edges.custom;var thick=st.w*(0.5+(e.confidence||0.5)*0.5);var hi=selId===e.source||selId===e.target||hovId===e.source||hovId===e.target;var path=(cat==='compositional'||cat==='pedagogical')?sPath(s.x,s.y,t.x,t.y):edgePath(s.x,s.y,t.x,t.y,e.idx,ep[[e.source,e.target].sort().join('|')].length);var tr="translate("+cam.x+","+cam.y+") scale("+cam.z+")";var dash=lineMode==='solid'?"":(lineMode==='dashed'?"9 5":st.dash);return h("g",{key:"e"+i},hi?h("path",{d:path,fill:"none",stroke:st.color,strokeWidth:thick+7,opacity:0.12,transform:tr}):null,h("path",{d:path,fill:"none",stroke:st.color,strokeWidth:hi?thick*1.5:thick,strokeDasharray:dash,opacity:hi?0.9:0.55,transform:tr,strokeLinecap:"round",markerEnd:(arrowsOn&&ARROW_CATS.has(cat))?"url(#ah)":""}));}),
      linkFrom&&linkPos&&nm[linkFrom]?h("path",{key:"linkline",d:"M"+nm[linkFrom].x+" "+nm[linkFrom].y+" L"+linkPos.x+" "+linkPos.y,fill:"none",stroke:"#A29BFE",strokeWidth:2,strokeDasharray:"6 5",opacity:0.85,transform:"translate("+cam.x+","+cam.y+") scale("+cam.z+")"}):null,
      vn.map(function(n){var t=typeColor(P,n.concept_type);var isSel=selId===n.id,isHov=hovId===n.id;var dl=showD?(n.dl||[]):[];var totalH=(n.lh||30)+(dl.length?dl.length*16+20:0);var sx2=n.x*cam.z+cam.x,sy2=n.y*cam.z+cam.y;var lSz=Math.round(impSize(n.id,14)*fontScale),dSz=Math.round(impSize(n.id,10)*fontScale);var shp=shapeForType(n.concept_type);var sbox=shapeBox(shp,n.w,totalH);
        return h("g",{key:n.id,transform:"translate("+sx2+","+sy2+") scale("+cam.z+")",style:{cursor:tool==='select'||tool==='magnify'?'pointer':'inherit'},
          onClick:function(ev){ev.stopPropagation();if(tool==='magnify')zoomTo(n.id);else if(tool==='select')setSel(selId===n.id?null:n.id);},
          onPointerDown:function(ev){if(tool==='magnify'){zoomTo(n.id);ev.stopPropagation();ev.preventDefault();return;}if(tool!=='select')return;ev.stopPropagation();var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;var nbrs=getNeighbors(n.id,edges);var off={};Object.keys(nbrs).forEach(function(id){off[id]={dx:(nm[id]?nm[id].x:0)-n.x,dy:(nm[id]?nm[id].y:0)-n.y};});setDrag({t:'c',nid:n.id,nbrs:nbrs,sx:ev.clientX-rc.left,sy:ev.clientY-rc.top,ox:n.x,oy:n.y,off:off});ev.preventDefault();}},
          shapesOn?shapeEl(shp,sbox.w,sbox.h,{fill:t.b,stroke:isSel?t.a:t.s,strokeWidth:isSel?2.5:(isHov?1.6:1.1),opacity:isSel?1:0.92}):null,
          (!shapesOn&&isSel)?h("rect",{x:-n.w/2-6,y:-totalH/2-6,width:n.w+12,height:totalH+12,rx:14,fill:SURF,stroke:t.a,strokeWidth:2,opacity:0.95}):null,
          (!shapesOn&&isHov&&!isSel)?h("rect",{x:-n.w/2-4,y:-totalH/2-4,width:n.w+8,height:totalH+8,rx:12,fill:"none",stroke:t.a,strokeWidth:1,opacity:0.3,strokeDasharray:"4 3"}):null,
          h("circle",{cx:-n.w/2+6,cy:-totalH/2+6,r:4,fill:t.a,opacity:0.7}),
          (n.ll||[]).map(function(line,li){return h("text",{key:"l"+li,x:0,y:-totalH/2+20+li*22,textAnchor:"middle",dominantBaseline:"central",fontSize:lSz,fontWeight:"600",fill:t.a,fontFamily:"'Inter',sans-serif",style:{pointerEvents:"none"}},line);}),
          dl.map(function(line,di){return h("text",{key:"d"+di,x:0,y:-totalH/2+(n.lh||30)+10+di*(dSz+6),textAnchor:"middle",dominantBaseline:"central",fontSize:dSz,fill:t.s,opacity:0.75,fontFamily:"'Inter',sans-serif",style:{pointerEvents:"none"}},line);}));})
    ),
    /* Detail card */
    selN?(function(){var sc=w2s(selN.x,selN.y);var t=typeColor(P,selN.concept_type);var rc=cRef.current?cRef.current.getBoundingClientRect():{width:800};var cW=260;var cx2=Math.min(Math.max(8,sc.x+70),rc.width-cW-12);var cy2=Math.max(8,sc.y-40);
      return h("div",{key:"dc", onPointerDown:function(e){e.stopPropagation();}, style:{position:"absolute",left:cx2,top:cy2,width:cW,background:SURF,border:"1px solid "+BRD,borderRadius:12,padding:"12px 14px",boxShadow:"0 6px 24px rgba(0,0,0,0.25)",zIndex:20,maxHeight:"50vh",overflowY:"auto"}},
        h("div",{style:{display:"flex",alignItems:"center",gap:4,marginBottom:4}},h("div",{style:{width:7,height:7,borderRadius:"50%",background:t.a}}),
          h("select",{value:selN.concept_type,onChange:function(ev){ev.stopPropagation();setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(nd){return nd.id!==selId?nd:Object.assign({},nd,{concept_type:ev.target.value});})});});},style:{fontSize:11,color:t.a,fontWeight:600,textTransform:"uppercase",background:"transparent",border:"1px solid "+t.a+"30",borderRadius:4,padding:"1px 4px",cursor:"pointer"}},["theory","principle","definition","method","example","evidence","argument","term","framework","phenomenon"].map(function(ct){return h("option",{key:ct,value:ct,style:{background:BG,color:TXT}},ct);})),
          h("span",{style:{fontSize:11,color:DIM,marginLeft:"auto"}},Math.round((selN.confidence||0)*100)+"%"),
          h("button",{onClick:function(e){e.stopPropagation();setSel(null);},style:{background:"none",border:"none",color:DIM,fontSize:14,cursor:"pointer",padding:"0 2px"}},"×")),
        editField==='label'?h("input",{value:editVal,onChange:function(e){setEv(e.target.value);},autoFocus:true,onBlur:function(){setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(nd){if(nd.id!==selId)return nd;var up=Object.assign({},nd,{label:editVal});return Object.assign(up,nSize(up));})});});setEf(null);},onKeyDown:function(e){if(e.key==='Enter')e.target.blur();if(e.key==='Escape')setEf(null);},style:{width:"100%",fontSize:15,fontWeight:600,background:BG,border:"1px solid "+t.a+"50",borderRadius:6,color:t.a,padding:"3px 6px",marginBottom:4,fontFamily:"inherit"}}):
          h("h3",{onClick:function(e){e.stopPropagation();setEf('label');setEv(selN.label);},style:{fontSize:15,fontWeight:600,marginBottom:4,cursor:"text",color:t.a}},selN.label),
        editField==='desc'?h("textarea",{value:editVal,onChange:function(e){setEv(e.target.value);},rows:3,autoFocus:true,onBlur:function(){setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(nd){if(nd.id!==selId)return nd;var up=Object.assign({},nd,{description:editVal});return Object.assign(up,nSize(up));})});});setEf(null);},style:{width:"100%",fontSize:13,background:BG,border:"1px solid "+t.a+"50",borderRadius:6,color:t.s,padding:"4px 6px",marginBottom:6,fontFamily:"inherit",lineHeight:1.4,resize:"vertical"}}):
          h("p",{onClick:function(e){e.stopPropagation();setEf('desc');setEv(selN.description||'');},style:{fontSize:13,color:t.s,lineHeight:1.5,marginBottom:6,cursor:"text"}},selN.description||"Click to add description"),
        h("div",{style:{display:"flex",gap:4,marginBottom:6}},h("button",{onClick:function(){submitCorrection({map_id:mapId,type:"approve",original:{id:selId}});},style:B("#51CF66","rgba(81,207,102,0.1)")},"✓"),h("button",{onClick:function(e){e.stopPropagation();setTool('link');setLinkFrom(selId);setLinkPos(null);},style:B("#74B9FF","rgba(116,185,255,0.1)")},"🔗 Link"),h("button",{onClick:function(){setData(function(dd){return{nodes:dd.nodes.filter(function(nd){return nd.id!==selId;}),edges:dd.edges.filter(function(ed){return ed.source!==selId&&ed.target!==selId;}),drawings:dd.drawings};});setSel(null);},style:B("#FF6B6B","rgba(255,107,107,0.1)")},"✗")),
        connE.length>0?h("div",null,h("div",{style:{fontSize:11,color:DIM,fontWeight:600,marginBottom:3}},"Connections ("+connE.length+")"),connE.slice(0,8).map(function(e,i){var isSrc=e.source===selId,oId=isSrc?e.target:e.source,o=nm[oId];var cat=edgeCat(e.relation_type),es=P.edges[cat]||P.edges.custom;return h("div",{key:i,style:{display:"flex",alignItems:"center",gap:4,padding:"4px 6px",background:BG,borderRadius:4,marginBottom:2,borderLeft:"2px solid "+es.color,fontSize:11}},
          h("select",{value:e.relation_type,onPointerDown:function(ev){ev.stopPropagation();},onChange:function(ev){ev.stopPropagation();var nt=ev.target.value;setData(function(dd){return Object.assign({},dd,{edges:dd.edges.map(function(ed){if(ed.source===e.source&&ed.target===e.target&&ed.relation_type===e.relation_type)return Object.assign({},ed,{relation_type:nt});return ed;})});});},style:{fontSize:9,fontWeight:600,textTransform:"uppercase",color:es.color,background:"transparent",border:"1px solid "+es.color+"40",borderRadius:4,padding:"1px 2px",cursor:"pointer",maxWidth:96}},REL_TYPES.map(function(rt){return h("option",{key:rt,value:rt,style:{background:BG,color:TXT}},rt.replace(/_/g,' '));})),
          h("span",{onClick:function(ev){ev.stopPropagation();zoomTo(oId);},style:{color:DIM,cursor:"pointer",flex:1,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}},(isSrc?"→ ":"← ")+(o?o.label:"?")),
          h("button",{title:"Remove connection",onPointerDown:function(ev){ev.stopPropagation();},onClick:function(ev){ev.stopPropagation();setData(function(dd){return Object.assign({},dd,{edges:dd.edges.filter(function(ed){return!(ed.source===e.source&&ed.target===e.target&&ed.relation_type===e.relation_type);})});});},style:{background:"none",border:"none",color:DIM,fontSize:13,cursor:"pointer",padding:"0 2px"}},"×"));})):null);})():null,
    /* Legend */
    h("div",{key:"lg",style:{position:"absolute",top:8,left:8,background:SURF+"DD",backdropFilter:"blur(8px)",padding:"10px 12px",borderRadius:10,border:"1px solid "+BRD,fontSize:12,zIndex:5}},
      ["theory","definition","principle","method","framework","example"].map(function(t2){var c=P.types[t2];if(!c)return null;return h("div",{key:t2,style:{display:"flex",alignItems:"center",gap:5,marginBottom:2}},h("div",{style:{width:8,height:8,borderRadius:"50%",background:c.a}}),h("span",{style:{color:c.a}},t2));})),
    /* Settings panel */
    showSettings?h("div",{key:"st",style:{position:"absolute",top:8,right:8,width:240,background:SURF,border:"1px solid "+BRD,borderRadius:12,padding:"14px 16px",boxShadow:"0 6px 24px rgba(0,0,0,0.2)",zIndex:25,maxHeight:"70vh",overflowY:"auto"}},
      h("div",{style:{display:"flex",justifyContent:"space-between",alignItems:"center",marginBottom:10}},h("span",{style:{fontSize:14,fontWeight:600}},"Settings"),h("button",{onClick:function(){setShowSettings(false);},style:{background:"none",border:"none",color:DIM,fontSize:14,cursor:"pointer"}},"×")),
      h("div",{style:{fontSize:12,fontWeight:600,color:DIM,marginBottom:6}},"PALETTE"),
      h("div",{style:{display:"flex",gap:4,flexWrap:"wrap",marginBottom:12}},Object.keys(PALETTES).map(function(k){var p=PALETTES[k];return h("div",{key:k,onClick:function(){setPalName(k);localStorage.setItem("mycel_palette",k);},style:{padding:"3px 6px",borderRadius:4,background:palName===k?p.bg:"transparent",border:palName===k?"1.5px solid "+p.types.theory.a:"1px solid "+BRD,cursor:"pointer",display:"flex",alignItems:"center",gap:4}},h("div",{style:{width:8,height:8,borderRadius:"50%",background:p.types.theory.a}}),h("span",{style:{fontSize:9,color:palName===k?p.text:DIM}},p.name));})),
      h("div",{style:{display:"flex",justifyContent:"space-between",alignItems:"center",marginBottom:6}},h("span",{style:{fontSize:12,fontWeight:600,color:DIM}},"CONCEPT SHAPES"),h("button",{onClick:function(){var nv=!shapesOn;setShapesOn(nv);localStorage.setItem("mycel_shapes",nv?"1":"0");},style:{padding:"2px 10px",borderRadius:10,fontSize:10,cursor:"pointer",border:"1px solid "+(shapesOn?"rgba(94,236,213,0.4)":BRD),background:shapesOn?"rgba(94,236,213,0.15)":"transparent",color:shapesOn?"#5EECD5":DIM}},shapesOn?"On":"Off")),
      shapesOn?h("div",{style:{fontSize:10,color:MUT,lineHeight:1.7,marginBottom:10}},"● Ellipse = theory / principle",h("br",null),"▭ Rectangle = definition / term",h("br",null),"◆ Diamond = argument / evidence",h("br",null),"⬡ Hexagon = framework",h("br",null),"▢ Pill = method  ·  Rounded = example"):h("div",{style:{fontSize:10,color:MUT,marginBottom:10}},"Text-only mode. Turn on to draw a shape per concept type."),
      h("div",{style:{fontSize:12,fontWeight:600,color:DIM,marginBottom:6}},"LINE STYLE"),
      h("div",{style:{display:"flex",gap:4,marginBottom:6}},[["category","By type"],["solid","Solid"],["dashed","Dashed"]].map(function(lm){return h("button",{key:lm[0],onClick:function(){setLineMode(lm[0]);localStorage.setItem("mycel_linemode",lm[0]);},style:{flex:1,padding:"4px 0",borderRadius:5,fontSize:10,cursor:"pointer",background:lineMode===lm[0]?"rgba(162,155,254,0.15)":"transparent",border:"1px solid "+(lineMode===lm[0]?"rgba(162,155,254,0.4)":BRD),color:lineMode===lm[0]?"#A29BFE":DIM}},lm[1]);})),
      h("div",{style:{display:"flex",justifyContent:"space-between",alignItems:"center",marginBottom:10}},h("span",{style:{fontSize:11,color:MUT}},"Direction arrows"),h("button",{onClick:function(){var nv=!arrowsOn;setArrowsOn(nv);localStorage.setItem("mycel_arrows",nv?"1":"0");},style:{padding:"2px 10px",borderRadius:10,fontSize:10,cursor:"pointer",border:"1px solid "+(arrowsOn?"rgba(162,155,254,0.4)":BRD),background:arrowsOn?"rgba(162,155,254,0.15)":"transparent",color:arrowsOn?"#A29BFE":DIM}},arrowsOn?"On":"Off")),
      h("div",{style:{fontSize:12,fontWeight:600,color:DIM,marginBottom:6}},"TEXT SIZE  "+Math.round(fontScale*100)+"%"),
      h("input",{type:"range",min:"0.8",max:"1.4",step:"0.05",value:fontScale,onChange:function(e){var v=parseFloat(e.target.value);setFontScale(v);localStorage.setItem("mycel_fontscale",String(v));},style:{width:"100%",marginBottom:10,accentColor:"#A29BFE"}}),
      h("div",{style:{fontSize:12,fontWeight:600,color:DIM,marginBottom:6,marginTop:8}},"STYLE PRESETS"),
      h("div",{style:{display:"flex",gap:4,flexWrap:"wrap"}},
        [["Academic","aurora",1,"category"],["Neon","tokyo",1,"category"],["Minimal","notion",0,"solid"],["Nordic","nord",1,"category"],["Warm","paper",1,"category"],["Cool","ice",1,"category"],["Bold","dracula",1,"category"]].map(function(pr){return h("button",{key:pr[0],onClick:function(){setPalName(pr[1]);localStorage.setItem("mycel_palette",pr[1]);var so=pr[2]===1;setShapesOn(so);localStorage.setItem("mycel_shapes",so?"1":"0");setLineMode(pr[3]);localStorage.setItem("mycel_linemode",pr[3]);},style:{padding:"3px 8px",borderRadius:4,fontSize:10,cursor:"pointer",background:palName===pr[1]?"rgba(162,155,254,0.15)":"transparent",border:"1px solid "+(palName===pr[1]?"rgba(162,155,254,0.3)":BRD),color:palName===pr[1]?"#A29BFE":DIM}},pr[0]);}))
    ):null,
    /* Zoom */
    h("div",{key:"zm",style:{position:"absolute",bottom:10,right:10,display:"flex",alignItems:"center",gap:3,background:SURF+"EE",backdropFilter:"blur(8px)",padding:"4px 8px",borderRadius:8,border:"1px solid "+BRD,zIndex:5}},
      h("button",{onClick:function(){setCam(function(c){var rc=cRef.current?cRef.current.getBoundingClientRect():{width:800,height:600};var cx=rc.width/2,cy=rc.height/2;var nz=Math.max(0.15,c.z/1.3);return{x:cx-(cx-c.x)*(nz/c.z),y:cy-(cy-c.y)*(nz/c.z),z:nz};});},style:{width:32,height:32,borderRadius:6,background:"transparent",border:"1px solid "+BRD,color:TXT,fontSize:16,cursor:"pointer",display:"flex",alignItems:"center",justifyContent:"center"}},"−"),
      h("div",{style:{fontSize:11,color:DIM,width:40,textAlign:"center",cursor:"pointer"},onClick:function(){setCam(function(c){return{x:c.x,y:c.y,z:1};});}},Math.round(cam.z*100)+"%"),
      h("button",{onClick:function(){setCam(function(c){var rc=cRef.current?cRef.current.getBoundingClientRect():{width:800,height:600};var cx=rc.width/2,cy=rc.height/2;var nz=Math.min(5,c.z*1.3);return{x:cx-(cx-c.x)*(nz/c.z),y:cy-(cy-c.y)*(nz/c.z),z:nz};});},style:{width:32,height:32,borderRadius:6,background:"transparent",border:"1px solid "+BRD,color:TXT,fontSize:16,cursor:"pointer",display:"flex",alignItems:"center",justifyContent:"center"}},"+"),
      h("button",{onClick:function(){fit(nodes);},style:{width:32,height:32,borderRadius:6,background:"transparent",border:"1px solid "+BRD,color:DIM,fontSize:12,cursor:"pointer",display:"flex",alignItems:"center",justifyContent:"center"}},"⊡"))
  ]:[];

  var graphProps={ref:cRef,style:{flex:1,position:"relative",overflow:"hidden",cursor:cursor},onPointerDown:onDown,onPointerMove:onMove,onPointerUp:onUp,onPointerLeave:onUp,onWheel:onWheel,onDoubleClick:onDbl};
  var graphView=view==='graph'?(
    referMode&&mapId
      ?h("div",{key:"sp",style:{display:"flex",flex:1,overflow:"hidden"}},
        h("div",{style:{flex:"0 0 50%",overflow:"hidden",borderRight:"1px solid "+BRD}},
          h(PDFViewer,{pdfUrl:apiUrl()+"/api/maps/"+mapId+"/pdf",pdfFile:uploadedFile,nodes:vn,edges:ve,palette:P,selectedId:selId,onSelectConcept:function(id){setSel(id);zoomTo(id);},onClose:function(){setRefer(false);},darkMode:isDark,splitMode:true})),
        h("div",Object.assign({key:"gr2"},graphProps),graphGuts))
      :h("div",Object.assign({key:"gr"},graphProps),graphGuts)
  ):null;

  /* ════════════════════════════════════════════════════ */
  return h("div",{style:{height:"100vh",display:"flex",flexDirection:"column",background:BG,color:TXT,fontFamily:"'Inter',system-ui,sans-serif"}},
    onboardView,headerView,homeView,libraryView,communityView,helpView,palaceView,accountView,graphView);
}
