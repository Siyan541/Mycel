#!/bin/bash
set -e
echo "🍄 Mycel — Complete frontend + backend fix..."

# Fix Together.ai extraction quality
cat > backend/app/services/llm.py << 'PYEOF'
import os, json, logging, httpx
from backend.app.config import LLM_PROVIDER, LLM_MODEL, TOGETHER_API_KEY, TOGETHER_MODEL
logger = logging.getLogger(__name__)

def chat(messages, json_schema=None, temperature=0.1, max_tokens=1500):
    if LLM_PROVIDER == "together":
        return _together(messages, json_schema, temperature, max_tokens)
    return _ollama(messages, json_schema, temperature, max_tokens)

def _ollama(messages, schema, temp, max_tok):
    import ollama as ol
    kw = {"model": LLM_MODEL, "messages": messages,
          "options": {"temperature": temp, "num_ctx": 4096, "num_predict": max_tok}}
    if schema: kw["format"] = schema
    return ol.chat(**kw).message.content

def _together(messages, schema, temp, max_tok):
    body = {"model": TOGETHER_MODEL, "messages": messages,
            "temperature": temp, "max_tokens": max_tok}
    if schema:
        body["response_format"] = {"type": "json_object"}
    with httpx.Client(timeout=120) as c:
        r = c.post("https://api.together.xyz/v1/chat/completions",
            headers={"Authorization": f"Bearer {TOGETHER_API_KEY}"},
            json=body)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]
PYEOF
echo "  ✓ llm.py — json_object mode for Together.ai"

# Write complete App.jsx
cat > frontend/src/App.jsx << 'JSXEOF'
import React,{useState,useMemo,useCallback,useRef,useEffect,useReducer} from"react";
import{uploadPDF,getMaps,getMap,deleteMap,submitCorrection,confirmMap,unconfirmMap,shareMap,getCommunityMaps,upvoteCommunityMap,register,login,getMe,getActivity,getLeaderboard}from"./api";
import{PALETTES,edgeCat,typeColor,ARROW_CATS}from"./utils/theme";
import{organicLayout,edgePath,sPath,wrap,nSize,convexHull,hullPath,getNeighbors}from"./utils/layout";

function histR(s,a){switch(a.type){case'SET':{var p=s.past.concat([s.present]);if(p.length>40)p=p.slice(-40);return{past:p,present:a.data,future:[]};}case'UNDO':{if(!s.past.length)return s;return{past:s.past.slice(0,-1),present:s.past[s.past.length-1],future:[s.present].concat(s.future).slice(0,40)};}case'REDO':{if(!s.future.length)return s;return{past:s.past.concat([s.present]),present:s.future[0],future:s.future.slice(1)};}case'INIT':return{past:[],present:a.data,future:[]};default:return s;}}

var h=React.createElement;
var BS=function(c,bg){return{padding:"8px 16px",background:bg||"rgba(162,155,254,0.1)",border:"1px solid "+(c||"rgba(162,155,254,0.25)"),borderRadius:8,color:c||"#A29BFE",fontSize:13,fontWeight:500,cursor:"pointer",fontFamily:"inherit"};};

