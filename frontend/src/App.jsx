import React,{useState,useMemo,useCallback,useRef,useEffect,useReducer} from"react";
import{uploadPDF,getMaps,getMap,deleteMap,submitCorrection,confirmMap,unconfirmMap,shareMap,getCommunityMaps,upvoteCommunityMap,register,login,getMe,getActivity,getLeaderboard,exportMap,postComment,getComments,postFeedback,updateProfile,getFavorites,renameMap,adminMaps,adminUsers,adminStats}from"./api";
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
var LEVELS=[["Beginner",1],["Experienced",75],["Expert",300],["Professional",1000],["Organizer",5000]];
function levelProgress(points){
  points=points||0;var cur=LEVELS[0],nxt=null;
  for(var i=0;i<LEVELS.length;i++){if(points>=LEVELS[i][1])cur=LEVELS[i];}
  for(var j=0;j<LEVELS.length;j++){if(LEVELS[j][1]>points){nxt=LEVELS[j];break;}}
  var lo=cur[1],hi=nxt?nxt[1]:cur[1];
  var pct=nxt?Math.min(100,Math.round((points-lo)/Math.max(hi-lo,1)*100)):100;
  return{name:cur[0],next:nxt?nxt[0]:null,nextAt:nxt?nxt[1]:null,pct:pct};
}

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
var BASE_TYPES=["theory","principle","definition","method","example","evidence","argument","term","framework","phenomenon"];

/* ── Map-quality rubric (operationalises the theory doc §1.4) ── */
function mapQuality(nodes,edges){
  var nN=nodes.length,nE=edges.length;
  if(!nN)return{score:0,clarity:0,integration:0,hierarchy:0,grounding:0,parsimony:0,orphans:0,hint:"Add some concepts to begin."};
  var labelled=0;edges.forEach(function(e){var rt=(e.relation_type||"").toUpperCase();if(rt&&rt!=="RELATED"&&rt!=="RELATED_TO")labelled++;});
  var clarity=nE?labelled/nE:0;
  // integration: cross-links between different clusters, relative to node count
  var cross=0;var nm={};nodes.forEach(function(n){nm[n.id]=n;});
  edges.forEach(function(e){var s=nm[e.source],t=nm[e.target];if(s&&t&&(s.cluster||"x")!==(t.cluster||"y"))cross++;});
  var integration=Math.min(1,(cross/Math.max(nN,1))/0.6);
  // hierarchy: spread of abstraction levels present
  var levels={};nodes.forEach(function(n){levels[n.abstraction_level==null?1:n.abstraction_level]=1;});
  var hierarchy=Math.min(1,(Object.keys(levels).length-1)/3);
  // grounding: fraction of concepts with description / note / source_quote
  var grounded=0;nodes.forEach(function(n){if((n.description&&n.description.length>4)||n.note||n.source_quote)grounded++;});
  var grounding=grounded/nN;
  // parsimony: penalise orphans
  var deg={};edges.forEach(function(e){deg[e.source]=1;deg[e.target]=1;});
  var orphans=0;nodes.forEach(function(n){if(!deg[n.id])orphans++;});
  var parsimony=Math.max(0,1-(orphans/nN));
  var score=Math.round((clarity*0.25+integration*0.25+hierarchy*0.15+grounding*0.2+parsimony*0.15)*100);
  var hint="";
  if(orphans>0)hint=orphans+" concept"+(orphans>1?"s have":" has")+" no links — connect "+(orphans>1?"them":"it")+".";
  else if(clarity<0.6)hint="Label more relations with a specific type.";
  else if(integration<0.4)hint="Add cross-links between different clusters.";
  else if(grounding<0.5)hint="Add descriptions or notes to more concepts.";
  else hint="Strong structure. Keep integrating.";
  return{score:score,clarity:clarity,integration:integration,hierarchy:hierarchy,grounding:grounding,parsimony:parsimony,orphans:orphans,hint:hint};
}

/* ── Line icons (smooth curves, currentColor; no emoji) ── */
function IC(name,sz){
  var s=sz||16;
  var P={width:s,height:s,viewBox:"0 0 24 24",fill:"none",stroke:"currentColor",strokeWidth:1.8,strokeLinecap:"round",strokeLinejoin:"round",style:{display:"block"}};
  function svg(){var ch=[];for(var i=1;i<arguments.length;i++)ch.push(arguments[i]);return h.apply(null,["svg",P].concat(ch));}
  function pth(d){return h("path",{d:d});}
  function cir(cx,cy,r){return h("circle",{cx:cx,cy:cy,r:r});}
  if(name==='select')return svg(0,pth("M5 3l4.5 16 2.3-6.4 6.2-2.1z"));
  if(name==='hand')return svg(0,pth("M12 3v18M3 12h18M9 6l3-3 3 3M9 18l3 3 3-3M6 9l-3 3 3 3M18 9l3 3-3 3"));
  if(name==='magnify')return svg(0,cir(10.5,10.5,6.5),pth("M15.5 15.5L21 21M10.5 7.5v6M7.5 10.5h6"));
  if(name==='link')return svg(0,cir(7,17,3),cir(17,7,3),pth("M9.3 14.7l5.4-5.4"));
  if(name==='draw')return svg(0,pth("M4 20l1.2-4.2L16.4 4.6a1.6 1.6 0 0 1 2.3 0l.7.7a1.6 1.6 0 0 1 0 2.3L8.2 18.8z"),pth("M14.5 6.5l3 3"));
  if(name==='eraser')return svg(0,pth("M4 15.5l7-7a2 2 0 0 1 2.8 0l3.7 3.7a2 2 0 0 1 0 2.8L16 21H8.5z"),pth("M9 21h11"));
  if(name==='plus')return svg(0,pth("M12 5v14M5 12h14"));
  if(name==='undo')return svg(0,pth("M8 13L3 8l5-5"),pth("M3 8h10a7 7 0 0 1 0 14H8"));
  if(name==='redo')return svg(0,pth("M16 13l5-5-5-5"),pth("M21 8H11a7 7 0 0 0 0 14h5"));
  if(name==='download')return svg(0,pth("M12 3v12M8 11l4 4 4-4M5 20h14"));
  if(name==='split')return svg(0,pth("M4 5h16v14H4zM12 5v14"));
  if(name==='settings')return svg(0,pth("M4 7h9M17 7h3M4 12h3M11 12h9M4 17h11M19 17h1"),cir(15,7,2),cir(9,12,2),cir(17,17,2));
  if(name==='sun')return svg(0,cir(12,12,4),pth("M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M19 5l-2 2M7 17l-2 2"));
  if(name==='moon')return svg(0,pth("M20 14.5A8 8 0 0 1 9.5 4 7 7 0 1 0 20 14.5z"));
  if(name==='fit')return svg(0,pth("M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"));
  if(name==='search')return svg(0,cir(10.5,10.5,6.5),pth("M15.5 15.5L21 21"));
  if(name==='note')return svg(0,pth("M5 4h11l3 3v13H5zM16 4v3h3"),pth("M8 12h8M8 16h5"));
  if(name==='close')return svg(0,pth("M6 6l12 12M18 6L6 18"));
  return svg(0,cir(12,12,8));
}

/* ════════════════════════════════════════════════════════════════ */
export default function App(){
  /* ── Core data ── */
  var hr=useReducer(histR,{past:[],present:{nodes:[],edges:[],drawings:[]},future:[]});
  var hist=hr[0],dispatch=hr[1];
  var D=hist.present,nodes=D.nodes,edges=D.edges,drawings=D.drawings||[],cards=D.cards||[];
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
  var _authD=useState(""),authD=_authD[0],setAuthD=_authD[1];
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
  var _splitRight=useState(localStorage.getItem("mycel_splitright")||"graph"),splitRight=_splitRight[0],setSplitRight=_splitRight[1];
  /* ── Concept search ── */
  var _query=useState(""),query=_query[0],setQuery=_query[1];
  var _showSearch=useState(false),showSearch=_showSearch[0],setShowSearch=_showSearch[1];
  /* ── Account editing ── */
  var _edn=useState(""),edn=_edn[0],setEdn=_edn[1];
  var _ebio=useState(""),ebio=_ebio[0],setEbio=_ebio[1];
  var _elang=useState("en"),elang=_elang[0],setElang=_elang[1];
  var _saved=useState(false),acctSaved=_saved[0],setAcctSaved=_saved[1];
  var _aMaps=useState([]),acctMaps=_aMaps[0],setAcctMaps=_aMaps[1];
  var _aFav=useState([]),acctFavs=_aFav[0],setAcctFavs=_aFav[1];
  var _aAct=useState([]),acctAct=_aAct[0],setAcctAct=_aAct[1];
  /* ── Custom concept & relation types (persisted) ── */
  var _ctypes=useState(function(){try{return JSON.parse(localStorage.getItem("mycel_ctypes")||"[]");}catch(e){return [];}}),customTypes=_ctypes[0],setCustomTypes=_ctypes[1];
  var _crels=useState(function(){try{return JSON.parse(localStorage.getItem("mycel_crels")||"[]");}catch(e){return [];}}),customRels=_crels[0],setCustomRels=_crels[1];
  var _ntName=useState(""),ntName=_ntName[0],setNtName=_ntName[1];
  var _ntColor=useState("#A29BFE"),ntColor=_ntColor[0],setNtColor=_ntColor[1];
  var _nrName=useState(""),nrName=_nrName[0],setNrName=_nrName[1];
  /* ── Library controls ── */
  var _libQ=useState(""),libQ=_libQ[0],setLibQ=_libQ[1];
  var _libSort=useState("recent"),libSort=_libSort[0],setLibSort=_libSort[1];
  var _libFilter=useState("all"),libFilter=_libFilter[0],setLibFilter=_libFilter[1];
  var _renaming=useState(null),renaming=_renaming[0],setRenaming=_renaming[1];
  var _renameVal=useState(""),renameVal=_renameVal[0],setRenameVal=_renameVal[1];
  /* ── Admin ── */
  var _adminKey=useState(localStorage.getItem("mycel_adminkey")||""),adminKey=_adminKey[0],setAdminKey=_adminKey[1];
  var _adminData=useState(null),adminData=_adminData[0],setAdminData=_adminData[1];
  var _adminTab=useState("users"),adminTab=_adminTab[0],setAdminTab=_adminTab[1];
  /* ── Animated onboarding step ── */
  var _obStep=useState(0),obStep=_obStep[0],setObStep=_obStep[1];
  /* ── Image-card drop ── */
  var _cardDrag=useState(null),cardDrag=_cardDrag[0],setCardDrag=_cardDrag[1];

  /* ── Theme (from palette, no separate darkMode) ── */
  var P=PALETTES[palName]||PALETTES.aurora;
  var isDark=P.mode==='dark';
  var BG=P.bg,SURF=P.surface,BRD=P.border,TXT=P.text,DIM=P.dim,MUT=P.muted;
  var cRef=useRef(null);
  var svgRef=useRef(null);

  /* ── Type / relation helpers (base + custom) ── */
  var allTypes=BASE_TYPES.concat(customTypes.map(function(c){return c.name;}));
  var relTypes=REL_TYPES.concat(customRels);
  var tcolor=function(type){for(var i=0;i<customTypes.length;i++){if(customTypes[i].name===type){var c=customTypes[i].color;return{a:c,s:c,b:c+"22"};}}return typeColor(P,type);};
  var qm=useMemo(function(){return mapQuality(nodes,edges);},[nodes,edges]);

  /* ── Export PNG / SVG ── */
  var downloadBlob=function(blob,name){var u=URL.createObjectURL(blob);var a=document.createElement("a");a.href=u;a.download=name;document.body.appendChild(a);a.click();setTimeout(function(){document.body.removeChild(a);URL.revokeObjectURL(u);},100);};
  var buildExportSVG=function(){
    if(!svgRef.current)return null;
    var src=svgRef.current;var rc=cRef.current?cRef.current.getBoundingClientRect():{width:1200,height:800};
    var clone=src.cloneNode(true);
    clone.setAttribute("xmlns","http://www.w3.org/2000/svg");
    clone.setAttribute("width",Math.round(rc.width));clone.setAttribute("height",Math.round(rc.height));
    clone.setAttribute("viewBox","0 0 "+Math.round(rc.width)+" "+Math.round(rc.height));
    var bg=document.createElementNS("http://www.w3.org/2000/svg","rect");
    bg.setAttribute("x",0);bg.setAttribute("y",0);bg.setAttribute("width",Math.round(rc.width));bg.setAttribute("height",Math.round(rc.height));bg.setAttribute("fill",BG);
    clone.insertBefore(bg,clone.firstChild);
    return new XMLSerializer().serializeToString(clone);
  };
  var exportSVG=function(){var s=buildExportSVG();if(!s)return;downloadBlob(new Blob([s],{type:"image/svg+xml"}),"mycel-map.svg");};
  var exportPNG=function(){var s=buildExportSVG();if(!s)return;var rc=cRef.current?cRef.current.getBoundingClientRect():{width:1200,height:800};var scale=2;var img=new Image();var svgBlob=new Blob([s],{type:"image/svg+xml;charset=utf-8"});var url=URL.createObjectURL(svgBlob);img.onload=function(){var cv=document.createElement("canvas");cv.width=Math.round(rc.width*scale);cv.height=Math.round(rc.height*scale);var ctx=cv.getContext("2d");ctx.scale(scale,scale);ctx.drawImage(img,0,0);URL.revokeObjectURL(url);cv.toBlob(function(b){if(b)downloadBlob(b,"mycel-map.png");});};img.onerror=function(){URL.revokeObjectURL(url);alert("PNG export needs the map to use same-origin images only.");};img.src=url;};

  /* ── Image cards ── */
  var addCard=function(src,wx,wy){var c={id:"card_"+Date.now(),x:wx,y:wy,w:180,h:130,src:src};setData(function(dd){return Object.assign({},dd,{cards:(dd.cards||[]).concat([c])});});};
  var onCanvasDrop=function(e){e.preventDefault();if(!e.dataTransfer||!e.dataTransfer.files||!e.dataTransfer.files.length)return;var f=e.dataTransfer.files[0];if(!f.type||f.type.indexOf("image")!==0)return;var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;var wx=(e.clientX-rc.left-cam.x)/cam.z,wy=(e.clientY-rc.top-cam.y)/cam.z;var rd=new FileReader();rd.onload=function(){addCard(rd.result,wx,wy);};rd.readAsDataURL(f);};

  /* ── Effects ── */
  useEffect(function(){var uid=localStorage.getItem("mycel_uid");if(uid)getMe().then(function(d){if(d.user)setUser(d.user);}).catch(function(){});},[]);
  useEffect(function(){
    if(view==="library")getMaps().then(function(d){setMaps(d.maps||[]);}).catch(function(){});
    if(view==="community"){getCommunityMaps("all").then(function(d){setCmaps(d.maps||[]);}).catch(function(){});getLeaderboard().then(function(d){setLeaders(d.users||[]);}).catch(function(){});}
    if(view==="account"&&user){setEdn(user.display_name||"");setEbio(user.bio||"");setElang(user.language||"en");setAcctSaved(false);getMaps().then(function(d){setAcctMaps(d.maps||[]);}).catch(function(){});getFavorites().then(function(d){setAcctFavs(d.maps||d.favorites||[]);}).catch(function(){});getActivity().then(function(d){setAcctAct(d.activity||d.actions||[]);}).catch(function(){});}
  },[view,user]);
  useEffect(function(){localStorage.setItem("mycel_ctypes",JSON.stringify(customTypes));},[customTypes]);
  useEffect(function(){localStorage.setItem("mycel_crels",JSON.stringify(customRels));},[customRels]);
  useEffect(function(){if(showOnboard)setObStep(0);},[showOnboard]);
  useEffect(function(){if(view==="admin"&&adminKey){adminUsers(adminKey).then(function(u){adminMaps(adminKey).then(function(m){adminStats(adminKey).then(function(s){setAdminData({users:u.users||u||[],maps:m.maps||m||[],stats:s||{}});}).catch(function(){setAdminData({users:u.users||[],maps:m.maps||[],stats:{}});});}).catch(function(){});}).catch(function(){setAdminData({error:true});});}},[view,adminKey]);
  useEffect(function(){
    function fn(e){
      if(e.target.tagName==='INPUT'||e.target.tagName==='TEXTAREA'||e.target.tagName==='SELECT')return;
      if((e.metaKey||e.ctrlKey)&&e.key==='z'&&!e.shiftKey){e.preventDefault();undo();}
      if((e.metaKey||e.ctrlKey)&&(e.key==='y'||(e.key==='z'&&e.shiftKey))){e.preventDefault();redo();}
      if(e.key==='Escape'){setSel(null);setTool('select');setEf(null);setLinkFrom(null);setLinkPos(null);}
      if(e.key==='Delete'&&selId&&!editField){setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.filter(function(n){return n.id!==selId;}),edges:dd.edges.filter(function(ed){return ed.source!==selId&&ed.target!==selId;})});});setSel(null);}
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
        var laid=organicLayout(r.nodes,edgesN);dispatch({type:'INIT',data:{nodes:laid,edges:edgesN,drawings:[],cards:(r.cards||[])}});
        setMapId(r.map_id);setView('graph');setColl(new Set());setTimeout(function(){fit(laid);},80);
        setProg({stage:'done',progress:1,message:r.node_count+' concepts, '+r.edge_count+' relations'});
      }else{setProg({stage:'error',progress:0,message:r.error||'Upload failed'});}
      setUpl(false);
    }).catch(function(e){setProg({stage:'error',progress:0,message:e.message||'Failed'});setUpl(false);});
  };

  var loadMap=function(id){getMap(id).then(function(r){if(r.nodes){
    var edgesN=r.edges.map(function(e){return Object.assign({},e,{source:e.source_id||e.source,target:e.target_id||e.target});});
    var laid=organicLayout(r.nodes,edgesN);dispatch({type:'INIT',data:{nodes:laid,edges:edgesN,drawings:[],cards:(r.cards||[])}});
    setMapId(id);setView('graph');setColl(new Set());setTimeout(function(){fit(laid);},80);
  }});};

  var addNode=function(){if(!cRef.current)return;var cx=(cRef.current.clientWidth/2-cam.x)/cam.z,cy=(cRef.current.clientHeight/2-cam.y)/cam.z;
    var nn={id:'n_'+Date.now(),label:'New Concept',description:'Click to edit',concept_type:'term',abstraction_level:1,confidence:0.5,cluster:'custom',x:cx,y:cy};
    Object.assign(nn,nSize(nn));setData(function(d){return Object.assign({},d,{nodes:d.nodes.concat([nn])});});setSel(nn.id);};

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
    else if(dragState.t==='card'){var cnx=dragState.ox+ddx/cam.z,cny=dragState.oy+ddy/cam.z;setData(function(dd){return Object.assign({},dd,{cards:(dd.cards||[]).map(function(cc){return cc.id===dragState.cid?Object.assign({},cc,{x:cnx,y:cny}):cc;})});});}
  },[dragState,cam,vn,s2w,drawPath,tool,setData,linkFrom]);

  var onUp=useCallback(function(){if(drawPath&&drawPath.points.length>2){setData(function(dd){return Object.assign({},dd,{drawings:dd.drawings.concat([drawPath])});});}setDrawPath(null);setDrag(null);},[drawPath,setData]);
  var onWheel=useCallback(function(e){e.preventDefault();var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;var sx=e.clientX-rc.left,sy=e.clientY-rc.top,f=e.deltaY>0?0.9:1.1;setCam(function(c){var nz=Math.max(0.15,Math.min(5,c.z*f));return{x:sx-(sx-c.x)*(nz/c.z),y:sy-(sy-c.y)*(nz/c.z),z:nz};});},[]);
  var onDbl=useCallback(function(e){var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;var w=s2w(e.clientX-rc.left,e.clientY-rc.top);var hit=null;for(var i=0;i<vn.length;i++){var dx=w.x-vn[i].x,dy=w.y-vn[i].y;if(dx*dx+dy*dy<vn[i].r*vn[i].r){hit=vn[i];break;}}if(hit){setColl(function(prev){var n2=new Set(prev);if(n2.has(hit.id))n2.delete(hit.id);else n2.add(hit.id);return n2;});}else{fit(nodes);}},[vn,s2w,fit,nodes]);

  /* ════════════════════════════════════════════════════ */
  /*                    BUILD VIEWS                      */
  /* ════════════════════════════════════════════════════ */

  /* ── Onboarding overlay (animated, multi-step) ── */
  var obSteps=[
    {t:"Welcome to Mycel",b:"A mindmap is the trace of your thinking — not just a pretty picture. Mycel helps you see the structure behind what you learn."},
    {t:"Start from anything",b:"Upload a PDF for an AI first draft, or build a map yourself. The draft is something to react to, not just consume."},
    {t:"Watch it grow",b:"Concepts appear and connect like mycelium. Click any concept to read it, edit it, or add your own notes and questions."},
    {t:"The links are the point",b:"Understanding lives in the relations. Use the Connect tool to draw labelled links between ideas, and add cross-links between clusters."},
    {t:"Refine & share",b:"Open Settings to see your Map Quality meter, export as PNG/SVG, then confirm and share your map with the community."}
  ];
  var obDone=function(){setOnboard(false);localStorage.setItem("mycel_onboarded","1");};
  var obIllus=h("svg",{key:"il"+obStep,viewBox:"0 0 240 120",style:{width:200,height:100,margin:"0 auto 4px",display:"block"}},
    h("line",{x1:120,y1:60,x2:60,y2:30,stroke:"#6C5CE7",strokeWidth:2,strokeDasharray:"70",strokeDashoffset:"70",style:{animation:"mycelDraw .5s ease .15s forwards"}}),
    h("line",{x1:120,y1:60,x2:185,y2:34,stroke:"#00B8A9",strokeWidth:2,strokeDasharray:"75",strokeDashoffset:"75",style:{animation:"mycelDraw .5s ease .3s forwards"}}),
    h("line",{x1:120,y1:60,x2:70,y2:96,stroke:"#5EECD5",strokeWidth:2,strokeDasharray:"75",strokeDashoffset:"75",style:{animation:"mycelDraw .5s ease .45s forwards"}}),
    h("line",{x1:120,y1:60,x2:182,y2:92,stroke:"#FD79A8",strokeWidth:2,strokeDasharray:"75",strokeDashoffset:"75",style:{animation:"mycelDraw .5s ease .6s forwards"}}),
    h("circle",{cx:120,cy:60,r:14,fill:"#6C5CE7",style:{transformOrigin:"120px 60px",animation:"mycelPop .4s ease both"}}),
    h("circle",{cx:60,cy:30,r:8,fill:"#A29BFE",style:{transformOrigin:"60px 30px",animation:"mycelPop .4s ease .25s both"}}),
    h("circle",{cx:185,cy:34,r:8,fill:"#00B8A9",style:{transformOrigin:"185px 34px",animation:"mycelPop .4s ease .4s both"}}),
    h("circle",{cx:70,cy:96,r:8,fill:"#5EECD5",style:{transformOrigin:"70px 96px",animation:"mycelPop .4s ease .55s both"}}),
    h("circle",{cx:182,cy:92,r:8,fill:"#FD79A8",style:{transformOrigin:"182px 92px",animation:"mycelPop .4s ease .7s both"}}));
  var onboardView=showOnboard?h("div",{key:"ob",style:{position:"fixed",inset:0,background:"rgba(0,0,0,0.7)",display:"flex",alignItems:"center",justifyContent:"center",zIndex:200},onClick:obDone},
    h("style",null,"@keyframes mycelDraw{to{stroke-dashoffset:0}}@keyframes mycelPop{from{transform:scale(0);opacity:0}to{transform:scale(1);opacity:1}}@keyframes mycelIn{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}"),
    h("div",{onClick:function(e){e.stopPropagation();},style:{width:400,maxWidth:"90vw",background:SURF,border:"1px solid "+BRD,borderRadius:20,padding:28,textAlign:"center",position:"relative"}},
      h("button",{onClick:obDone,style:{position:"absolute",top:12,right:14,background:"none",border:"none",color:DIM,cursor:"pointer",fontSize:13}},"Skip"),
      obIllus,
      h("div",{key:"txt"+obStep,style:{animation:"mycelIn .35s ease"}},
        h("h2",{style:{fontSize:20,fontWeight:700,margin:"6px 0 10px",background:"linear-gradient(135deg,#6C5CE7,#00B8A9)",WebkitBackgroundClip:"text",WebkitTextFillColor:"transparent"}},obSteps[obStep].t),
        h("p",{style:{fontSize:14,color:MUT,lineHeight:1.7,marginBottom:18,minHeight:64}},obSteps[obStep].b)),
      h("div",{style:{display:"flex",justifyContent:"center",gap:6,marginBottom:16}},obSteps.map(function(s,i){return h("div",{key:i,onClick:function(){setObStep(i);},style:{width:i===obStep?22:8,height:8,borderRadius:8,background:i===obStep?"#A29BFE":BRD,cursor:"pointer",transition:"width .2s"}});})),
      h("div",{style:{display:"flex",gap:8}},
        obStep>0?h("button",{onClick:function(){setObStep(obStep-1);},style:Object.assign({flex:1},B(DIM,"transparent"))},"Back"):null,
        h("button",{onClick:function(){if(obStep<obSteps.length-1)setObStep(obStep+1);else obDone();},style:Object.assign({flex:2},B())},obStep<obSteps.length-1?"Next":"Get started")))
  ):null;

  /* ── Header ── */
  var tabs=["home","graph","library","community","help","palace","account"].concat((user&&user.role==='admin')||adminKey?["admin"]:[]);
  var headerView=h("header",{key:"hd",style:{display:"flex",alignItems:"center",justifyContent:"space-between",padding:"8px 16px",background:SURF,borderBottom:"1px solid "+BRD,flexShrink:0,height:44}},
    h("div",{style:{display:"flex",alignItems:"center",gap:8}},
      h("span",{onClick:function(){setView('home');},style:{fontSize:16,fontWeight:700,cursor:'pointer',background:"linear-gradient(135deg,#6C5CE7,#00B8A9)",WebkitBackgroundClip:"text",WebkitTextFillColor:"transparent"}},"✦ Mycel"),
      h("nav",{style:{display:"flex",gap:2}},tabs.map(function(k){return h("button",{key:k,onClick:function(){setView(k);},style:{padding:"4px 10px",borderRadius:6,border:"none",cursor:"pointer",background:view===k?BG:"transparent",color:view===k?TXT:DIM,fontSize:13,fontWeight:500}},k.charAt(0).toUpperCase()+k.slice(1));}))),
    view==='graph'?h("div",{style:{display:"flex",gap:2,alignItems:"center"}},
      h("span",{style:{fontSize:11,color:linkFrom?"#A29BFE":DIM,marginRight:6}},linkFrom?"click target…":(tool==='link'?"click a node…":vn.length+"·"+ve.length)),
      [{k:'select',t:'Select (V)'},{k:'hand',t:'Pan (H)'},{k:'magnify',t:'Zoom (M)'},{k:'link',t:'Connect (L)'},{k:'draw',t:'Draw (D)'},{k:'eraser',t:'Erase (E)'}].map(function(b){return h("button",{key:b.k,title:b.t,onClick:function(){setTool(b.k);if(b.k!=='link'){setLinkFrom(null);setLinkPos(null);}},style:{padding:"5px 7px",borderRadius:5,border:tool===b.k?"1px solid "+TXT+"30":"1px solid transparent",background:tool===b.k?BG:"transparent",color:tool===b.k?TXT:DIM,cursor:"pointer",display:"inline-flex",alignItems:"center",justifyContent:"center"}},IC(b.k));}),
      tool==='draw'?["#A29BFE","#5EECD5","#F0A08A","#FDCB6E","#FD79A8"].map(function(c){return h("div",{key:c,onClick:function(){setDrawColor(c);},style:{width:14,height:14,borderRadius:"50%",background:c,cursor:"pointer",outline:drawColor===c?"2px solid "+TXT:"none",outlineOffset:1,marginLeft:1}});}):null,
      h("div",{style:{width:1,height:14,background:BRD,margin:"0 4px"}}),
      h("button",{title:"Add node",onClick:addNode,style:{padding:"5px 7px",borderRadius:5,border:"1px solid "+BRD,background:"transparent",color:TXT,cursor:"pointer",display:"inline-flex",alignItems:"center"}},IC('plus')),
      h("button",{title:"Undo",onClick:undo,style:{padding:"5px 7px",borderRadius:5,border:"1px solid "+BRD,background:"transparent",color:hist.past.length?TXT:DIM,cursor:"pointer",opacity:hist.past.length?1:0.4,display:"inline-flex",alignItems:"center"}},IC('undo')),
      h("button",{title:"Redo",onClick:redo,style:{padding:"5px 7px",borderRadius:5,border:"1px solid "+BRD,background:"transparent",color:hist.future.length?TXT:DIM,cursor:"pointer",opacity:hist.future.length?1:0.4,display:"inline-flex",alignItems:"center"}},IC('redo')),
      h("div",{style:{width:1,height:14,background:BRD,margin:"0 4px"}}),
      h("button",{title:"Export JSON",onClick:function(){if(mapId)window.open(apiUrl()+"/api/maps/"+mapId+"/export","_blank");},style:{padding:"5px 7px",borderRadius:5,border:"1px solid "+BRD,background:"transparent",color:DIM,cursor:"pointer",display:"inline-flex",alignItems:"center"}},IC('download')),
      h("button",{title:"PDF split view",onClick:function(){setRefer(!referMode);},style:{padding:"5px 7px",borderRadius:5,border:referMode?"1px solid #A29BFE":"1px solid "+BRD,background:referMode?"rgba(162,155,254,0.12)":"transparent",color:referMode?"#A29BFE":DIM,cursor:"pointer",display:"inline-flex",alignItems:"center"}},IC('split')),
      referMode?h("div",{style:{display:"flex",border:"1px solid "+BRD,borderRadius:5,overflow:"hidden"}},[["graph","Graph"],["list","List"]].map(function(sr){return h("button",{key:sr[0],onClick:function(){setSplitRight(sr[0]);localStorage.setItem("mycel_splitright",sr[0]);},style:{padding:"4px 8px",border:"none",background:splitRight===sr[0]?"rgba(162,155,254,0.18)":"transparent",color:splitRight===sr[0]?"#A29BFE":DIM,fontSize:11,cursor:"pointer"}},sr[1]);})):null,
      h("button",{title:"Settings",onClick:function(){setShowSettings(!showSettings);},style:{padding:"5px 7px",borderRadius:5,border:showSettings?"1px solid #A29BFE":"1px solid "+BRD,background:showSettings?"rgba(162,155,254,0.12)":"transparent",color:showSettings?"#A29BFE":DIM,cursor:"pointer",display:"inline-flex",alignItems:"center"}},IC('settings')),
      h("button",{title:"Find concept",onClick:function(){setShowSearch(!showSearch);},style:{padding:"5px 7px",borderRadius:5,border:showSearch?"1px solid #A29BFE":"1px solid "+BRD,background:showSearch?"rgba(162,155,254,0.12)":"transparent",color:showSearch?"#A29BFE":DIM,cursor:"pointer",display:"inline-flex",alignItems:"center"}},IC('search'))
    ):null,
    h("div",{style:{display:"flex",alignItems:"center",gap:6}},
      h("button",{title:isDark?"Light mode":"Dark mode",onClick:function(){var next=isDark?'notion':'aurora';setPalName(next);localStorage.setItem("mycel_palette",next);},style:{padding:"5px 7px",borderRadius:5,border:"1px solid "+BRD,background:"transparent",color:DIM,cursor:"pointer",display:"inline-flex",alignItems:"center"}},isDark?IC('sun'):IC('moon')),
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
  var libList=maps.filter(function(m){var q=libQ.trim().toLowerCase();var okQ=!q||((m.title||m.filename||"").toLowerCase().indexOf(q)>=0);var okF=libFilter==="all"||(libFilter==="confirmed"?m.status==="confirmed":m.status!=="confirmed");return okQ&&okF;}).slice().sort(function(a,b){if(libSort==="name")return((a.title||a.filename||"")).localeCompare(b.title||b.filename||"");if(libSort==="oldest")return((a.created_at||"")<(b.created_at||"")?-1:1);return((a.created_at||"")>(b.created_at||"")?-1:1);});
  var libraryView=view==='library'?h("div",{key:"lb",style:{flex:1,padding:24,overflowY:"auto"}},
    h("div",{style:{display:"flex",alignItems:"center",gap:10,marginBottom:14,flexWrap:"wrap"}},
      h("h2",{style:{fontSize:18,fontWeight:600,marginRight:"auto"}},"Your Library"),
      user&&maps.length?h("input",{value:libQ,onChange:function(e){setLibQ(e.target.value);},placeholder:"Search maps…",style:{padding:"6px 12px",background:SURF,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:13,width:180,fontFamily:"inherit"}}):null,
      user&&maps.length?h("select",{value:libSort,onChange:function(e){setLibSort(e.target.value);},style:{padding:"6px 10px",background:SURF,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:13,fontFamily:"inherit"}},[["recent","Newest"],["oldest","Oldest"],["name","Name A–Z"]].map(function(o){return h("option",{key:o[0],value:o[0]},o[1]);})):null,
      user&&maps.length?h("div",{style:{display:"flex",border:"1px solid "+BRD,borderRadius:8,overflow:"hidden"}},[["all","All"],["draft","Drafts"],["confirmed","Confirmed"]].map(function(f){return h("button",{key:f[0],onClick:function(){setLibFilter(f[0]);},style:{padding:"6px 10px",border:"none",background:libFilter===f[0]?"rgba(162,155,254,0.18)":"transparent",color:libFilter===f[0]?"#A29BFE":DIM,fontSize:12,cursor:"pointer"}},f[1]);})):null),
    !user?h("div",{style:{textAlign:"center",padding:40,color:DIM}},"Log in to see your maps.",h("br",null),h("br",null),h("button",{onClick:function(){setView('account');},style:B()},"Go to Account")):
    maps.length===0?h("div",{style:{textAlign:"center",padding:40,color:DIM}},"No maps yet."):
    libList.length===0?h("div",{style:{textAlign:"center",padding:40,color:DIM}},"No maps match your filters."):
    h("div",{style:{display:"grid",gridTemplateColumns:"repeat(auto-fill,minmax(280px,1fr))",gap:12}},libList.map(function(m){return h("div",{key:m.id,style:{padding:16,background:SURF,border:"1px solid "+BRD,borderRadius:12}},
      renaming===m.id?h("div",{style:{display:"flex",gap:4,marginBottom:6}},h("input",{value:renameVal,autoFocus:true,onChange:function(e){setRenameVal(e.target.value);},onKeyDown:function(e){if(e.key==='Enter'){renameMap(m.id,renameVal).then(function(){setRenaming(null);getMaps().then(function(d){setMaps(d.maps||[]);});});}if(e.key==='Escape')setRenaming(null);},style:{flex:1,padding:"4px 8px",background:BG,border:"1px solid "+BRD,borderRadius:6,color:TXT,fontSize:14,fontFamily:"inherit"}}),h("button",{onClick:function(){renameMap(m.id,renameVal).then(function(){setRenaming(null);getMaps().then(function(d){setMaps(d.maps||[]);});});},style:B()},"Save")):
      h("div",{style:{display:"flex",alignItems:"center",gap:6,marginBottom:6}},h("div",{style:{fontSize:15,fontWeight:600,flex:1}},m.title||m.filename),h("span",{style:{fontSize:10,padding:"3px 10px",borderRadius:8,background:m.status==='confirmed'?'rgba(81,207,102,0.15)':'rgba(90,100,120,0.2)',color:m.status==='confirmed'?'#51CF66':DIM}},m.status==='confirmed'?'Confirmed':'Draft')),
      h("div",{style:{fontSize:12,color:DIM,marginBottom:10}},fmtDate(m.created_at)+(m.node_count?(" · "+m.node_count+" concepts"):"")),
      h("div",{style:{display:"flex",gap:4,flexWrap:"wrap"}},
        h("button",{onClick:function(){loadMap(m.id);},style:B()},"Open"),
        h("button",{onClick:function(){setRenaming(m.id);setRenameVal(m.title||m.filename||"");},style:B(DIM,"transparent")},"Rename"),
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
    [["How do I create a map?","Upload a PDF, DOCX, TXT, MD or EPUB on the Home tab and the AI extracts a first draft. You can also press Add node to start one by hand."],["How do I edit a concept?","Click it, then click the title or description to type. Each concept also has a Notes field for your own questions and reasoning."],["How do I connect concepts?","Pick the Connect tool (or press L, or use the Link button in a concept card), click the source, then the target. Set or remove a relation's type in the card's Connections list. The links are where understanding lives, so label them."],["What do the tools do?","Select, Pan, Magnify, Connect, Draw, and Erase — all line icons in the top toolbar. Use the Search icon to find any concept fast."],["Can I add images?","Yes — drag an image file onto the canvas and it becomes a movable card. Use the × on a card to remove it."],["What is Map Quality?","Open Settings to see a live rubric (clarity, integration, hierarchy, grounding, parsimony). It nudges you toward the habits that research links to deeper learning."],["How do I export?","Settings has Export as PNG, SVG, or JSON. Library cards also export JSON."],["Custom types?","In Settings, add your own concept types (with a colour) and relation types; they appear in every concept and connection menu."],["PDF split view?","Toggle split view in the toolbar, then switch the right pane between Graph and List. Selecting a concept highlights and scrolls to its source in the PDF."],["Shortcuts","V select · H pan · M magnify · L link · D draw · E erase · Ctrl+Z undo · Ctrl+Y redo · Del remove · Esc deselect."]].map(function(qa,i){return h("div",{key:i,style:{marginBottom:8,padding:12,background:SURF,border:"1px solid "+BRD,borderRadius:8}},h("div",{style:{fontSize:14,fontWeight:600,marginBottom:2}},qa[0]),h("div",{style:{fontSize:13,color:MUT,lineHeight:1.5}},qa[1]));}),
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

  /* ── Admin dashboard ── */
  var adminView=view==='admin'?h("div",{key:"ad",style:{flex:1,padding:24,overflowY:"auto"}},
    h("h2",{style:{fontSize:18,fontWeight:600,marginBottom:12}},"Admin Dashboard"),
    h("div",{style:{display:"flex",gap:8,marginBottom:16,alignItems:"center"}},
      h("input",{type:"password",value:adminKey,placeholder:"Admin key",onChange:function(e){setAdminKey(e.target.value);},style:{padding:"8px 12px",background:SURF,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:13,width:220,fontFamily:"inherit"}}),
      h("button",{onClick:function(){localStorage.setItem("mycel_adminkey",adminKey);setAdminData(null);adminUsers(adminKey).then(function(u){adminMaps(adminKey).then(function(m){adminStats(adminKey).then(function(s){setAdminData({users:u.users||u||[],maps:m.maps||m||[],stats:s||{}});}).catch(function(){setAdminData({users:u.users||[],maps:m.maps||[],stats:{}});});}).catch(function(){});}).catch(function(){setAdminData({error:true});});},style:B()},"Load")),
    adminData&&adminData.error?h("div",{style:{padding:30,textAlign:"center",color:"#FF6B6B"}},"Could not load admin data — check the key and that the backend admin endpoints are enabled."):
    !adminData?h("div",{style:{padding:30,textAlign:"center",color:DIM}},"Enter your admin key to view users, maps, and stats. The backend exposes /api/admin/* behind this key."):
    h("div",null,
      adminData.stats&&Object.keys(adminData.stats).length?h("div",{style:{display:"flex",gap:8,flexWrap:"wrap",marginBottom:16}},Object.keys(adminData.stats).map(function(k){return h("div",{key:k,style:{flex:"1 1 120px",padding:12,background:SURF,border:"1px solid "+BRD,borderRadius:10,textAlign:"center"}},h("div",{style:{fontSize:22,fontWeight:700,color:"#A29BFE"}},String(adminData.stats[k])),h("div",{style:{fontSize:11,color:DIM}},k.replace(/_/g,' ')));})):null,
      h("div",{style:{display:"flex",gap:6,marginBottom:10}},[["users","Users ("+(adminData.users?adminData.users.length:0)+")"],["maps","Maps ("+(adminData.maps?adminData.maps.length:0)+")"]].map(function(tb){return h("button",{key:tb[0],onClick:function(){setAdminTab(tb[0]);},style:adminTab===tb[0]?B():B(DIM,"transparent")},tb[1]);})),
      adminTab==="users"?h("div",{style:{background:SURF,border:"1px solid "+BRD,borderRadius:10,overflow:"hidden"}},(adminData.users||[]).slice(0,200).map(function(u2,i){return h("div",{key:u2.id||i,style:{display:"flex",gap:10,padding:"8px 12px",borderBottom:i<(adminData.users.length-1)?"1px solid "+BRD:"none",fontSize:12,alignItems:"center"}},h("span",{style:{flex:1,fontWeight:600}},u2.display_name||u2.username||u2.id),h("span",{style:{color:DIM,width:90}},"@"+(u2.username||"")),h("span",{style:{color:"#FDCB6E",width:60,textAlign:"right"}},(u2.points||0)+"pts"),h("span",{style:{color:DIM,width:90,textAlign:"right"}},u2.level||u2.role||""));})):
      h("div",{style:{background:SURF,border:"1px solid "+BRD,borderRadius:10,overflow:"hidden"}},(adminData.maps||[]).slice(0,300).map(function(m,i){return h("div",{key:m.id||i,style:{display:"flex",gap:10,padding:"8px 12px",borderBottom:i<(adminData.maps.length-1)?"1px solid "+BRD:"none",fontSize:12,alignItems:"center"}},h("span",{style:{flex:1,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}},m.title||m.filename||m.id),h("span",{style:{color:m.status==='confirmed'?'#51CF66':DIM,width:80}},m.status||""),h("span",{style:{color:DIM,width:110,textAlign:"right"}},fmtDate(m.created_at)));})))
  ):null;

  /* ── Account ── */
  var accountView=view==='account'?h("div",{key:"ac",style:{flex:1,padding:28,maxWidth:600,margin:"0 auto",overflowY:"auto"}},
    user?(function(){var lp=levelProgress(user.points);var nConf=acctMaps.filter(function(m){return m.status==='confirmed';}).length;var initial=(user.display_name||user.username||"?").charAt(0).toUpperCase();
      function card(ch){return h("div",{style:{padding:16,background:SURF,borderRadius:12,border:"1px solid "+BRD,marginBottom:14}},ch);}
      function stat(v,l,c){return h("div",{style:{flex:1,textAlign:"center"}},h("div",{style:{fontSize:22,fontWeight:700,color:c}},v),h("div",{style:{fontSize:11,color:DIM}},l));}
      return h("div",null,
      h("h2",{style:{fontSize:18,fontWeight:600,marginBottom:14}},"Account"),
      /* Profile header */
      card(h("div",{style:{display:"flex",alignItems:"center",gap:14}},
        h("div",{style:{width:54,height:54,borderRadius:"50%",background:"linear-gradient(135deg,#6C5CE7,#00B8A9)",display:"flex",alignItems:"center",justifyContent:"center",fontSize:24,fontWeight:700,color:"#fff",flexShrink:0}},initial),
        h("div",{style:{flex:1,minWidth:0}},
          h("div",{style:{fontSize:18,fontWeight:600}},user.display_name||user.username),
          h("div",{style:{fontSize:12,color:DIM}},"@"+user.username),
          h("div",{style:{display:"flex",alignItems:"center",gap:6,marginTop:4}},
            h("span",{style:{fontSize:11,padding:"2px 10px",borderRadius:10,background:"rgba(94,236,213,0.15)",color:"#5EECD5",fontWeight:600}},lp.name),
            user.created_at?h("span",{style:{fontSize:11,color:DIM}},"Member since "+fmtDate(user.created_at).split(' ')[0]):null)))),
      /* Level progress */
      card(h("div",null,
        h("div",{style:{display:"flex",justifyContent:"space-between",fontSize:12,marginBottom:6}},h("span",{style:{color:MUT}},(user.points||0)+" points"),lp.next?h("span",{style:{color:DIM}},lp.pct+"% to "+lp.next+" ("+lp.nextAt+")"):h("span",{style:{color:"#FDCB6E"}},"Top level reached")),
        h("div",{style:{height:8,background:BG,borderRadius:6,overflow:"hidden"}},h("div",{style:{width:lp.pct+"%",height:"100%",background:"linear-gradient(90deg,#6C5CE7,#00B8A9)",borderRadius:6}})))),
      /* Stats */
      card(h("div",{style:{display:"flex",gap:8}},stat(acctMaps.length,"Maps","#A29BFE"),stat(nConf,"Confirmed","#51CF66"),stat(acctFavs.length,"Favorites","#FD79A8"),stat(user.points||0,"Points","#FDCB6E"))),
      /* Edit profile */
      card(h("div",null,
        h("h3",{style:{fontSize:15,fontWeight:600,marginBottom:10}},"Edit profile"),
        h("div",{style:{fontSize:12,color:DIM,marginBottom:4}},"Display name"),
        h("input",{value:edn,onChange:function(e){setEdn(e.target.value);setAcctSaved(false);},style:{width:"100%",padding:"8px 12px",background:BG,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:14,marginBottom:10,fontFamily:"inherit"}}),
        h("div",{style:{fontSize:12,color:DIM,marginBottom:4}},"Bio"),
        h("textarea",{value:ebio,onChange:function(e){setEbio(e.target.value);setAcctSaved(false);},rows:3,placeholder:"A little about you...",style:{width:"100%",padding:"8px 12px",background:BG,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:14,marginBottom:10,fontFamily:"inherit",resize:"vertical"}}),
        h("div",{style:{fontSize:12,color:DIM,marginBottom:4}},"Language"),
        h("select",{value:elang,onChange:function(e){setElang(e.target.value);setAcctSaved(false);},style:{width:"100%",padding:"8px 12px",background:BG,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:14,marginBottom:12,fontFamily:"inherit"}},[["en","English"],["zh","中文"],["es","Español"],["fr","Français"],["de","Deutsch"],["ja","日本語"],["ko","한국어"]].map(function(o){return h("option",{key:o[0],value:o[0],style:{background:BG,color:TXT}},o[1]);})),
        h("button",{onClick:function(){updateProfile(edn,ebio,palName,elang).then(function(){setAcctSaved(true);getMe().then(function(r){if(r.user)setUser(r.user);});});},style:Object.assign({width:"100%"},B())},acctSaved?"Saved ✓":"Save changes"))),
      /* Appearance */
      card(h("div",null,
        h("h3",{style:{fontSize:15,fontWeight:600,marginBottom:10}},"Appearance"),
        h("div",{style:{display:"flex",justifyContent:"space-between",alignItems:"center",marginBottom:10}},h("span",{style:{fontSize:13}},"Theme"),h("button",{onClick:function(){var n=isDark?'notion':'aurora';setPalName(n);localStorage.setItem("mycel_palette",n);},style:B(DIM,"transparent")},isDark?"Light":"Dark")),
        h("div",{style:{fontSize:13,marginBottom:6}},"Palette"),
        h("div",{style:{display:"flex",gap:4,flexWrap:"wrap"}},Object.keys(PALETTES).map(function(k){var p=PALETTES[k];return h("div",{key:k,onClick:function(){setPalName(k);localStorage.setItem("mycel_palette",k);},style:{padding:"4px 8px",borderRadius:6,background:palName===k?p.bg:"transparent",border:palName===k?"2px solid "+p.types.theory.a:"1px solid "+BRD,cursor:"pointer",display:"flex",alignItems:"center",gap:6}},h("div",{style:{width:12,height:12,borderRadius:"50%",background:p.types.theory.a}}),h("span",{style:{fontSize:11,color:palName===k?p.text:DIM}},p.name));})))),
      /* Activity */
      acctAct&&acctAct.length?card(h("div",null,
        h("h3",{style:{fontSize:15,fontWeight:600,marginBottom:10}},"Recent activity"),
        acctAct.slice(0,8).map(function(a,i){return h("div",{key:i,style:{display:"flex",justifyContent:"space-between",alignItems:"center",fontSize:12,padding:"5px 0",borderBottom:i<7?"1px solid "+BRD:"none"}},h("span",{style:{color:MUT}},(a.action||"action").replace(/_/g,' ')),h("span",{style:{display:"flex",gap:8,alignItems:"center"}},a.points_delta?h("span",{style:{color:a.points_delta>0?"#51CF66":"#FF6B6B",fontWeight:600}},(a.points_delta>0?"+":"")+a.points_delta):null,h("span",{style:{color:DIM}},fmtDate(a.created_at))));}))):null,
      /* Quick links */
      card(h("div",null,
        h("h3",{style:{fontSize:15,fontWeight:600,marginBottom:10}},"Shortcuts"),
        h("div",{style:{display:"flex",gap:6,flexWrap:"wrap"}},
          h("button",{onClick:function(){setView('library');},style:B()},"My library"),
          h("button",{onClick:function(){setView('community');},style:B(DIM,"transparent")},"Community"),
          h("button",{onClick:function(){setOnboard(true);},style:B(DIM,"transparent")},"Replay intro")))),
      /* Credits */
      card(h("div",null,
        h("h3",{style:{fontSize:15,fontWeight:600,marginBottom:8}},"How points work"),
        h("div",{style:{fontSize:12,color:MUT,lineHeight:1.8}},"Upload +5 · Confirm +10 · Share +15 · Edit +1 · Upvote +3",h("br",null),"Beginner → Experienced (75) → Expert (300) → Professional (1000) → Organizer (5000)"))),
      h("button",{onClick:function(){localStorage.removeItem("mycel_uid");setUser(null);},style:Object.assign({width:"100%"},B("#FF6B6B","rgba(255,107,107,0.1)"))},"Log out"));})():h("div",null,
      h("h2",{style:{fontSize:18,fontWeight:600,marginBottom:14}},authMode==="login"?"Log In":"Create Account"),
      h("input",{value:authU,placeholder:"Username",onChange:function(e){setAuthU(e.target.value);},style:{width:"100%",padding:"10px 14px",background:BG,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:14,marginBottom:8}}),
      authMode==="register"?h("input",{value:authD,placeholder:"Display name (optional)",onChange:function(e){setAuthD(e.target.value);},style:{width:"100%",padding:"10px 14px",background:BG,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:14,marginBottom:8}}):null,
      h("input",{value:authP,placeholder:"Password",type:"password",onChange:function(e){setAuthP(e.target.value);},style:{width:"100%",padding:"10px 14px",background:BG,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:14,marginBottom:12}}),
      h("button",{onClick:function(){(authMode==="login"?login(authU,authP):register(authU,authP,authD||authU)).then(function(d){if(d.user){localStorage.setItem("mycel_uid",d.user.id);setUser(d.user);}else if(d.user_id){localStorage.setItem("mycel_uid",d.user_id);getMe().then(function(r){if(r.user)setUser(r.user);});}else alert(d.error||"Failed");});},style:Object.assign({width:"100%",marginBottom:8},B())},authMode==="login"?"Log In":"Create Account"),
      h("button",{onClick:function(){setAuthMode(authMode==="login"?"register":"login");},style:Object.assign({width:"100%"},B(DIM,"transparent"))},authMode==="login"?"Need an account? Register":"Have an account? Log in"))
  ):null;

  /* ── Graph (with split mode) ── */
  var graphGuts=view==='graph'?[
    h("div",{key:"dots",style:{position:"absolute",inset:0,zIndex:0,pointerEvents:"none",backgroundImage:"radial-gradient(circle,"+P.dot+" 1px,transparent 1px)",backgroundSize:Math.max(16,26*cam.z)+"px "+Math.max(16,26*cam.z)+"px",backgroundPosition:(cam.x%(26*cam.z))+"px "+(cam.y%(26*cam.z))+"px"}}),
    h("svg",{key:"svg",ref:svgRef,style:{position:"absolute",inset:0,width:"100%",height:"100%",zIndex:1,overflow:"visible"}},
      h("defs",null,h("marker",{id:"ah",viewBox:"0 0 12 12",refX:"11",refY:"6",markerWidth:"7",markerHeight:"7",orient:"auto"},h("path",{d:"M1 2L10 6L1 10",fill:"none",stroke:"context-stroke",strokeWidth:"1.5",strokeLinecap:"round"}))),
      drawings.map(function(dr,i){if(dr.points.length<2)return null;var d2='M'+dr.points[0].x+' '+dr.points[0].y;for(var j=1;j<dr.points.length;j++)d2+='L'+dr.points[j].x+' '+dr.points[j].y;return h("path",{key:"dr"+i,d:d2,fill:"none",stroke:dr.color,strokeWidth:dr.width/cam.z,opacity:0.7,strokeLinecap:"round",transform:"translate("+cam.x+","+cam.y+") scale("+cam.z+")"});}),
      drawPath&&drawPath.points.length>1?(function(){var d2='M'+drawPath.points[0].x+' '+drawPath.points[0].y;for(var j=1;j<drawPath.points.length;j++)d2+='L'+drawPath.points[j].x+' '+drawPath.points[j].y;return h("path",{key:"adp",d:d2,fill:"none",stroke:drawPath.color,strokeWidth:drawPath.width/cam.z,opacity:0.7,strokeLinecap:"round",transform:"translate("+cam.x+","+cam.y+") scale("+cam.z+")"});})():null,
      hulls.map(function(hl){return h("path",{key:hl.key,d:hl.d,fill:P.hullFill,stroke:P.hullStroke,strokeWidth:1,transform:"translate("+cam.x+","+cam.y+") scale("+cam.z+")"});}),
      cards.map(function(c){var sx=c.x*cam.z+cam.x,sy=c.y*cam.z+cam.y;return h("g",{key:c.id,transform:"translate("+sx+","+sy+") scale("+cam.z+")",style:{cursor:tool==='select'?"move":"inherit"},
        onPointerDown:function(ev){if(tool!=='select')return;ev.stopPropagation();setSel(null);var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;setDrag({t:'card',cid:c.id,sx:ev.clientX-rc.left,sy:ev.clientY-rc.top,ox:c.x,oy:c.y});ev.preventDefault();}},
        h("rect",{x:-c.w/2-4,y:-c.h/2-4,width:c.w+8,height:c.h+8,rx:10,fill:SURF,stroke:BRD,strokeWidth:1}),
        h("image",{href:c.src,xlinkHref:c.src,x:-c.w/2,y:-c.h/2,width:c.w,height:c.h,preserveAspectRatio:"xMidYMid meet",style:{pointerEvents:"none"}}),
        h("g",{transform:"translate("+(c.w/2)+","+(-c.h/2)+")",style:{cursor:"pointer"},onPointerDown:function(ev){ev.stopPropagation();setData(function(dd){return Object.assign({},dd,{cards:(dd.cards||[]).filter(function(x){return x.id!==c.id;})});});}},h("circle",{r:9,fill:"#FF6B6B"}),h("path",{d:"M-3 -3L3 3M3 -3L-3 3",stroke:"#fff",strokeWidth:1.6,strokeLinecap:"round"})));}),
      Object.keys(ep).map(function(k){return ep[k];}).reduce(function(a,b){return a.concat(b);},[]).map(function(e,i){var s=nm[e.source],t=nm[e.target];if(!s||!t)return null;var cat=edgeCat(e.relation_type),st=P.edges[cat]||P.edges.custom;var thick=st.w*(0.5+(e.confidence||0.5)*0.5);var hi=selId===e.source||selId===e.target||hovId===e.source||hovId===e.target;var path=(cat==='compositional'||cat==='pedagogical')?sPath(s.x,s.y,t.x,t.y):edgePath(s.x,s.y,t.x,t.y,e.idx,ep[[e.source,e.target].sort().join('|')].length);var tr="translate("+cam.x+","+cam.y+") scale("+cam.z+")";var dash=lineMode==='solid'?"":(lineMode==='dashed'?"9 5":st.dash);return h("g",{key:"e"+i},hi?h("path",{d:path,fill:"none",stroke:st.color,strokeWidth:thick+7,opacity:0.12,transform:tr}):null,h("path",{d:path,fill:"none",stroke:st.color,strokeWidth:hi?thick*1.5:thick,strokeDasharray:dash,opacity:hi?0.9:0.55,transform:tr,strokeLinecap:"round",markerEnd:(arrowsOn&&ARROW_CATS.has(cat))?"url(#ah)":""}));}),
      linkFrom&&linkPos&&nm[linkFrom]?h("path",{key:"linkline",d:"M"+nm[linkFrom].x+" "+nm[linkFrom].y+" L"+linkPos.x+" "+linkPos.y,fill:"none",stroke:"#A29BFE",strokeWidth:2,strokeDasharray:"6 5",opacity:0.85,transform:"translate("+cam.x+","+cam.y+") scale("+cam.z+")"}):null,
      vn.map(function(n){var t=tcolor(n.concept_type);var isSel=selId===n.id,isHov=hovId===n.id;var dl=showD?(n.dl||[]):[];var totalH=(n.lh||30)+(dl.length?dl.length*16+20:0);var sx2=n.x*cam.z+cam.x,sy2=n.y*cam.z+cam.y;var lSz=Math.round(impSize(n.id,14)*fontScale),dSz=Math.round(impSize(n.id,10)*fontScale);var shp=shapeForType(n.concept_type);var sbox=shapeBox(shp,n.w,totalH);
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
    selN?(function(){var sc=w2s(selN.x,selN.y);var t=tcolor(selN.concept_type);var rc=cRef.current?cRef.current.getBoundingClientRect():{width:800};var cW=260;var cx2=Math.min(Math.max(8,sc.x+70),rc.width-cW-12);var cy2=Math.max(8,sc.y-40);
      return h("div",{key:"dc", onPointerDown:function(e){e.stopPropagation();}, style:{position:"absolute",left:cx2,top:cy2,width:cW,background:SURF,border:"1px solid "+BRD,borderRadius:12,padding:"12px 14px",boxShadow:"0 6px 24px rgba(0,0,0,0.25)",zIndex:20,maxHeight:"50vh",overflowY:"auto"}},
        h("div",{style:{display:"flex",alignItems:"center",gap:4,marginBottom:4}},h("div",{style:{width:7,height:7,borderRadius:"50%",background:t.a}}),
          h("select",{value:selN.concept_type,onChange:function(ev){ev.stopPropagation();setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(nd){return nd.id!==selId?nd:Object.assign({},nd,{concept_type:ev.target.value});})});});},style:{fontSize:11,color:t.a,fontWeight:600,textTransform:"uppercase",background:"transparent",border:"1px solid "+t.a+"30",borderRadius:4,padding:"1px 4px",cursor:"pointer"}},allTypes.map(function(ct){return h("option",{key:ct,value:ct,style:{background:BG,color:TXT}},ct);})),
          h("span",{style:{fontSize:11,color:DIM,marginLeft:"auto"}},Math.round((selN.confidence||0)*100)+"%"),
          h("button",{onClick:function(e){e.stopPropagation();setSel(null);},style:{background:"none",border:"none",color:DIM,fontSize:14,cursor:"pointer",padding:"0 2px"}},"×")),
        editField==='label'?h("input",{value:editVal,onChange:function(e){setEv(e.target.value);},autoFocus:true,onBlur:function(){setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(nd){if(nd.id!==selId)return nd;var up=Object.assign({},nd,{label:editVal});return Object.assign(up,nSize(up));})});});setEf(null);},onKeyDown:function(e){if(e.key==='Enter')e.target.blur();if(e.key==='Escape')setEf(null);},style:{width:"100%",fontSize:15,fontWeight:600,background:BG,border:"1px solid "+t.a+"50",borderRadius:6,color:t.a,padding:"3px 6px",marginBottom:4,fontFamily:"inherit"}}):
          h("h3",{onClick:function(e){e.stopPropagation();setEf('label');setEv(selN.label);},style:{fontSize:15,fontWeight:600,marginBottom:4,cursor:"text",color:t.a}},selN.label),
        editField==='desc'?h("textarea",{value:editVal,onChange:function(e){setEv(e.target.value);},rows:3,autoFocus:true,onBlur:function(){setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(nd){if(nd.id!==selId)return nd;var up=Object.assign({},nd,{description:editVal});return Object.assign(up,nSize(up));})});});setEf(null);},style:{width:"100%",fontSize:13,background:BG,border:"1px solid "+t.a+"50",borderRadius:6,color:t.s,padding:"4px 6px",marginBottom:6,fontFamily:"inherit",lineHeight:1.4,resize:"vertical"}}):
          h("p",{onClick:function(e){e.stopPropagation();setEf('desc');setEv(selN.description||'');},style:{fontSize:13,color:t.s,lineHeight:1.5,marginBottom:6,cursor:"text"}},selN.description||"Click to add description"),
        editField==='note'?h("textarea",{value:editVal,onChange:function(e){setEv(e.target.value);},rows:3,autoFocus:true,placeholder:"Your own notes, questions, links…",onBlur:function(){setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(nd){if(nd.id!==selId)return nd;return Object.assign({},nd,{note:editVal});})});});setEf(null);},style:{width:"100%",fontSize:12,background:BG,border:"1px solid "+t.a+"50",borderRadius:6,color:TXT,padding:"6px 8px",marginBottom:6,fontFamily:"inherit",lineHeight:1.4,resize:"vertical"}}):
          h("div",{onClick:function(e){e.stopPropagation();setEf('note');setEv(selN.note||'');},style:{fontSize:12,color:selN.note?TXT:DIM,lineHeight:1.5,marginBottom:6,cursor:"text",padding:"6px 8px",background:BG,borderRadius:6,border:"1px dashed "+BRD}},selN.note?selN.note:"+ Add note"),
        h("div",{style:{display:"flex",gap:4,marginBottom:6}},h("button",{onClick:function(){submitCorrection({map_id:mapId,type:"approve",original:{id:selId}});},style:B("#51CF66","rgba(81,207,102,0.1)")},"✓"),h("button",{onClick:function(e){e.stopPropagation();setTool('link');setLinkFrom(selId);setLinkPos(null);},style:B("#74B9FF","rgba(116,185,255,0.1)")},"Link"),h("button",{onClick:function(){setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.filter(function(nd){return nd.id!==selId;}),edges:dd.edges.filter(function(ed){return ed.source!==selId&&ed.target!==selId;})});});setSel(null);},style:B("#FF6B6B","rgba(255,107,107,0.1)")},"✗")),
        connE.length>0?h("div",null,h("div",{style:{fontSize:11,color:DIM,fontWeight:600,marginBottom:3}},"Connections ("+connE.length+")"),connE.slice(0,8).map(function(e,i){var isSrc=e.source===selId,oId=isSrc?e.target:e.source,o=nm[oId];var cat=edgeCat(e.relation_type),es=P.edges[cat]||P.edges.custom;return h("div",{key:i,style:{display:"flex",alignItems:"center",gap:4,padding:"4px 6px",background:BG,borderRadius:4,marginBottom:2,borderLeft:"2px solid "+es.color,fontSize:11}},
          h("select",{value:e.relation_type,onPointerDown:function(ev){ev.stopPropagation();},onChange:function(ev){ev.stopPropagation();var nt=ev.target.value;setData(function(dd){return Object.assign({},dd,{edges:dd.edges.map(function(ed){if(ed.source===e.source&&ed.target===e.target&&ed.relation_type===e.relation_type)return Object.assign({},ed,{relation_type:nt});return ed;})});});},style:{fontSize:9,fontWeight:600,textTransform:"uppercase",color:es.color,background:"transparent",border:"1px solid "+es.color+"40",borderRadius:4,padding:"1px 2px",cursor:"pointer",maxWidth:96}},relTypes.map(function(rt){return h("option",{key:rt,value:rt,style:{background:BG,color:TXT}},rt.replace(/_/g,' '));})),
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
        [["Academic","aurora",1,"category"],["Neon","tokyo",1,"category"],["Minimal","notion",0,"solid"],["Nordic","nord",1,"category"],["Warm","paper",1,"category"],["Cool","ice",1,"category"],["Bold","dracula",1,"category"]].map(function(pr){return h("button",{key:pr[0],onClick:function(){setPalName(pr[1]);localStorage.setItem("mycel_palette",pr[1]);var so=pr[2]===1;setShapesOn(so);localStorage.setItem("mycel_shapes",so?"1":"0");setLineMode(pr[3]);localStorage.setItem("mycel_linemode",pr[3]);},style:{padding:"3px 8px",borderRadius:4,fontSize:10,cursor:"pointer",background:palName===pr[1]?"rgba(162,155,254,0.15)":"transparent",border:"1px solid "+(palName===pr[1]?"rgba(162,155,254,0.3)":BRD),color:palName===pr[1]?"#A29BFE":DIM}},pr[0]);})),
      h("div",{style:{fontSize:12,fontWeight:600,color:DIM,margin:"14px 0 4px"}},"MAP QUALITY  "+qm.score+"/100"),
      h("div",{style:{height:7,background:BG,borderRadius:6,overflow:"hidden",marginBottom:6}},h("div",{style:{width:qm.score+"%",height:"100%",background:qm.score>66?"#51CF66":qm.score>33?"#FDCB6E":"#FF6B6B",borderRadius:6}})),
      [["Clarity",qm.clarity],["Integration",qm.integration],["Hierarchy",qm.hierarchy],["Grounding",qm.grounding],["Parsimony",qm.parsimony]].map(function(r){return h("div",{key:r[0],style:{display:"flex",alignItems:"center",gap:6,marginBottom:3}},h("span",{style:{fontSize:10,color:MUT,width:74}},r[0]),h("div",{style:{flex:1,height:5,background:BG,borderRadius:5,overflow:"hidden"}},h("div",{style:{width:Math.round(r[1]*100)+"%",height:"100%",background:"#A29BFE"}})));}),
      h("div",{style:{fontSize:10,color:MUT,lineHeight:1.5,margin:"4px 0 12px"}},qm.hint),
      h("div",{style:{fontSize:12,fontWeight:600,color:DIM,marginBottom:6}},"EXPORT"),
      h("div",{style:{display:"flex",gap:4,marginBottom:14}},
        h("button",{onClick:exportPNG,style:Object.assign({flex:1,padding:"5px 0"},B(DIM,"transparent"))},"PNG"),
        h("button",{onClick:exportSVG,style:Object.assign({flex:1,padding:"5px 0"},B(DIM,"transparent"))},"SVG"),
        h("button",{onClick:function(){if(mapId)exportMap(mapId);},style:Object.assign({flex:1,padding:"5px 0"},B(DIM,"transparent"))},"JSON")),
      h("div",{style:{fontSize:12,fontWeight:600,color:DIM,marginBottom:6}},"CUSTOM CONCEPT TYPES"),
      customTypes.length?h("div",{style:{display:"flex",flexWrap:"wrap",gap:4,marginBottom:6}},customTypes.map(function(c){return h("span",{key:c.name,style:{display:"inline-flex",alignItems:"center",gap:4,fontSize:10,padding:"2px 6px",borderRadius:10,background:c.color+"22",color:c.color}},c.name,h("span",{onClick:function(){setCustomTypes(customTypes.filter(function(x){return x.name!==c.name;}));},style:{cursor:"pointer"}},"×"));})):null,
      h("div",{style:{display:"flex",gap:4,marginBottom:12}},
        h("input",{value:ntName,placeholder:"e.g. axiom",onChange:function(e){setNtName(e.target.value);},style:{flex:1,minWidth:0,padding:"4px 6px",background:BG,border:"1px solid "+BRD,borderRadius:5,color:TXT,fontSize:11,fontFamily:"inherit"}}),
        h("input",{type:"color",value:ntColor,onChange:function(e){setNtColor(e.target.value);},style:{width:28,height:26,padding:0,border:"1px solid "+BRD,borderRadius:5,background:"transparent",cursor:"pointer"}}),
        h("button",{onClick:function(){var n=ntName.trim().toLowerCase().replace(/\s+/g,'_');if(!n)return;if(BASE_TYPES.indexOf(n)>=0||customTypes.some(function(x){return x.name===n;})){setNtName("");return;}setCustomTypes(customTypes.concat([{name:n,color:ntColor}]));setNtName("");},style:B()},"Add")),
      h("div",{style:{fontSize:12,fontWeight:600,color:DIM,marginBottom:6}},"CUSTOM RELATION TYPES"),
      customRels.length?h("div",{style:{display:"flex",flexWrap:"wrap",gap:4,marginBottom:6}},customRels.map(function(r){return h("span",{key:r,style:{display:"inline-flex",alignItems:"center",gap:4,fontSize:10,padding:"2px 6px",borderRadius:10,background:BG,color:MUT}},r.replace(/_/g,' '),h("span",{onClick:function(){setCustomRels(customRels.filter(function(x){return x!==r;}));},style:{cursor:"pointer"}},"×"));})):null,
      h("div",{style:{display:"flex",gap:4}},
        h("input",{value:nrName,placeholder:"e.g. REFUTES",onChange:function(e){setNrName(e.target.value);},style:{flex:1,minWidth:0,padding:"4px 6px",background:BG,border:"1px solid "+BRD,borderRadius:5,color:TXT,fontSize:11,fontFamily:"inherit"}}),
        h("button",{onClick:function(){var n=nrName.trim().toUpperCase().replace(/\s+/g,'_');if(!n)return;if(relTypes.indexOf(n)>=0){setNrName("");return;}setCustomRels(customRels.concat([n]));setNrName("");},style:B()},"Add"))
    ):null,
    /* Search */
    showSearch?h("div",{key:"srch",style:{position:"absolute",top:8,left:"50%",transform:"translateX(-50%)",width:280,background:SURF,border:"1px solid "+BRD,borderRadius:10,padding:10,boxShadow:"0 6px 24px rgba(0,0,0,0.2)",zIndex:26}},
      h("div",{style:{display:"flex",alignItems:"center",gap:6,marginBottom:6}},
        h("span",{style:{color:DIM,display:"inline-flex"}},IC('search',14)),
        h("input",{value:query,autoFocus:true,placeholder:"Find a concept…",onChange:function(e){setQuery(e.target.value);},style:{flex:1,background:"transparent",border:"none",outline:"none",color:TXT,fontSize:13,fontFamily:"inherit"}}),
        h("button",{onClick:function(){setShowSearch(false);setQuery("");},style:{background:"none",border:"none",color:DIM,cursor:"pointer",display:"inline-flex"}},IC('close',14))),
      (function(){var q=query.trim().toLowerCase();if(!q)return h("div",{style:{fontSize:11,color:DIM}},"Type to search "+vn.length+" concepts");var res=vn.filter(function(n){return(n.label||'').toLowerCase().indexOf(q)>=0||(n.description||'').toLowerCase().indexOf(q)>=0;}).slice(0,8);if(!res.length)return h("div",{style:{fontSize:11,color:DIM}},"No matches");return h("div",{style:{maxHeight:200,overflowY:"auto"}},res.map(function(n){var tc=tcolor(n.concept_type);return h("div",{key:n.id,onClick:function(){zoomTo(n.id);},style:{display:"flex",alignItems:"center",gap:6,padding:"5px 6px",borderRadius:6,cursor:"pointer",background:selId===n.id?BG:"transparent"}},h("div",{style:{width:7,height:7,borderRadius:"50%",background:tc.a,flexShrink:0}}),h("span",{style:{fontSize:12,color:TXT,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}},n.label));}));})()
    ):null,
    /* Zoom */
    h("div",{key:"zm",style:{position:"absolute",bottom:10,right:10,display:"flex",alignItems:"center",gap:3,background:SURF+"EE",backdropFilter:"blur(8px)",padding:"4px 8px",borderRadius:8,border:"1px solid "+BRD,zIndex:5}},
      h("button",{onClick:function(){setCam(function(c){var rc=cRef.current?cRef.current.getBoundingClientRect():{width:800,height:600};var cx=rc.width/2,cy=rc.height/2;var nz=Math.max(0.15,c.z/1.3);return{x:cx-(cx-c.x)*(nz/c.z),y:cy-(cy-c.y)*(nz/c.z),z:nz};});},style:{width:32,height:32,borderRadius:6,background:"transparent",border:"1px solid "+BRD,color:TXT,fontSize:16,cursor:"pointer",display:"flex",alignItems:"center",justifyContent:"center"}},"−"),
      h("div",{style:{fontSize:11,color:DIM,width:40,textAlign:"center",cursor:"pointer"},onClick:function(){setCam(function(c){return{x:c.x,y:c.y,z:1};});}},Math.round(cam.z*100)+"%"),
      h("button",{onClick:function(){setCam(function(c){var rc=cRef.current?cRef.current.getBoundingClientRect():{width:800,height:600};var cx=rc.width/2,cy=rc.height/2;var nz=Math.min(5,c.z*1.3);return{x:cx-(cx-c.x)*(nz/c.z),y:cy-(cy-c.y)*(nz/c.z),z:nz};});},style:{width:32,height:32,borderRadius:6,background:"transparent",border:"1px solid "+BRD,color:TXT,fontSize:16,cursor:"pointer",display:"flex",alignItems:"center",justifyContent:"center"}},"+"),
      h("button",{title:"Fit to view",onClick:function(){fit(nodes);},style:{width:32,height:32,borderRadius:6,background:"transparent",border:"1px solid "+BRD,color:DIM,fontSize:12,cursor:"pointer",display:"flex",alignItems:"center",justifyContent:"center"}},IC('fit',16)))
  ]:[];

  var graphProps={ref:cRef,style:{flex:1,position:"relative",overflow:"hidden",cursor:cursor},onPointerDown:onDown,onPointerMove:onMove,onPointerUp:onUp,onPointerLeave:onUp,onWheel:onWheel,onDoubleClick:onDbl,onDrop:onCanvasDrop,onDragOver:function(e){e.preventDefault();}};
  var graphView=view==='graph'?(
    referMode&&mapId
      ?(splitRight==='list'
        ?h("div",{key:"splist",style:{display:"flex",flex:1,overflow:"hidden"}},
          h(PDFViewer,{pdfUrl:apiUrl()+"/api/maps/"+mapId+"/pdf",pdfFile:uploadedFile,nodes:vn,edges:ve,palette:P,selectedId:selId,onSelectConcept:function(id){setSel(id);zoomTo(id);},onClose:function(){setRefer(false);},darkMode:isDark,panel:"both"}))
        :h("div",{key:"sp",style:{display:"flex",flex:1,overflow:"hidden"}},
          h("div",{style:{flex:"0 0 50%",overflow:"hidden",borderRight:"1px solid "+BRD}},
            h(PDFViewer,{pdfUrl:apiUrl()+"/api/maps/"+mapId+"/pdf",pdfFile:uploadedFile,nodes:vn,edges:ve,palette:P,selectedId:selId,onSelectConcept:function(id){setSel(id);zoomTo(id);},onClose:function(){setRefer(false);},darkMode:isDark,panel:"pdf"})),
          h("div",Object.assign({key:"gr2"},graphProps),graphGuts)))
      :h("div",Object.assign({key:"gr"},graphProps),graphGuts)
  ):null;

  /* ════════════════════════════════════════════════════ */
  return h("div",{style:{height:"100vh",display:"flex",flexDirection:"column",background:BG,color:TXT,fontFamily:"'Inter',system-ui,sans-serif"}},
    onboardView,headerView,homeView,libraryView,communityView,helpView,palaceView,adminView,accountView,graphView);
}