export default function App(){
var init={nodes:[],edges:[],drawings:[]};
var hr=useReducer(histR,{past:[],present:init,future:[]});
var hist=hr[0],dispatch=hr[1];
var D=hist.present,nodes=D.nodes,edges=D.edges,drawings=D.drawings||[];
var setData=useCallback(function(fn){dispatch({type:'SET',data:typeof fn==='function'?fn(hist.present):fn});},[hist.present]);
var undo=useCallback(function(){dispatch({type:'UNDO'});},[]);
var redo=useCallback(function(){dispatch({type:'REDO'});},[]);

var vs=useState,pal=vs("aurora"),view=vs("home"),sel=vs(null),hov=vs(null),
mapId=vs(null),maps=vs([]),upl=vs(false),prog=vs(null),coll=vs(new Set()),
ef=vs(null),ev=vs(''),cam=vs({x:0,y:0,z:0.75}),drag=vs(null),
tool=vs('select'),dp=vs(null),dc=vs('#A29BFE'),
user=vs(null),cmaps=vs([]),shareM=vs(null),shareDom=vs("general"),commDom=vs("all"),
authMode=vs("login"),authU=vs(""),authP=vs(""),linkMode=vs(false),linkSrc=vs(null);

var P=PALETTES[pal[0]];
var cRef=useRef(null),fRef=useRef(null);

// Load user
useEffect(function(){var uid=localStorage.getItem("mycel_uid");
if(uid)getMe().then(function(d){if(d.user)user[1](d.user);}).catch(function(){});},[]);

// View effects
useEffect(function(){
if(view[0]==="library")getMaps().then(function(d){maps[1](d.maps||[]);}).catch(function(){});
if(view[0]==="community")getCommunityMaps("all").then(function(d){cmaps[1](d.maps||[]);}).catch(function(){});
},[view[0]]);

// Keyboard
useEffect(function(){var fn=function(e){if(e.target.tagName==='INPUT'||e.target.tagName==='TEXTAREA')return;
if((e.metaKey||e.ctrlKey)&&e.key==='z'&&!e.shiftKey){e.preventDefault();undo();}
if((e.metaKey||e.ctrlKey)&&(e.key==='y'||(e.key==='z'&&e.shiftKey))){e.preventDefault();redo();}
if(e.key==='Escape'){sel[1](null);tool[1]('select');}
if(e.key==='Delete'&&sel[0]){setData(function(dd){return{nodes:dd.nodes.filter(function(n){return n.id!==sel[0];}),edges:dd.edges.filter(function(ed){return ed.source!==sel[0]&&ed.target!==sel[0];}),drawings:dd.drawings};});sel[1](null);}
};window.addEventListener('keydown',fn);return function(){window.removeEventListener('keydown',fn);};},[undo,redo,sel[0],setData]);

var fit=useCallback(function(nl){if(!cRef.current||!nl||!nl.length)return;var rc=cRef.current.getBoundingClientRect();
var ax=Infinity,ay=Infinity,bx=-Infinity,by=-Infinity;
for(var i=0;i<nl.length;i++){var r=nl[i].r||60;ax=Math.min(ax,nl[i].x-r);ay=Math.min(ay,nl[i].y-r);bx=Math.max(bx,nl[i].x+r);by=Math.max(by,nl[i].y+r);}
var gw=bx-ax+120,gh=by-ay+120,z=Math.min(rc.width/gw,rc.height/gh,1.4);
cam[1]({x:-(ax-60)*z+(rc.width-gw*z)/2,y:-(ay-60)*z+(rc.height-gh*z)/2,z:z});},[]);

var handleUpload=function(file){if(!file)return;
var ext=file.name.split('.').pop().toLowerCase();
if(['pdf','docx','txt','md','epub'].indexOf(ext)<0)return;
upl[1](true);prog[1]({stage:'uploading',progress:0,message:'Uploading...'});
uploadPDF(file).then(function(r){if(r.nodes){
var edgesN=r.edges.map(function(e){return Object.assign({},e,{source:e.source_id||e.source,target:e.target_id||e.target});});
var laid=organicLayout(r.nodes,edgesN);
dispatch({type:'INIT',data:{nodes:laid,edges:edgesN,drawings:[]}});
mapId[1](r.map_id);view[1]('graph');coll[1](new Set());
setTimeout(function(){fit(laid);},80);
prog[1]({stage:'done',progress:1,message:r.node_count+' concepts, '+r.edge_count+' relations'});
}else{prog[1]({stage:'error',progress:0,message:r.error||'Failed'});}
upl[1](false);}).catch(function(e){prog[1]({stage:'error',progress:0,message:e.message||'Failed'});upl[1](false);});};

var loadMap=function(id){getMap(id).then(function(r){if(r.nodes){
var edgesN=r.edges.map(function(e){return Object.assign({},e,{source:e.source_id||e.source,target:e.target_id||e.target});});
var laid=organicLayout(r.nodes,edgesN);
dispatch({type:'INIT',data:{nodes:laid,edges:edgesN,drawings:[]}});
mapId[1](id);view[1]('graph');coll[1](new Set());setTimeout(function(){fit(laid);},80);
}});};

var loadComm=function(dom){getCommunityMaps(dom).then(function(d){cmaps[1](d.maps||[]);}).catch(function(){cmaps[1]([]);});};

var addNode=function(){if(!cRef.current)return;var center={x:(cRef.current.clientWidth/2-cam[0].x)/cam[0].z,y:(cRef.current.clientHeight/2-cam[0].y)/cam[0].z};
var nn={id:'n_'+Date.now(),label:'New Concept',description:'Click to edit',concept_type:'term',abstraction_level:1,confidence:0.5,cluster:'custom',x:center.x,y:center.y};
Object.assign(nn,nSize(nn));
setData(function(d){return{nodes:d.nodes.concat([nn]),edges:d.edges,drawings:d.drawings};});sel[1](nn.id);};

// Derived
var nm=useMemo(function(){var m={};nodes.forEach(function(n){m[n.id]=n;});return m;},[nodes]);
var allL=useMemo(function(){return nodes.map(function(n){return n.label;});},[nodes]);
var ch=useMemo(function(){var c={};edges.forEach(function(e){if(!c[e.source])c[e.source]=[];c[e.source].push(e.target);});return c;},[edges]);
var deg=useMemo(function(){var d={};edges.forEach(function(e){d[e.source]=(d[e.source]||0)+1;d[e.target]=(d[e.target]||0)+1;});return d;},[edges]);
var visIds=useMemo(function(){if(!coll[0].size)return new Set(nodes.map(function(n){return n.id;}));var hidden=new Set();coll[0].forEach(function(cid){var q=(ch[cid]||[]).slice();while(q.length){var id=q.shift();if(!hidden.has(id)){hidden.add(id);if(!coll[0].has(id))(ch[id]||[]).forEach(function(c2){q.push(c2);});}}});return new Set(nodes.filter(function(n){return!hidden.has(n.id);}).map(function(n){return n.id;}));},[nodes,coll[0],ch]);
var vn=useMemo(function(){return nodes.filter(function(n){return visIds.has(n.id);});},[nodes,visIds]);
var ve=useMemo(function(){return edges.filter(function(e){return visIds.has(e.source)&&visIds.has(e.target);});},[edges,visIds]);
var hulls=useMemo(function(){var g={};vn.forEach(function(n){var c=n.cluster||'x';if(!g[c])g[c]=[];g[c].push(n);});return Object.keys(g).filter(function(k){return g[k].length>=2;}).map(function(k){return{key:k,d:hullPath(convexHull(g[k].map(function(n2){return{x:n2.x,y:n2.y};})),45)};});},[vn]);
var ep=useMemo(function(){var p={};ve.forEach(function(e){var k=[e.source,e.target].sort().join('|');if(!p[k])p[k]=[];p[k].push(Object.assign({},e,{idx:p[k].length}));});return p;},[ve]);

var s2w=useCallback(function(sx,sy){return{x:(sx-cam[0].x)/cam[0].z,y:(sy-cam[0].y)/cam[0].z};},[cam[0]]);
var w2s=useCallback(function(wx,wy){return{x:wx*cam[0].z+cam[0].x,y:wy*cam[0].z+cam[0].y};},[cam[0]]);
var findT=useCallback(function(desc,skip){if(!desc)return[];var f=[];allL.forEach(function(lb){if(lb===skip||lb.length<3)return;if(desc.toLowerCase().indexOf(lb.toLowerCase())>=0)f.push(lb);});return f.slice(0,4);},[allL]);

// Pointer handlers
var onDown=useCallback(function(e){if(e.button!==0)return;var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;
var sx=e.clientX-rc.left,sy=e.clientY-rc.top,w=s2w(sx,sy);
if(tool[0]==='draw'){dp[1]({color:dc[0],points:[{x:w.x,y:w.y}],width:2});e.preventDefault();return;}
if(tool[0]==='eraser'){setData(function(dd){return Object.assign({},dd,{drawings:dd.drawings.filter(function(dr){return!dr.points.some(function(pt){return Math.abs(pt.x-w.x)<20&&Math.abs(pt.y-w.y)<20;});})});});return;}
var hit=null;for(var i=0;i<vn.length;i++){var dx=w.x-vn[i].x,dy=w.y-vn[i].y;if(dx*dx+dy*dy<vn[i].r*vn[i].r){hit=vn[i];break;}}
if(hit){var nbrs=getNeighbors(hit.id,edges);var offsets={};Object.keys(nbrs).forEach(function(id){offsets[id]={dx:(nm[id]?nm[id].x:0)-hit.x,dy:(nm[id]?nm[id].y:0)-hit.y};});
drag[1]({t:'c',nid:hit.id,nbrs:nbrs,sx:sx,sy:sy,ox:hit.x,oy:hit.y,off:offsets});e.preventDefault();}
else{drag[1]({t:'p',sx:sx,sy:sy,cx:cam[0].x,cy:cam[0].y});}
},[vn,s2w,cam[0],nm,edges,tool[0],dc[0],setData]);

var onMove=useCallback(function(e){var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;
var sx=e.clientX-rc.left,sy=e.clientY-rc.top;
if(dp[0]){var w=s2w(sx,sy);dp[1](function(p){return Object.assign({},p,{points:p.points.concat([{x:w.x,y:w.y}])});});return;}
if(!drag[0]){if(tool[0]==='select'){var w2=s2w(sx,sy);var hit2=null;for(var i=0;i<vn.length;i++){var dx=w2.x-vn[i].x,dy=w2.y-vn[i].y;if(dx*dx+dy*dy<vn[i].r*vn[i].r){hit2=vn[i];break;}}hov[1](hit2?hit2.id:null);}return;}
var ddx=sx-drag[0].sx,ddy=sy-drag[0].sy;
if(drag[0].t==='p'){cam[1](function(c){return{x:drag[0].cx+ddx,y:drag[0].cy+ddy,z:c.z};});}
else if(drag[0].t==='c'){var nx=drag[0].ox+ddx/cam[0].z,ny=drag[0].oy+ddy/cam[0].z;
setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(n){if(n.id===drag[0].nid)return Object.assign({},n,{x:nx,y:ny});if(drag[0].off[n.id])return Object.assign({},n,{x:nx+drag[0].off[n.id].dx,y:ny+drag[0].off[n.id].dy});return n;})});});}
},[drag[0],cam[0],vn,s2w,dp[0],tool[0],setData]);

var onUp=useCallback(function(){if(dp[0]&&dp[0].points.length>2){setData(function(dd){return Object.assign({},dd,{drawings:dd.drawings.concat([dp[0]])});});}dp[1](null);drag[1](null);},[dp[0],setData]);
var onWheel=useCallback(function(e){e.preventDefault();var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;var sx=e.clientX-rc.left,sy=e.clientY-rc.top,f=e.deltaY>0?0.9:1.1;cam[1](function(c){var nz=Math.max(0.15,Math.min(5,c.z*f));return{x:sx-(sx-c.x)*(nz/c.z),y:sy-(sy-c.y)*(nz/c.z),z:nz};});},[]);
var onDbl=useCallback(function(e){var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;var w=s2w(e.clientX-rc.left,e.clientY-rc.top);var hit=null;for(var i=0;i<vn.length;i++){var dx=w.x-vn[i].x,dy=w.y-vn[i].y;if(dx*dx+dy*dy<vn[i].r*vn[i].r){hit=vn[i];break;}}if(hit){coll[1](function(prev){var n2=new Set(prev);if(n2.has(hit.id))n2.delete(hit.id);else n2.add(hit.id);return n2;});}else{fit(nodes);}},[vn,s2w,fit,nodes]);

var selN=sel[0]?nm[sel[0]]:null;
var connE=selN?ve.filter(function(e){return e.source===sel[0]||e.target===sel[0];}):[];
var showD=cam[0].z>0.45,showT=cam[0].z>0.55,showEL=cam[0].z>0.65;
var stages={uploading:"Uploading",parsing:"Parsing",chunking:"Splitting",pattern_extraction:"Scanning",concept_extraction:"Extracting",clustering:"Clustering",relation_extraction:"Connecting",validation:"Validating",done:"Complete",extract:"Extracting",validate:"Validating",parse:"Parsing",chunk:"Chunking"};
var cursor=tool[0]==='draw'?'crosshair':tool[0]==='eraser'?'cell':(drag[0]&&drag[0].t==='p')?'grabbing':'grab';

// ═══ RENDER ═══
return h("div",{style:{height:"100vh",display:"flex",flexDirection:"column",background:P.bg,color:P.text,fontFamily:"'Inter',system-ui,sans-serif"}},

// HEADER
h("header",{style:{display:"flex",alignItems:"center",justifyContent:"space-between",padding:"8px 16px",background:P.surface,borderBottom:"1px solid "+P.border,flexShrink:0,gap:8}},
h("div",{style:{display:"flex",alignItems:"center",gap:10}},
h("span",{onClick:function(){view[1]('home');},style:{fontSize:16,fontWeight:700,cursor:'pointer',background:"linear-gradient(135deg,#6C5CE7,#00B8A9)",WebkitBackgroundClip:"text",WebkitTextFillColor:"transparent"}},"✦ Mycel"),
h("nav",{style:{display:"flex",gap:3}},
["home","graph","library","community","palace","account"].map(function(k){
return h("button",{key:k,onClick:function(){view[1](k);},style:{padding:"5px 12px",borderRadius:6,border:"none",cursor:"pointer",background:view[0]===k?P.bg:"transparent",color:view[0]===k?P.text:P.dim,fontSize:12,fontWeight:500}},k.charAt(0).toUpperCase()+k.slice(1));}))),
// Toolbar (graph only)
view[0]==='graph'&&h("div",{style:{display:"flex",gap:4,alignItems:"center"}},
h("span",{style:{fontSize:11,color:P.dim,marginRight:6}},vn.length+" / "+ve.length),
[{k:'select',l:'↖'},{k:'draw',l:'✎'},{k:'eraser',l:'⌫'}].map(function(b){return h("button",{key:b.k,onClick:function(){tool[1](b.k);},style:{padding:"5px 10px",borderRadius:6,border:tool[0]===b.k?"1px solid "+P.text+"30":"1px solid transparent",background:tool[0]===b.k?P.bg:"transparent",color:tool[0]===b.k?P.text:P.dim,fontSize:13,cursor:"pointer"}},b.l);}),
tool[0]==='draw'&&["#A29BFE","#5EECD5","#F0A08A","#FDCB6E","#FD79A8","#E8ECF4"].map(function(c){return h("div",{key:c,onClick:function(){dc[1](c);},style:{width:16,height:16,borderRadius:"50%",background:c,cursor:"pointer",outline:dc[0]===c?"2px solid #fff":"none",outlineOffset:1,marginLeft:2}});}),
h("div",{style:{width:1,height:16,background:P.border,margin:"0 4px"}}),
h("button",{onClick:addNode,style:{padding:"5px 10px",borderRadius:6,border:"1px solid "+P.border,background:"transparent",color:P.text,fontSize:12,cursor:"pointer"}},"+Node"),
h("div",{style:{width:1,height:16,background:P.border,margin:"0 4px"}}),
h("button",{onClick:undo,disabled:!hist.past.length,style:{padding:"5px 8px",borderRadius:6,border:"1px solid "+P.border,background:"transparent",color:hist.past.length?P.text:P.dim,fontSize:12,cursor:"pointer",opacity:hist.past.length?1:0.4}},"↩"),
h("button",{onClick:redo,disabled:!hist.future.length,style:{padding:"5px 8px",borderRadius:6,border:"1px solid "+P.border,background:"transparent",color:hist.future.length?P.text:P.dim,fontSize:12,cursor:"pointer",opacity:hist.future.length?1:0.4}},"↪")),
// User badge
user[0]&&h("div",{style:{fontSize:11,color:"#A29BFE",cursor:"pointer"},onClick:function(){view[1]('account');}},user[0].display_name+" · "+user[0].points+"pts")
),

// HOME
view[0]==='home'&&h("div",{style:{flex:1,display:"flex",alignItems:"center",justifyContent:"center",flexDirection:"column",gap:20,padding:"40px 20px"}},
h("h1",{style:{fontSize:28,fontWeight:700,background:"linear-gradient(135deg,#6C5CE7,#00B8A9)",WebkitBackgroundClip:"text",WebkitTextFillColor:"transparent"}},"Mycel"),
h("p",{style:{fontSize:14,color:P.muted,lineHeight:1.7,maxWidth:420,textAlign:"center"}},"Upload a textbook chapter. AI extracts concepts and shows how they connect."),
h("div",{onClick:function(){if(!upl[0]){var el=document.getElementById('fi');if(el)el.click();}},style:{width:"100%",maxWidth:460,border:"2px dashed "+P.border,borderRadius:14,padding:"28px 20px",textAlign:"center",cursor:upl[0]?"wait":"pointer"}},
h("input",{id:"fi",type:"file",accept:".pdf,.docx,.txt,.md,.epub",style:{display:"none"},disabled:upl[0],onChange:function(e){handleUpload(e.target.files?e.target.files[0]:null);}}),
prog[0]&&prog[0].stage!=='done'?h("div",null,h("div",{style:{fontSize:14,fontWeight:600,marginBottom:4}},stages[prog[0].stage]||'Processing...'),h("div",{style:{fontSize:12,color:P.dim,marginBottom:8}},prog[0].message),h("div",{style:{height:5,background:P.bg,borderRadius:3,overflow:"hidden",maxWidth:260,margin:"0 auto"}},h("div",{style:{height:"100%",width:Math.max((prog[0].progress||0)*100,3)+"%",background:"linear-gradient(90deg,#6C5CE7,#00B8A9)",borderRadius:3}}))):h("div",null,h("div",{style:{fontSize:15,fontWeight:500,marginBottom:4}},"Drop a file or click to upload"),h("div",{style:{fontSize:12,color:P.dim}},"PDF, DOCX, TXT, MD, EPUB supported"))),
h("button",{onClick:function(){view[1]('library');},style:BS(P.dim,"transparent")},"Browse library")),

// LIBRARY
view[0]==='library'&&h("div",{style:{flex:1,padding:24,overflowY:"auto"}},
h("h2",{style:{fontSize:18,fontWeight:600,marginBottom:16}},"Library"),
maps[0].length===0?h("div",{style:{textAlign:"center",padding:40,color:P.dim}},"No maps yet. Upload a file to create one."):
h("div",{style:{display:"grid",gridTemplateColumns:"repeat(auto-fill,minmax(280px,1fr))",gap:12}},
maps[0].map(function(m){return h("div",{key:m.id,style:{padding:16,background:P.surface,border:"1px solid "+P.border,borderRadius:12}},
h("div",{style:{display:"flex",alignItems:"center",gap:8,marginBottom:6}},
h("div",{style:{fontSize:15,fontWeight:600,flex:1}},m.title||m.filename),
h("span",{style:{fontSize:10,padding:"3px 10px",borderRadius:10,background:m.status==='confirmed'?'rgba(81,207,102,0.15)':'rgba(90,100,120,0.2)',color:m.status==='confirmed'?'#51CF66':P.dim}},m.status==='confirmed'?'Confirmed':'Draft')),
h("div",{style:{fontSize:11,color:P.dim,marginBottom:10}},m.created_at?m.created_at.split('T')[0]:''),
h("div",{style:{display:"flex",gap:6,flexWrap:"wrap"}},
h("button",{onClick:function(){loadMap(m.id);},style:BS()},"Open"),
m.status!=='confirmed'&&h("button",{onClick:function(){confirmMap(m.id).then(function(){getMaps().then(function(d){maps[1](d.maps||[]);});});},style:BS("#51CF66","rgba(81,207,102,0.1)")},"Confirm"),
m.status==='confirmed'&&h("button",{onClick:function(){shareM[1]({id:m.id,title:m.title||m.filename});},style:BS("#A29BFE","rgba(162,155,254,0.1)")},"Share"),
m.status==='confirmed'&&h("button",{onClick:function(){unconfirmMap(m.id).then(function(){getMaps().then(function(d){maps[1](d.maps||[]);});});},style:BS(P.dim,"transparent")},"Unconfirm"),
h("button",{onClick:function(){if(confirm('Delete "'+(m.title||m.filename)+'"?')){deleteMap(m.id).then(function(){getMaps().then(function(d){maps[1](d.maps||[]);});});}},style:BS("#FF6B6B","rgba(255,107,107,0.1)")},"Delete")));})),
// Share modal
shareM[0]&&h("div",{style:{position:"fixed",inset:0,background:"rgba(0,0,0,0.6)",display:"flex",alignItems:"center",justifyContent:"center",zIndex:100},onClick:function(){shareM[1](null);}},
h("div",{onClick:function(e){e.stopPropagation();},style:{width:360,background:P.surface,border:"1px solid "+P.border,borderRadius:16,padding:24}},
h("h3",{style:{fontSize:16,fontWeight:600,marginBottom:12}},"Share to Community"),
h("div",{style:{fontSize:12,color:P.muted,marginBottom:14}},'"'+shareM[0].title+'"'),
h("div",{style:{display:"flex",gap:4,flexWrap:"wrap",marginBottom:16}},
["general","mathematics","physics","cs","biology","history"].map(function(d){return h("button",{key:d,onClick:function(){shareDom[1](d);},style:{padding:"4px 12px",borderRadius:6,fontSize:11,cursor:"pointer",background:shareDom[0]===d?"rgba(162,155,254,0.2)":"transparent",border:shareDom[0]===d?"1px solid rgba(162,155,254,0.4)":"1px solid "+P.border,color:shareDom[0]===d?"#A29BFE":P.dim}},d);})),
h("div",{style:{display:"flex",gap:8}},
h("button",{onClick:function(){shareMap(shareM[0].id,shareM[0].title,'',shareDom[0]).then(function(){shareM[1](null);alert('Shared!');}).catch(function(){alert('Failed');});},style:BS()},"Share"),
h("button",{onClick:function(){shareM[1](null);},style:BS(P.dim,"transparent")},"Cancel"))))),

// COMMUNITY
view[0]==='community'&&h("div",{style:{flex:1,padding:24,overflowY:"auto"}},
h("h2",{style:{fontSize:18,fontWeight:600,marginBottom:16}},"Community Maps"),
h("div",{style:{display:"flex",gap:6,flexWrap:"wrap",marginBottom:20}},
["all","general","mathematics","physics","cs","biology","history"].map(function(d){return h("button",{key:d,onClick:function(){commDom[1](d);loadComm(d);},style:{padding:"6px 14px",borderRadius:8,fontSize:12,cursor:"pointer",fontWeight:500,background:commDom[0]===d?"rgba(162,155,254,0.15)":"transparent",border:commDom[0]===d?"1px solid rgba(162,155,254,0.3)":"1px solid "+P.border,color:commDom[0]===d?"#A29BFE":P.dim}},d.charAt(0).toUpperCase()+d.slice(1));})),
cmaps[0].length===0?h("div",{style:{textAlign:"center",padding:40,color:P.dim}},"No community maps yet. Confirm and share yours!"):
h("div",{style:{display:"grid",gridTemplateColumns:"repeat(auto-fill,minmax(280px,1fr))",gap:12}},
cmaps[0].map(function(m){return h("div",{key:m.id,style:{padding:16,background:P.surface,border:"1px solid "+P.border,borderRadius:12}},
h("div",{style:{display:"flex",alignItems:"center",gap:8,marginBottom:6}},
h("div",{style:{fontSize:15,fontWeight:600,flex:1}},m.title),
h("span",{style:{fontSize:10,padding:"3px 10px",borderRadius:10,background:"rgba(162,155,254,0.15)",color:"#A29BFE"}},m.domain||'general')),
m.description&&h("div",{style:{fontSize:12,color:P.muted,marginBottom:6,lineHeight:1.4}},m.description),
h("div",{style:{fontSize:11,color:P.dim,marginBottom:10}},"by "+(m.user_id||'anonymous')),
h("div",{style:{display:"flex",gap:6}},
h("button",{onClick:function(){upvoteCommunityMap(m.id).then(function(){loadComm(commDom[0]);});},style:BS("#FDCB6E","rgba(253,203,110,0.1)")},"↑ "+(m.upvotes||0)),
h("button",{onClick:function(){loadMap(m.map_id);},style:BS("#5EECD5","rgba(94,236,213,0.1)")},"Open Map")));}))),

// PALACE
view[0]==='palace'&&h("div",{style:{flex:1,display:"flex",alignItems:"center",justifyContent:"center",flexDirection:"column",gap:16}},
h("div",{style:{fontSize:48}},"🏛️"),
h("h2",{style:{fontSize:22,fontWeight:600}},"Memory Palace"),
h("p",{style:{fontSize:14,color:P.dim,maxWidth:400,textAlign:"center",lineHeight:1.6}},"Walk through your knowledge as a 3D architectural space. Each concept becomes a room, each connection a corridor."),
h("div",{style:{fontSize:12,color:P.dim,padding:"8px 16px",border:"1px solid "+P.border,borderRadius:8}},"Coming soon — under development")),

// ACCOUNT
view[0]==='account'&&h("div",{style:{flex:1,padding:32,maxWidth:480,margin:"0 auto",overflowY:"auto"}},
user[0]?h("div",null,
h("h2",{style:{fontSize:18,fontWeight:600,marginBottom:16}},"Account"),
h("div",{style:{padding:16,background:P.surface,borderRadius:12,border:"1px solid "+P.border,marginBottom:16}},
h("div",{style:{fontSize:16,fontWeight:600,marginBottom:4}},user[0].display_name),
h("div",{style:{fontSize:12,color:P.dim,marginBottom:12}},"@"+user[0].username),
h("div",{style:{display:"flex",gap:20}},
h("div",null,h("div",{style:{fontSize:22,fontWeight:700,color:"#A29BFE"}},user[0].points||0),h("div",{style:{fontSize:11,color:P.dim}},"Points")),
h("div",null,h("div",{style:{fontSize:22,fontWeight:700,color:"#5EECD5"}},user[0].level||"beginner"),h("div",{style:{fontSize:11,color:P.dim}},"Level")))),
h("div",{style:{marginBottom:16}},
h("div",{style:{fontSize:12,color:P.dim,marginBottom:6}},"How credits work:"),
h("div",{style:{fontSize:11,color:P.dim,lineHeight:1.8,padding:12,background:P.surface,borderRadius:8,border:"1px solid "+P.border}},
"Upload a map: +5 pts · Confirm: +10 · Share: +15 · Edit: +1 · Receive upvote: +3",h("br"),
"Levels: Beginner (0) → Experienced (50) → Expert (200) → Professional (500) → Organizer (1500)")),
h("button",{onClick:function(){localStorage.removeItem("mycel_uid");user[1](null);},style:BS("#FF6B6B","rgba(255,107,107,0.1)")},"Log out")
):h("div",null,
h("h2",{style:{fontSize:18,fontWeight:600,marginBottom:16}},authMode[0]==="login"?"Log in":"Create account"),
h("input",{value:authU[0],placeholder:"Username",onChange:function(e){authU[1](e.target.value);},style:{width:"100%",padding:"10px 14px",background:P.bg,border:"1px solid "+P.border,borderRadius:8,color:P.text,fontSize:14,marginBottom:8}}),
h("input",{value:authP[0],placeholder:"Password",type:"password",onChange:function(e){authP[1](e.target.value);},style:{width:"100%",padding:"10px 14px",background:P.bg,border:"1px solid "+P.border,borderRadius:8,color:P.text,fontSize:14,marginBottom:12}}),
h("button",{onClick:function(){var fn=authMode[0]==="login"?login:register;
fn(authU[0],authP[0]).then(function(d){if(d.user){localStorage.setItem("mycel_uid",d.user.id);user[1](d.user);}
else if(d.user_id){localStorage.setItem("mycel_uid",d.user_id);getMe().then(function(r){if(r.user)user[1](r.user);});}
else{alert(d.error||"Failed");}});},style:Object.assign({width:"100%",marginBottom:8},BS())},authMode[0]==="login"?"Log in":"Create account"),
h("button",{onClick:function(){authMode[1](authMode[0]==="login"?"register":"login");},style:Object.assign({width:"100%"},BS(P.dim,"transparent"))},authMode[0]==="login"?"Need an account? Register":"Have an account? Log in"))),

// GRAPH
view[0]==='graph'&&h("div",{ref:cRef,style:{flex:1,position:"relative",overflow:"hidden",cursor:cursor},onPointerDown:onDown,onPointerMove:onMove,onPointerUp:onUp,onPointerLeave:onUp,onWheel:onWheel,onDoubleClick:onDbl},
h("div",{style:{position:"absolute",inset:0,zIndex:0,pointerEvents:"none",backgroundImage:"radial-gradient(circle,"+P.dot+" 1px,transparent 1px)",backgroundSize:Math.max(16,26*cam[0].z)+"px "+Math.max(16,26*cam[0].z)+"px",backgroundPosition:(cam[0].x%(26*cam[0].z))+"px "+(cam[0].y%(26*cam[0].z))+"px"}}),
h("svg",{style:{position:"absolute",inset:0,width:"100%",height:"100%",zIndex:1,overflow:"visible"}},
h("defs",null,h("marker",{id:"ah",viewBox:"0 0 12 12",refX:"11",refY:"6",markerWidth:"7",markerHeight:"7",orient:"auto"},h("path",{d:"M1 2L10 6L1 10",fill:"none",stroke:"context-stroke",strokeWidth:"1.5",strokeLinecap:"round",strokeLinejoin:"round"}))),
// Drawings
drawings.map(function(dr,i){if(dr.points.length<2)return null;var d2='M'+dr.points[0].x+' '+dr.points[0].y;for(var j=1;j<dr.points.length;j++)d2+='L'+dr.points[j].x+' '+dr.points[j].y;return h("path",{key:"dr"+i,d:d2,fill:"none",stroke:dr.color,strokeWidth:dr.width/cam[0].z,opacity:0.7,strokeLinecap:"round",strokeLinejoin:"round",transform:"translate("+cam[0].x+","+cam[0].y+") scale("+cam[0].z+")"});}),
dp[0]&&dp[0].points.length>1&&(function(){var d2='M'+dp[0].points[0].x+' '+dp[0].points[0].y;for(var j=1;j<dp[0].points.length;j++)d2+='L'+dp[0].points[j].x+' '+dp[0].points[j].y;return h("path",{d:d2,fill:"none",stroke:dp[0].color,strokeWidth:dp[0].width/cam[0].z,opacity:0.7,strokeLinecap:"round",strokeLinejoin:"round",transform:"translate("+cam[0].x+","+cam[0].y+") scale("+cam[0].z+")"});})(),
hulls.map(function(hl){return h("path",{key:hl.key,d:hl.d,fill:P.hullFill,stroke:P.hullStroke,strokeWidth:1,transform:"translate("+cam[0].x+","+cam[0].y+") scale("+cam[0].z+")"});}),
// Edges
Object.keys(ep).map(function(k){return ep[k];}).reduce(function(a,b){return a.concat(b);},[]).map(function(e,i){var s=nm[e.source],t=nm[e.target];if(!s||!t)return null;var cat=edgeCat(e.relation_type),st=P.edges[cat]||P.edges.custom;var conf=e.confidence||0.5,thick=st.w*(0.5+conf*0.5);var hi=sel[0]===e.source||sel[0]===e.target||hov[0]===e.source||hov[0]===e.target;var path=(cat==='compositional'||cat==='pedagogical')?sPath(s.x,s.y,t.x,t.y):edgePath(s.x,s.y,t.x,t.y,e.idx,ep[[e.source,e.target].sort().join('|')].length);var tr="translate("+cam[0].x+","+cam[0].y+") scale("+cam[0].z+")";var useA=ARROW_CATS.has(cat);return h("g",{key:"e"+i},hi&&h("path",{d:path,fill:"none",stroke:st.color,strokeWidth:thick+7,opacity:0.12,transform:tr,strokeLinecap:"round"}),h("path",{d:path,fill:"none",stroke:st.color,strokeWidth:hi?thick*1.5:thick,strokeDasharray:st.dash,opacity:hi?0.9:0.55,transform:tr,strokeLinecap:"round",markerEnd:useA?"url(#ah)":""}));}),
// Nodes
vn.map(function(n){var t=typeColor(P,n.concept_type);var isSel=sel[0]===n.id,isHov=hov[0]===n.id;var hasCh=(ch[n.id]||[]).length>0,isCol=coll[0].has(n.id);var dl=showD?(n.dl||[]):[];var totalH=(n.lh||30)+(dl.length?dl.length*16+10:0)+(dl.length?10:0)+(n.imgH||0);var sx2=n.x*cam[0].z+cam[0].x,sy2=n.y*cam[0].z+cam[0].y;var terms=showT&&dl.length>0?findT(n.description,n.label):[];
return h("g",{key:n.id,transform:"translate("+sx2+","+sy2+") scale("+cam[0].z+")",style:{cursor:tool[0]==='select'?'pointer':'inherit'},onClick:function(ev){if(tool[0]!=='select')return;ev.stopPropagation();sel[1](function(p){return p===n.id?null:n.id;});},onPointerDown:function(ev){if(tool[0]!=='select')return;ev.stopPropagation();var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;var px=ev.clientX-rc.left,py=ev.clientY-rc.top;var nbrs=getNeighbors(n.id,edges);var offsets={};Object.keys(nbrs).forEach(function(id){offsets[id]={dx:(nm[id]?nm[id].x:0)-n.x,dy:(nm[id]?nm[id].y:0)-n.y};});drag[1]({t:'c',nid:n.id,nbrs:nbrs,sx:px,sy:py,ox:n.x,oy:n.y,off:offsets});ev.preventDefault();}},
isSel&&h("rect",{x:-n.w/2-6,y:-totalH/2-6,width:n.w+12,height:totalH+12,rx:14,fill:P.surface,stroke:t.a,strokeWidth:1.5,opacity:0.95}),
isHov&&!isSel&&h("rect",{x:-n.w/2-4,y:-totalH/2-4,width:n.w+8,height:totalH+8,rx:12,fill:"none",stroke:t.a,strokeWidth:0.8,opacity:0.3,strokeDasharray:"4 3"}),
h("circle",{cx:-n.w/2+6,cy:-totalH/2+6,r:3.5,fill:t.a,opacity:isSel?1:0.7}),
(n.ll||[]).map(function(line,li){return h("text",{key:"l"+li,x:0,y:-totalH/2+18+li*22,textAnchor:"middle",dominantBaseline:"central",fontSize:"14",fontWeight:"600",fill:t.a,fontFamily:"'Inter',sans-serif",style:{pointerEvents:"none"}},line);}),
dl.map(function(line,di){return h("text",{key:"d"+di,x:0,y:-totalH/2+(n.lh||30)+8+di*16,textAnchor:"middle",dominantBaseline:"central",fontSize:"10",fill:t.s,opacity:0.75,fontFamily:"'Inter',sans-serif",style:{pointerEvents:"none"}},line);}),
n.image&&h("image",{href:n.image,x:-30,y:totalH/2-(n.imgH||70)-5,width:60,height:60,preserveAspectRatio:"xMidYMid slice"}),
terms.map(function(term,ti){var tw=term.length*5.5;var ox=(ti-(terms.length-1)/2)*(tw+16);var oy=totalH/2-(n.imgH||0)+2;return h("g",{key:"t"+ti},h("ellipse",{cx:ox,cy:oy,rx:tw/2+6,ry:9,fill:"none",stroke:t.a,strokeWidth:1,opacity:0.5}),h("text",{x:ox,y:oy+1,textAnchor:"middle",dominantBaseline:"central",fontSize:"8",fill:t.a,opacity:0.6,fontWeight:"500",fontFamily:"'Inter',sans-serif"},term));}),
hasCh&&h("g",{transform:"translate("+(n.w/2)+","+(-totalH/2)+")",onClick:function(ev){ev.stopPropagation();coll[1](function(prev){var s2=new Set(prev);if(s2.has(n.id))s2.delete(n.id);else s2.add(n.id);return s2;});}},h("circle",{r:9,fill:P.surface,stroke:t.a,strokeWidth:0.8}),h("text",{x:0,y:1,textAnchor:"middle",dominantBaseline:"central",fontSize:"8",fill:t.a,fontWeight:"600"},isCol?'+'+(ch[n.id]||[]).length:'−')),
(deg[n.id]||0)>2&&!isHov&&!isSel&&h("g",{transform:"translate("+(-n.w/2)+","+(totalH/2)+")"},h("circle",{r:8,fill:P.surface+"CC",stroke:t.a,strokeWidth:0.4}),h("text",{x:0,y:1,textAnchor:"middle",dominantBaseline:"central",fontSize:"7",fill:t.a},deg[n.id])));})),
// Detail card
selN&&(function(){var sc=w2s(selN.x,selN.y);var t=typeColor(P,selN.concept_type);var rc=cRef.current?cRef.current.getBoundingClientRect():{width:800};var cW=270;var cx2=Math.min(Math.max(10,sc.x+80),rc.width-cW-16);var cy2=Math.max(10,sc.y-50);
return h("div",{style:{position:"absolute",left:cx2,top:cy2,width:cW,background:P.surface,border:"1px solid "+P.border,borderRadius:12,padding:"10px 12px",boxShadow:"0 6px 28px "+P.bg+"AA",zIndex:20,maxHeight:"55vh",overflowY:"auto"}},
h("div",{style:{display:"flex",alignItems:"center",gap:5,marginBottom:5}},h("div",{style:{width:7,height:7,borderRadius:"50%",background:t.a}}),h("span",{style:{fontSize:11,color:t.a,fontWeight:600,textTransform:"uppercase"}},selN.concept_type),h("span",{style:{fontSize:11,color:P.dim,marginLeft:"auto"}},Math.round((selN.confidence||0)*100)+"%"),h("button",{onClick:function(){sel[1](null);},style:{background:"none",border:"none",color:P.dim,fontSize:13,cursor:"pointer"}},"×")),
ef[0]==='label'?h("input",{value:ev[0],onChange:function(e){ev[1](e.target.value);},autoFocus:true,onBlur:function(){setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(nd){if(nd.id!==sel[0])return nd;var up=Object.assign({},nd,{label:ev[0]});return Object.assign(up,nSize(up));})});});ef[1](null);},onKeyDown:function(e){if(e.key==='Enter')e.target.blur();if(e.key==='Escape')ef[1](null);},style:{width:"100%",fontSize:15,fontWeight:600,background:P.bg,border:"1px solid "+t.a+"50",borderRadius:6,color:t.a,padding:"3px 6px",marginBottom:4,fontFamily:"inherit"}}):h("h3",{onClick:function(){ef[1]('label');ev[1](selN.label);},style:{fontSize:15,fontWeight:600,marginBottom:4,cursor:"text",color:t.a}},selN.label),
ef[0]==='desc'?h("textarea",{value:ev[0],onChange:function(e){ev[1](e.target.value);},rows:3,autoFocus:true,onBlur:function(){setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(nd){if(nd.id!==sel[0])return nd;var up=Object.assign({},nd,{description:ev[0]});return Object.assign(up,nSize(up));})});});ef[1](null);},style:{width:"100%",fontSize:12,background:P.bg,border:"1px solid "+t.a+"50",borderRadius:6,color:t.s,padding:"4px 6px",marginBottom:6,fontFamily:"inherit",lineHeight:1.4,resize:"vertical"}}):h("p",{onClick:function(){ef[1]('desc');ev[1](selN.description||'');},style:{fontSize:12,color:t.s,lineHeight:1.5,marginBottom:6,cursor:"text"}},selN.description||"Click to add"),
h("div",{style:{display:"flex",gap:4,marginBottom:6}},h("button",{onClick:function(){submitCorrection({map_id:mapId[0],type:"approve",original:{id:sel[0]}}).catch(function(){});},style:BS("#51CF66","rgba(81,207,102,0.1)")},"Correct"),h("button",{onClick:function(){setData(function(dd){return{nodes:dd.nodes.filter(function(nd){return nd.id!==sel[0];}),edges:dd.edges.filter(function(ed){return ed.source!==sel[0]&&ed.target!==sel[0];}),drawings:dd.drawings};});sel[1](null);},style:BS("#FF6B6B","rgba(255,107,107,0.1)")},"Remove")),
connE.length>0&&h("div",null,h("div",{style:{fontSize:11,color:P.dim,fontWeight:600,marginBottom:3}},"Connections ("+connE.length+")"),connE.map(function(e,i){var isSrc=e.source===sel[0],oId=isSrc?e.target:e.source,o=nm[oId];var cat=edgeCat(e.relation_type),es=P.edges[cat]||P.edges.custom;return h("div",{key:i,onClick:function(){sel[1](oId);},style:{padding:"4px 6px",background:P.bg,borderRadius:4,marginBottom:2,borderLeft:"3px solid "+es.color,cursor:"pointer"}},h("div",{style:{display:"flex",justifyContent:"space-between",fontSize:10}},h("span",{style:{color:es.color,fontWeight:600,fontSize:8,textTransform:"uppercase"}},(e.relation_type||'').replace(/_/g,' ')),h("span",{style:{color:P.dim}},(isSrc?"→ ":"← ")+(o?o.label:"?"))),e.justification&&h("div",{style:{fontSize:9,color:P.dim,marginTop:1,lineHeight:1.3}},e.justification));})));})(),
// Legend
h("div",{style:{position:"absolute",top:8,left:8,background:P.surface+"DD",backdropFilter:"blur(8px)",padding:"10px 12px",borderRadius:10,border:"1px solid "+P.border,fontSize:10,zIndex:5}},
["theorem","definition","principle","method","framework","example"].map(function(t2){var c=P.types[t2];if(!c)return null;return h("div",{key:t2,style:{display:"flex",alignItems:"center",gap:5,marginBottom:2}},h("div",{style:{width:7,height:7,borderRadius:"50%",background:c.a}}),h("span",{style:{color:c.a}},t2));}),
h("div",{style:{marginTop:4,borderTop:"1px solid "+P.border,paddingTop:4,color:P.dim,lineHeight:1.5}},"Drag=move · Dbl=fold",h("br"),"V=select D=draw E=erase",h("br"),"Ctrl+Z/Y · Del=remove")),
// Zoom
h("div",{style:{position:"absolute",bottom:8,right:8,display:"flex",gap:3,zIndex:5}},
[{l:"+",f:1.2},{l:"−",f:1/1.2},{l:"⊡",f:0}].map(function(b){return h("button",{key:b.l,onClick:function(){b.f?cam[1](function(c){return{x:c.x,y:c.y,z:Math.max(0.15,Math.min(5,c.z*b.f))};}):fit(nodes);},style:{width:32,height:32,borderRadius:8,background:P.surface,border:"1px solid "+P.border,color:P.text,fontSize:12,cursor:"pointer",display:"flex",alignItems:"center",justifyContent:"center"}},b.l);})))
);}
JSXEOF
echo "  ✓ App.jsx — complete with all views"
echo ""
echo "DEPLOY: git add -A && git commit -m 'complete UI' && git push"
echo "Wait for Vercel to rebuild (uncheck build cache if needed)"