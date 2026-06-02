import React,{useState,useMemo,useCallback,useRef,useEffect,useReducer} from"react";
import{uploadPDF,getMaps,getMap,deleteMap,submitCorrection,confirmMap,unconfirmMap,shareMap,getCommunityMaps,upvoteCommunityMap,register,login,getMe,getActivity,getLeaderboard,exportMap,postComment,getComments,postFeedback,updateProfile}from"./api";
import{PALETTES,edgeCat,typeColor,ARROW_CATS}from"./utils/theme";
import{organicLayout,edgePath,sPath,wrap,nSize,convexHull,hullPath,getNeighbors}from"./utils/layout";
import PDFViewer from './components/PDFViewer.jsx';
import { getPdfUrl } from './api';

function histR(s,a){
  switch(a.type){
    case'SET':var p=s.past.concat([s.present]);if(p.length>40)p=p.slice(-40);return{past:p,present:a.data,future:[]};
    case'UNDO':if(!s.past.length)return s;return{past:s.past.slice(0,-1),present:s.past[s.past.length-1],future:[s.present].concat(s.future).slice(0,40)};
    case'REDO':if(!s.future.length)return s;return{past:s.past.concat([s.present]),present:s.future[0],future:s.future.slice(1)};
    case'INIT':return{past:[],present:a.data,future:[]};
    default:return s;
  }
}

var h=React.createElement;
function B(c,bg){return{padding:"10px 18px",background:bg||"rgba(162,155,254,0.12)",border:"1px solid "+(c?c+"40":"rgba(162,155,254,0.3)"),borderRadius:8,color:c||"#A29BFE",fontSize:14,fontWeight:500,cursor:"pointer",fontFamily:"inherit"};}
function fmtDate(d){if(!d)return'';try{var dt=new Date(d+'Z');return dt.toLocaleDateString()+' '+dt.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});}catch(e){return d||'';}}

export default function App(){
  var init={nodes:[],edges:[],drawings:[]};
  var hr=useReducer(histR,{past:[],present:init,future:[]});
  var hist=hr[0],dispatch=hr[1];
  var D=hist.present,nodes=D.nodes,edges=D.edges,drawings=D.drawings||[];
  var setData=useCallback(function(fn){dispatch({type:'SET',data:typeof fn==='function'?fn(hist.present):fn});},[hist.present]);
  var undo=useCallback(function(){dispatch({type:'UNDO'});},[]);
  var redo=useCallback(function(){dispatch({type:'REDO'});},[]);

  var view=useState("home"),sel=useState(null),hov=useState(null),mapId=useState(null),maps=useState([]);
  var upl=useState(false),prog=useState(null),coll=useState(new Set()),ef=useState(null),ev=useState('');
  var cam=useState({x:0,y:0,z:0.75}),drag=useState(null),tool=useState('select'),dp=useState(null),dc=useState('#A29BFE');
  var user=useState(null),cmaps=useState([]),shareM=useState(null),shareDom=useState("general"),commDom=useState("all");
  var authMode=useState("login"),authU=useState(""),authP=useState("");
  var onboard=useState(!localStorage.getItem("mycel_onboarded"));
  var fbCat=useState("general"),fbText=useState(""),fbSent=useState(false);
  var leaders=useState([]);
  var darkMode=useState(localStorage.getItem("mycel_theme")!=="light");

  var P=PALETTES.aurora;
  var BG=darkMode[0]?P.bg:"#F8F6F1",SURF=darkMode[0]?P.surface:"#FFFFFF",BRD=darkMode[0]?P.border:"#E0D8CC";
  var TXT=darkMode[0]?P.text:"#1A1510",DIM=darkMode[0]?P.dim:"#4A3E2D",MUT=darkMode[0]?P.muted:"#4A3E2D";
  var cRef=useRef(null);

  var referMode = useState(false);
  
  useEffect(function(){var uid=localStorage.getItem("mycel_uid");if(uid)getMe().then(function(d){if(d.user)user[1](d.user);}).catch(function(){});},[]);
  useEffect(function(){
    if(view[0]==="library")getMaps().then(function(d){maps[1](d.maps||[]);}).catch(function(){});
    if(view[0]==="community"){getCommunityMaps("all").then(function(d){cmaps[1](d.maps||[]);}).catch(function(){});getLeaderboard().then(function(d){leaders[1](d.users||[]);}).catch(function(){});}
  },[view[0]]);
  useEffect(function(){
    var fn=function(e){
      if(e.target.tagName==='INPUT'||e.target.tagName==='TEXTAREA')return;
      if((e.metaKey||e.ctrlKey)&&e.key==='z'&&!e.shiftKey){e.preventDefault();undo();}
      if((e.metaKey||e.ctrlKey)&&(e.key==='y'||(e.key==='z'&&e.shiftKey))){e.preventDefault();redo();}
      if(e.key==='Escape'){sel[1](null);tool[1]('select');}
      if(e.key==='Delete'&&sel[0]){setData(function(dd){return{nodes:dd.nodes.filter(function(n){return n.id!==sel[0];}),edges:dd.edges.filter(function(ed){return ed.source!==sel[0]&&ed.target!==sel[0];}),drawings:dd.drawings};});sel[1](null);}
    };window.addEventListener('keydown',fn);return function(){window.removeEventListener('keydown',fn);};
  },[undo,redo,sel[0],setData]);

  var fit=useCallback(function(nl){
    if(!cRef.current||!nl||!nl.length)return;var rc=cRef.current.getBoundingClientRect();
    var ax=1e9,ay=1e9,bx=-1e9,by=-1e9;
    for(var i=0;i<nl.length;i++){var r=nl[i].r||60;ax=Math.min(ax,nl[i].x-r);ay=Math.min(ay,nl[i].y-r);bx=Math.max(bx,nl[i].x+r);by=Math.max(by,nl[i].y+r);}
    var gw=bx-ax+120,gh=by-ay+120,z=Math.min(rc.width/gw,rc.height/gh,1.4);
    cam[1]({x:-(ax-60)*z+(rc.width-gw*z)/2,y:-(ay-60)*z+(rc.height-gh*z)/2,z:z});
  },[]);

  var handleUpload=function(file){
    if(!file)return;var ext=file.name.split('.').pop().toLowerCase();
    if(['pdf','docx','txt','md','epub'].indexOf(ext)<0)return;
    upl[1](true);prog[1]({stage:'uploading',progress:0,message:'Uploading...'});
    uploadPDF(file).then(function(r){
      if(r.nodes){
        var edgesN=r.edges.map(function(e){return Object.assign({},e,{source:e.source_id||e.source,target:e.target_id||e.target});});
        var laid=organicLayout(r.nodes,edgesN);dispatch({type:'INIT',data:{nodes:laid,edges:edgesN,drawings:[]}});
        mapId[1](r.map_id);view[1]('graph');coll[1](new Set());setTimeout(function(){fit(laid);},80);
        prog[1]({stage:'done',progress:1,message:r.node_count+' concepts, '+r.edge_count+' relations'});
      }else{prog[1]({stage:'error',progress:0,message:r.error||'Upload failed'});}
      upl[1](false);
    }).catch(function(e){prog[1]({stage:'error',progress:0,message:e.message||'Failed'});upl[1](false);});
  };

  var loadMap=function(id){getMap(id).then(function(r){if(r.nodes){
    var edgesN=r.edges.map(function(e){return Object.assign({},e,{source:e.source_id||e.source,target:e.target_id||e.target});});
    var laid=organicLayout(r.nodes,edgesN);dispatch({type:'INIT',data:{nodes:laid,edges:edgesN,drawings:[]}});
    mapId[1](id);view[1]('graph');coll[1](new Set());setTimeout(function(){fit(laid);},80);
  }});};
  var loadComm=function(dom){getCommunityMaps(dom).then(function(d){cmaps[1](d.maps||[]);}).catch(function(){cmaps[1]([]);});};
  var addNode=function(){if(!cRef.current)return;var cx=(cRef.current.clientWidth/2-cam[0].x)/cam[0].z,cy=(cRef.current.clientHeight/2-cam[0].y)/cam[0].z;
    var nn={id:'n_'+Date.now(),label:'New Concept',description:'Click to edit',concept_type:'term',abstraction_level:1,confidence:0.5,cluster:'custom',x:cx,y:cy};
    Object.assign(nn,nSize(nn));setData(function(d){return{nodes:d.nodes.concat([nn]),edges:d.edges,drawings:d.drawings};});sel[1](nn.id);
  };

  // Derived data
  var nm=useMemo(function(){var m={};nodes.forEach(function(n){m[n.id]=n;});return m;},[nodes]);
  var allL=useMemo(function(){return nodes.map(function(n){return n.label;});},[nodes]);
  var ch=useMemo(function(){var c={};edges.forEach(function(e){if(!c[e.source])c[e.source]=[];c[e.source].push(e.target);});return c;},[edges]);
  var deg=useMemo(function(){var d={};edges.forEach(function(e){d[e.source]=(d[e.source]||0)+1;d[e.target]=(d[e.target]||0)+1;});return d;},[edges]);
  var maxDeg=useMemo(function(){var m=1;Object.values(deg).forEach(function(v){if(v>m)m=v;});return m;},[deg]);
  var visIds=useMemo(function(){if(!coll[0].size)return new Set(nodes.map(function(n){return n.id;}));var hidden=new Set();coll[0].forEach(function(cid){var q=(ch[cid]||[]).slice();while(q.length){var id=q.shift();if(!hidden.has(id)){hidden.add(id);if(!coll[0].has(id))(ch[id]||[]).forEach(function(c2){q.push(c2);});}}});return new Set(nodes.filter(function(n){return!hidden.has(n.id);}).map(function(n){return n.id;}));},[nodes,coll[0],ch]);
  var vn=useMemo(function(){return nodes.filter(function(n){return visIds.has(n.id);});},[nodes,visIds]);
  var ve=useMemo(function(){return edges.filter(function(e){return visIds.has(e.source)&&visIds.has(e.target);});},[edges,visIds]);
  var hulls=useMemo(function(){var g={};vn.forEach(function(n){var c=n.cluster||'x';if(!g[c])g[c]=[];g[c].push(n);});return Object.keys(g).filter(function(k){return g[k].length>=2;}).map(function(k){return{key:k,d:hullPath(convexHull(g[k].map(function(n2){return{x:n2.x,y:n2.y};})),45)};});},[vn]);
  var ep=useMemo(function(){var p={};ve.forEach(function(e){var k=[e.source,e.target].sort().join('|');if(!p[k])p[k]=[];p[k].push(Object.assign({},e,{idx:p[k].length}));});return p;},[ve]);
  var s2w=useCallback(function(sx,sy){return{x:(sx-cam[0].x)/cam[0].z,y:(sy-cam[0].y)/cam[0].z};},[cam[0]]);
  var w2s=useCallback(function(wx,wy){return{x:wx*cam[0].z+cam[0].x,y:wy*cam[0].z+cam[0].y};},[cam[0]]);
  var findT=useCallback(function(desc,skip){if(!desc)return[];var f=[];allL.forEach(function(lb){if(lb===skip||lb.length<3)return;if(desc.toLowerCase().indexOf(lb.toLowerCase())>=0)f.push(lb);});return f.slice(0,4);},[allL]);
  var impSize=function(nid,base){var d=deg[nid]||0;return Math.round(base+(d/Math.max(maxDeg,1))*20);};

  // Pointer handlers
  var onDown=useCallback(function(e){
    if(e.button!==0)return;var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;
    var sx=e.clientX-rc.left,sy=e.clientY-rc.top,w=s2w(sx,sy);
    if(tool[0]==='draw'){dp[1]({color:dc[0],points:[{x:w.x,y:w.y}],width:2});e.preventDefault();return;}
    if(tool[0]==='eraser'){setData(function(dd){return Object.assign({},dd,{drawings:dd.drawings.filter(function(dr){return!dr.points.some(function(pt){return Math.abs(pt.x-w.x)<20&&Math.abs(pt.y-w.y)<20;});})});});return;}
    var hit=null;for(var i=0;i<vn.length;i++){var dx=w.x-vn[i].x,dy=w.y-vn[i].y;if(dx*dx+dy*dy<vn[i].r*vn[i].r){hit=vn[i];break;}}
    if(hit){var nbrs=getNeighbors(hit.id,edges);var offsets={};Object.keys(nbrs).forEach(function(id){offsets[id]={dx:(nm[id]?nm[id].x:0)-hit.x,dy:(nm[id]?nm[id].y:0)-hit.y};});drag[1]({t:'c',nid:hit.id,nbrs:nbrs,sx:sx,sy:sy,ox:hit.x,oy:hit.y,off:offsets});e.preventDefault();}
    else{drag[1]({t:'p',sx:sx,sy:sy,cx:cam[0].x,cy:cam[0].y});}
  },[vn,s2w,cam[0],nm,edges,tool[0],dc[0],setData]);

  var onMove=useCallback(function(e){
    var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;
    var sx=e.clientX-rc.left,sy=e.clientY-rc.top;
    if(dp[0]){var w=s2w(sx,sy);dp[1](function(p){return Object.assign({},p,{points:p.points.concat([{x:w.x,y:w.y}])});});return;}
    if(!drag[0]){if(tool[0]==='select'){var w2=s2w(sx,sy);var hit2=null;for(var i=0;i<vn.length;i++){var dx=w2.x-vn[i].x,dy=w2.y-vn[i].y;if(dx*dx+dy*dy<vn[i].r*vn[i].r){hit2=vn[i];break;}}hov[1](hit2?hit2.id:null);}return;}
    var ddx=sx-drag[0].sx,ddy=sy-drag[0].sy;
    if(drag[0].t==='p'){cam[1](function(c){return{x:drag[0].cx+ddx,y:drag[0].cy+ddy,z:c.z};});}
    else if(drag[0].t==='c'){var nx=drag[0].ox+ddx/cam[0].z,ny=drag[0].oy+ddy/cam[0].z;setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(n){if(n.id===drag[0].nid)return Object.assign({},n,{x:nx,y:ny});if(drag[0].off[n.id])return Object.assign({},n,{x:nx+drag[0].off[n.id].dx,y:ny+drag[0].off[n.id].dy});return n;})});});}
  },[drag[0],cam[0],vn,s2w,dp[0],tool[0],setData]);

  var onUp=useCallback(function(){if(dp[0]&&dp[0].points.length>2){setData(function(dd){return Object.assign({},dd,{drawings:dd.drawings.concat([dp[0]])});});}dp[1](null);drag[1](null);},[dp[0],setData]);
  var onWheel=useCallback(function(e){e.preventDefault();var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;var sx=e.clientX-rc.left,sy=e.clientY-rc.top,f=e.deltaY>0?0.9:1.1;cam[1](function(c){var nz=Math.max(0.15,Math.min(5,c.z*f));return{x:sx-(sx-c.x)*(nz/c.z),y:sy-(sy-c.y)*(nz/c.z),z:nz};});},[]);
  var onDbl=useCallback(function(e){var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;var w=s2w(e.clientX-rc.left,e.clientY-rc.top);var hit=null;for(var i=0;i<vn.length;i++){var dx=w.x-vn[i].x,dy=w.y-vn[i].y;if(dx*dx+dy*dy<vn[i].r*vn[i].r){hit=vn[i];break;}}if(hit){coll[1](function(prev){var n2=new Set(prev);if(n2.has(hit.id))n2.delete(hit.id);else n2.add(hit.id);return n2;});}else{fit(nodes);}},[vn,s2w,fit,nodes]);

  var magnify=function(nid,e){if(e)e.stopPropagation();if(sel[0]===nid){sel[1](null);return;}sel[1](nid);};
  var zoomTo=function(nid){var n=nm[nid];if(!n||!cRef.current)return;var rc=cRef.current.getBoundingClientRect();cam[1]({x:-n.x*2.5+rc.width/2,y:-n.y*2.5+rc.height/2,z:2.5});sel[1](nid);};

  var selN=sel[0]?nm[sel[0]]:null;
  var connE=selN?ve.filter(function(e){return e.source===sel[0]||e.target===sel[0];}):[];
  var showD=cam[0].z>0.4,showTm=cam[0].z>0.5;
  var stages={uploading:"Uploading",extract:"Extracting",validate:"Validating",done:"Complete",parse:"Parsing",chunk:"Chunking"};
  var cursor=tool[0]==='draw'?'crosshair':tool[0]==='eraser'?'cell':tool[0]==='magnify'?'zoom-in':(drag[0]&&drag[0].t==='p')?'grabbing':'grab';

  // ═══ BUILD VIEWS AS SEPARATE VARIABLES ═══

  var onboardView=onboard[0]?h("div",{key:"ob",style:{position:"fixed",inset:0,background:"rgba(0,0,0,0.75)",display:"flex",alignItems:"center",justifyContent:"center",zIndex:200},onClick:function(){onboard[1](false);localStorage.setItem("mycel_onboarded","1");}},
    h("div",{onClick:function(e){e.stopPropagation();},style:{width:420,background:SURF,border:"1px solid "+BRD,borderRadius:20,padding:32,textAlign:"center"}},
      h("div",{style:{fontSize:40,marginBottom:12}},"✦"),
      h("h2",{style:{fontSize:22,fontWeight:700,marginBottom:12,background:"linear-gradient(135deg,#6C5CE7,#00B8A9)",WebkitBackgroundClip:"text",WebkitTextFillColor:"transparent"}},"Welcome to Mycel"),
      h("div",{style:{fontSize:15,color:MUT,lineHeight:1.8,marginBottom:20,textAlign:"left"}},
        "1. Create an account in the ",h("b",null,"Account")," tab",h("br",null),
        "2. Upload a PDF/DOCX on the ",h("b",null,"Home")," tab",h("br",null),
        "3. AI extracts concepts → interactive mindmap",h("br",null),
        "4. Click concepts to edit, drag to rearrange",h("br",null),
        "5. Confirm maps → share with community",h("br",null),
        "6. ",h("b",null,"V"),"=select ",h("b",null,"D"),"=draw ",h("b",null,"E"),"=erase"),
      h("button",{onClick:function(){onboard[1](false);localStorage.setItem("mycel_onboarded","1");},style:Object.assign({width:"100%"},B())},"Get Started"))
  ):null;

  var headerView=h("header",{key:"hd",style:{display:"flex",alignItems:"center",justifyContent:"space-between",padding:"10px 18px",background:SURF,borderBottom:"1px solid "+BRD,flexShrink:0}},
    h("div",{style:{display:"flex",alignItems:"center",gap:10}},
      h("span",{onClick:function(){view[1]('home');},style:{fontSize:18,fontWeight:700,cursor:'pointer',background:"linear-gradient(135deg,#6C5CE7,#00B8A9)",WebkitBackgroundClip:"text",WebkitTextFillColor:"transparent"}},"✦ Mycel"),
      h("nav",{style:{display:"flex",gap:4}},
        ["home","graph","library","community","help","palace","account"].map(function(k){
          return h("button",{key:k,onClick:function(){view[1](k);},style:{padding:"6px 14px",borderRadius:7,border:"none",cursor:"pointer",background:view[0]===k?BG:"transparent",color:view[0]===k?TXT:DIM,fontSize:14,fontWeight:500}},k.charAt(0).toUpperCase()+k.slice(1));
        })
      )
    ),
    view[0]==='graph'?h("div",{style:{display:"flex",gap:4,alignItems:"center"}},
      h("span",{style:{fontSize:14,color:DIM,marginRight:10}},vn.length+" · "+ve.length),
      [{k:'select',l:'↖ Select'},{k:'magnify',l:'🔍 Zoom'},{k:'draw',l:'✎ Draw'},{k:'eraser',l:'⌫ Erase'}].map(function(b){return h("button",{key:b.k,onClick:function(){tool[1](b.k);},style:{padding:"6px 12px",borderRadius:6,border:tool[0]===b.k?"1px solid "+TXT+"30":"1px solid transparent",background:tool[0]===b.k?BG:"transparent",color:tool[0]===b.k?TXT:DIM,fontSize:14,cursor:"pointer"}},b.l);}),
      tool[0]==='draw'?["#A29BFE","#5EECD5","#F0A08A","#FDCB6E","#FD79A8","#E8ECF4"].map(function(c){return h("div",{key:c,onClick:function(){dc[1](c);},style:{width:18,height:18,borderRadius:"50%",background:c,cursor:"pointer",outline:dc[0]===c?"2px solid #fff":"none",outlineOffset:2,marginLeft:2}});}):null,
      h("button",{onClick:addNode,style:{padding:"6px 12px",borderRadius:6,border:"1px solid "+BRD,background:"transparent",color:TXT,fontSize:13,cursor:"pointer",marginLeft:6}},"+Node"),
      h("button",{onClick:undo,style:{padding:"6px 10px",borderRadius:6,border:"1px solid "+BRD,background:"transparent",color:hist.past.length?TXT:DIM,fontSize:13,cursor:"pointer",opacity:hist.past.length?1:0.4,marginLeft:4}},"↩"),
      h("button",{onClick:redo,style:{padding:"6px 10px",borderRadius:6,border:"1px solid "+BRD,background:"transparent",color:hist.future.length?TXT:DIM,fontSize:13,cursor:"pointer",opacity:hist.future.length?1:0.4}},"↪"),h("div",{style:{width:1,height:18,background:BRD,margin:"0 6px"}}),h("button",{onClick:function(){if(mapId[0]){window.open(((typeof import.meta!=="undefined"&&import.meta.env&&import.meta.env.VITE_API_URL)||"http://localhost:8000")+"/api/maps/"+mapId[0]+"/export","_blank");}},style:{padding:"6px 14px",borderRadius:6,border:"1px solid "+BRD,background:"transparent",color:DIM,fontSize:14,cursor:"pointer"}},"Export")
    ):null,
    h("div",{style:{display:"flex",alignItems:"center",gap:8}},
      h("button",{onClick:function(){var n=!darkMode[0];darkMode[1](n);localStorage.setItem("mycel_theme",n?"dark":"light");},style:{padding:"6px 10px",borderRadius:6,border:"1px solid "+BRD,background:"transparent",color:DIM,fontSize:13,cursor:"pointer"}},darkMode[0]?"☀":"🌙"),
      user[0]?h("span",{style:{fontSize:13,color:"#A29BFE",cursor:"pointer"},onClick:function(){view[1]('account');}},user[0].display_name+" · "+user[0].points+"pts"):null)
  );

var homeView = view[0] === 'home' ? h("div", {key:"hm", style:{flex:1, display:"flex", alignItems:"center", justifyContent:"center", flexDirection:"column", gap:24, padding:"40px 20px"}},
  h("h1", {style:{fontSize:32, fontWeight:700, background:"linear-gradient(135deg,#6C5CE7,#00B8A9)", WebkitBackgroundClip:"text", WebkitTextFillColor:"transparent"}}, "Mycel"),
  h("p", {style:{fontSize:16, color:MUT, lineHeight:1.7, maxWidth:440, textAlign:"center"}}, "Upload a textbook chapter. AI extracts concepts and shows how they connect."),
  h("div", {onClick:function(){if(!upl[0]){var el=document.getElementById('fi');if(el)el.click();}}, style:{width:"100%", maxWidth:480, border:"2px dashed "+BRD, borderRadius:16, padding:"32px 24px", textAlign:"center", cursor:upl[0]?"wait":"pointer"}},
    h("input", {id:"fi", type:"file", accept:".pdf,.docx,.txt,.md,.epub", style:{display:"none"}, disabled:upl[0], onChange:function(e){handleUpload(e.target.files?e.target.files[0]:null);}}),
    prog[0] && prog[0].stage !== 'done'
      ? h("div", null,
          h("div", {style:{fontSize:16, fontWeight:600, marginBottom:6}}, stages[prog[0].stage] || 'Processing...'),
          h("div", {style:{fontSize:13, color:DIM, marginBottom:10}}, prog[0].message),
          h("div", {style:{height:6, background:BG, borderRadius:3, overflow:"hidden", maxWidth:280, margin:"0 auto"}},
            h("div", {style:{height:"100%", width:Math.max((prog[0].progress||0)*100,3)+"%", background:"linear-gradient(90deg,#6C5CE7,#00B8A9)", borderRadius:3}})))
      : h("div", null,
          h("div", {style:{fontSize:17, fontWeight:500, marginBottom:6}}, "Drop a file or click to upload"),
          h("div", {style:{fontSize:14, color:DIM}}, "PDF, DOCX, TXT, MD, EPUB supported"),
          !user[0] ? h("div", {style:{fontSize:12, color:DIM, marginTop:8}}, "Log in to save maps to your library") : null)
  ),
  h("button", {onClick:function(){view[1]('library');}, style:B(DIM,"transparent")}, "Browse library")
) : null;

  var libraryView=view[0]==='library'?h("div",{key:"lb",style:{flex:1,padding:28,overflowY:"auto"}},
    h("h2",{style:{fontSize:20,fontWeight:600,marginBottom:18}},"Your Library"),
    !user[0]?h("div",{style:{textAlign:"center",padding:40,color:DIM}},"Log in to see your maps.",h("br",null),h("br",null),h("button",{onClick:function(){view[1]('account');},style:B()},"Go to Account")):
    maps[0].length===0?h("div",{style:{textAlign:"center",padding:40,color:DIM}},"No maps yet. Upload a file on Home."):
    h("div",{style:{display:"grid",gridTemplateColumns:"repeat(auto-fill,minmax(300px,1fr))",gap:14}},
      maps[0].map(function(m){return h("div",{key:m.id,style:{padding:20,background:SURF,border:"1px solid "+BRD,borderRadius:14}},
        h("div",{style:{display:"flex",alignItems:"center",gap:8,marginBottom:8}},
          h("div",{style:{fontSize:17,fontWeight:600,flex:1}},m.title||m.filename),
          h("span",{style:{fontSize:11,padding:"4px 12px",borderRadius:10,background:m.status==='confirmed'?'rgba(81,207,102,0.15)':'rgba(90,100,120,0.2)',color:m.status==='confirmed'?'#51CF66':DIM}},m.status==='confirmed'?'Confirmed':'Draft')),
        h("div",{style:{fontSize:13,color:DIM,marginBottom:12}},fmtDate(m.created_at)),
        h("div",{style:{display:"flex",gap:6,flexWrap:"wrap"}},
          h("button",{onClick:function(){loadMap(m.id);},style:B()},"Open"),
          h("button",{onClick:function(){exportMap(m.id);},style:B(DIM,"transparent")},"Export"),
          m.status!=='confirmed'?h("button",{onClick:function(){confirmMap(m.id).then(function(){getMaps().then(function(d){maps[1](d.maps||[]);});});},style:B("#51CF66","rgba(81,207,102,0.1)")},"✓ Confirm"):h("button",{onClick:function(){unconfirmMap(m.id).then(function(){getMaps().then(function(d){maps[1](d.maps||[]);});});},style:B(DIM,"transparent")},"Unconfirm"),
          m.status==='confirmed'?h("button",{onClick:function(){shareM[1]({id:m.id,title:m.title||m.filename});},style:B("#A29BFE","rgba(162,155,254,0.1)")},"Share"):null,
          h("button",{onClick:function(){if(confirm('Delete?')){deleteMap(m.id).then(function(){getMaps().then(function(d){maps[1](d.maps||[]);});});}},style:B("#FF6B6B","rgba(255,107,107,0.1)")},"Delete"))
      );})
    ),
    shareM[0]?h("div",{style:{position:"fixed",inset:0,background:"rgba(0,0,0,0.6)",display:"flex",alignItems:"center",justifyContent:"center",zIndex:100},onClick:function(){shareM[1](null);}},
      h("div",{onClick:function(e){e.stopPropagation();},style:{width:380,background:SURF,border:"1px solid "+BRD,borderRadius:16,padding:28}},
        h("h3",{style:{fontSize:18,fontWeight:600,marginBottom:12}},"Share to Community"),
        h("div",{style:{fontSize:14,color:MUT,marginBottom:16}},shareM[0].title),
        h("div",{style:{display:"flex",gap:4,flexWrap:"wrap",marginBottom:18}},["general","mathematics","physics","cs","biology","history"].map(function(d){return h("button",{key:d,onClick:function(){shareDom[1](d);},style:{padding:"5px 14px",borderRadius:6,fontSize:12,cursor:"pointer",background:shareDom[0]===d?"rgba(162,155,254,0.2)":"transparent",border:shareDom[0]===d?"1px solid rgba(162,155,254,0.4)":"1px solid "+BRD,color:shareDom[0]===d?"#A29BFE":DIM}},d);})),
        h("div",{style:{display:"flex",gap:8}},
          h("button",{onClick:function(){shareMap(shareM[0].id,shareM[0].title,'',shareDom[0]).then(function(){shareM[1](null);});},style:Object.assign({flex:1},B())},"Share"),
          h("button",{onClick:function(){shareM[1](null);},style:Object.assign({flex:1},B(DIM,"transparent"))},"Cancel")))
    ):null
  ):null;

  var communityView=view[0]==='community'?h("div",{key:"cm",style:{flex:1,padding:28,overflowY:"auto"}},
    h("h2",{style:{fontSize:20,fontWeight:600,marginBottom:18}},"Community Maps"),
    h("div",{style:{display:"flex",gap:6,flexWrap:"wrap",marginBottom:20}},["all","general","mathematics","physics","cs","biology","history"].map(function(d){return h("button",{key:d,onClick:function(){commDom[1](d);loadComm(d);},style:{padding:"7px 16px",borderRadius:8,fontSize:13,cursor:"pointer",fontWeight:500,background:commDom[0]===d?"rgba(162,155,254,0.15)":"transparent",border:commDom[0]===d?"1px solid rgba(162,155,254,0.3)":"1px solid "+BRD,color:commDom[0]===d?"#A29BFE":DIM}},d.charAt(0).toUpperCase()+d.slice(1));})),
    cmaps[0].length===0?h("div",{style:{textAlign:"center",padding:40,color:DIM}},"No community maps yet."):
    h("div",{style:{display:"grid",gridTemplateColumns:"repeat(auto-fill,minmax(300px,1fr))",gap:14}},cmaps[0].map(function(m){return h("div",{key:m.id,style:{padding:20,background:SURF,border:"1px solid "+BRD,borderRadius:14}},
      h("div",{style:{fontSize:17,fontWeight:600,marginBottom:4}},m.title),
      h("div",{style:{fontSize:12,color:DIM,marginBottom:10}},(m.domain||'general')+" · by "+(m.user_id||'anon')+" · "+fmtDate(m.created_at)),
      h("div",{style:{display:"flex",gap:6}},
        h("button",{onClick:function(){upvoteCommunityMap(m.id).then(function(){loadComm(commDom[0]);});},style:B("#FDCB6E","rgba(253,203,110,0.1)")},"↑ "+(m.upvotes||0)),
        h("button",{onClick:function(){loadMap(m.map_id);},style:B("#5EECD5","rgba(94,236,213,0.1)")},"Open")));})),
    leaders[0].length>0?h("div",{style:{marginTop:28}},
      h("h3",{style:{fontSize:17,fontWeight:600,marginBottom:12}},"Top Contributors"),
      h("div",{style:{display:"grid",gridTemplateColumns:"repeat(auto-fill,minmax(200px,1fr))",gap:8}},leaders[0].slice(0,10).map(function(u2,i){return h("div",{key:u2.id,style:{padding:12,background:SURF,border:"1px solid "+BRD,borderRadius:10,display:"flex",alignItems:"center",gap:10}},
        h("div",{style:{width:28,height:28,borderRadius:"50%",background:i<3?"rgba(253,203,110,0.2)":"rgba(90,100,120,0.15)",display:"flex",alignItems:"center",justifyContent:"center",fontSize:13,fontWeight:600,color:i<3?"#FDCB6E":DIM}},i+1),
        h("div",null,h("div",{style:{fontSize:14,fontWeight:500}},u2.display_name),h("div",{style:{fontSize:11,color:DIM}},u2.points+"pts · "+u2.level)));}))
    ):null
  ):null;

  var helpView=view[0]==='help'?h("div",{key:"hp",style:{flex:1,padding:28,overflowY:"auto",maxWidth:600,margin:"0 auto"}},
    h("h2",{style:{fontSize:20,fontWeight:600,marginBottom:18}},"Help & Feedback"),
    h("h3",{style:{fontSize:17,fontWeight:600,marginBottom:12}},"FAQ"),
    [["How do I create a mindmap?","Upload a PDF, DOCX, or TXT on the Home tab."],
     ["How do I edit concepts?","Click any concept, then click the label or description to edit."],
     ["What do the colors mean?","Purple=theory, teal=definition, blue=method, orange=example."],
     ["How do I earn points?","Upload +5, Confirm +10, Share +15, Edit +1, Upvote received +3."],
     ["Levels?","Beginner (0) → Experienced (100) → Expert (500) → Professional (2000+review) → Organizer (5000+approval)."],
     ["Keyboard shortcuts?","V=select, D=draw, E=erase, Ctrl+Z=undo, Del=remove."]
    ].map(function(qa,i){return h("div",{key:i,style:{marginBottom:10,padding:14,background:SURF,border:"1px solid "+BRD,borderRadius:10}},
      h("div",{style:{fontSize:15,fontWeight:600,marginBottom:4}},qa[0]),h("div",{style:{fontSize:14,color:MUT,lineHeight:1.5}},qa[1]));}),
    h("h3",{style:{fontSize:17,fontWeight:600,margin:"24px 0 12px"}},"Send Feedback"),
    fbSent[0]?h("div",{style:{padding:20,background:"rgba(81,207,102,0.1)",border:"1px solid rgba(81,207,102,0.2)",borderRadius:10,textAlign:"center",color:"#51CF66"}},"Thank you!"):
    h("div",null,
      h("select",{value:fbCat[0],onChange:function(e){fbCat[1](e.target.value);},style:{width:"100%",padding:"10px",background:BG,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:14,marginBottom:8}},
        ["general","bug","feature","other"].map(function(c){return h("option",{key:c,value:c},c);})),
      h("textarea",{value:fbText[0],onChange:function(e){fbText[1](e.target.value);},placeholder:"Your feedback...",rows:4,style:{width:"100%",padding:"10px",background:BG,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:14,resize:"vertical",marginBottom:8}}),
      h("button",{onClick:function(){if(fbText[0].trim()){postFeedback(fbCat[0],fbText[0]).then(function(){fbSent[1](true);});}},style:Object.assign({width:"100%"},B())},"Submit"))
  ):null;

  var palaceView=view[0]==='palace'?h("div",{key:"pl",style:{flex:1,display:"flex",alignItems:"center",justifyContent:"center",flexDirection:"column",gap:20}},
    h("div",{style:{fontSize:56}},"🏛️"),
    h("h2",{style:{fontSize:24,fontWeight:600}},"Memory Palace"),
    h("p",{style:{fontSize:16,color:DIM,maxWidth:420,textAlign:"center",lineHeight:1.7}},"Walk through your knowledge as a 3D town. Coming soon."),
    h("div",{style:{fontSize:14,color:DIM,padding:"10px 20px",border:"1px solid "+BRD,borderRadius:10}},"🚧 Under development")
  ):null;

  var accountView=view[0]==='account'?h("div",{key:"ac",style:{flex:1,padding:32,maxWidth:500,margin:"0 auto",overflowY:"auto"}},
    user[0]?h("div",null,
      h("h2",{style:{fontSize:20,fontWeight:600,marginBottom:18}},"Account"),
      h("div",{style:{padding:20,background:SURF,borderRadius:14,border:"1px solid "+BRD,marginBottom:18}},
        h("div",{style:{fontSize:18,fontWeight:600,marginBottom:4}},user[0].display_name),
        h("div",{style:{fontSize:14,color:DIM,marginBottom:14}},"@"+user[0].username),
        h("div",{style:{display:"flex",gap:24}},
          h("div",null,h("div",{style:{fontSize:28,fontWeight:700,color:"#A29BFE"}},user[0].points||0),h("div",{style:{fontSize:13,color:DIM}},"Points")),
          h("div",null,h("div",{style:{fontSize:28,fontWeight:700,color:"#5EECD5"}},user[0].level||"beginner"),h("div",{style:{fontSize:13,color:DIM}},"Level")))),
      h("div",{style:{padding:20,background:SURF,borderRadius:14,border:"1px solid "+BRD,marginBottom:18}},
        h("h3",{style:{fontSize:16,fontWeight:600,marginBottom:12}},"Settings"),
        h("div",{style:{display:"flex",justifyContent:"space-between",alignItems:"center",marginBottom:10}},h("span",{style:{fontSize:14}},"Theme"),h("button",{onClick:function(){var n=!darkMode[0];darkMode[1](n);localStorage.setItem("mycel_theme",n?"dark":"light");},style:B(DIM,"transparent")},darkMode[0]?"☀ Light":"🌙 Dark")),
        h("div",{style:{display:"flex",justifyContent:"space-between",alignItems:"center"}},h("span",{style:{fontSize:14}},"Onboarding"),h("button",{onClick:function(){onboard[1](true);},style:B(DIM,"transparent")},"Show again"))),
      h("div",{style:{padding:20,background:SURF,borderRadius:14,border:"1px solid "+BRD,marginBottom:18}},
        h("h3",{style:{fontSize:16,fontWeight:600,marginBottom:10}},"Credit System"),
        h("div",{style:{fontSize:14,color:MUT,lineHeight:1.8}},
          "Upload +5 · Confirm +10 · Share +15 · Edit +1 · Upvote +3 · Comment +2",h("br",null),
          "Beginner (0) → Experienced (100) → Expert (500)",h("br",null),
          "Professional (2000 + peer review) → Organizer (5000 + admin approval)")),
      h("button",{onClick:function(){localStorage.removeItem("mycel_uid");user[1](null);},style:B("#FF6B6B","rgba(255,107,107,0.1)")},"Log out")
    ):h("div",null,
      h("h2",{style:{fontSize:20,fontWeight:600,marginBottom:18}},authMode[0]==="login"?"Log In":"Create Account"),
      h("input",{value:authU[0],placeholder:"Username",onChange:function(e){authU[1](e.target.value);},style:{width:"100%",padding:"12px 16px",background:BG,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:15,marginBottom:10}}),
      h("input",{value:authP[0],placeholder:"Password",type:"password",onChange:function(e){authP[1](e.target.value);},style:{width:"100%",padding:"12px 16px",background:BG,border:"1px solid "+BRD,borderRadius:8,color:TXT,fontSize:15,marginBottom:14}}),
      h("button",{onClick:function(){var fn=authMode[0]==="login"?login:register;fn(authU[0],authP[0]).then(function(d){if(d.user){localStorage.setItem("mycel_uid",d.user.id);user[1](d.user);}else if(d.user_id){localStorage.setItem("mycel_uid",d.user_id);getMe().then(function(r){if(r.user)user[1](r.user);});}else{alert(d.error||"Failed");}});},style:Object.assign({width:"100%",marginBottom:10},B())},authMode[0]==="login"?"Log In":"Create Account"),
      h("button",{onClick:function(){authMode[1](authMode[0]==="login"?"register":"login");},style:Object.assign({width:"100%"},B(DIM,"transparent"))},authMode[0]==="login"?"Need an account? Register":"Already have one? Log in"))
  ):null;

  // ═══ GRAPH VIEW ═══
  var graphView=view[0]==='graph'?h("div",{key:"gr",ref:cRef,style:{flex:1,position:"relative",overflow:"hidden",cursor:cursor},onPointerDown:onDown,onPointerMove:onMove,onPointerUp:onUp,onPointerLeave:onUp,onWheel:onWheel,onDoubleClick:onDbl},
    // Dot grid
    h("div",{style:{position:"absolute",inset:0,zIndex:0,pointerEvents:"none",backgroundImage:"radial-gradient(circle,"+P.dot+" 1px,transparent 1px)",backgroundSize:Math.max(16,26*cam[0].z)+"px "+Math.max(16,26*cam[0].z)+"px",backgroundPosition:(cam[0].x%(26*cam[0].z))+"px "+(cam[0].y%(26*cam[0].z))+"px"}}),
    // SVG
    h("svg",{style:{position:"absolute",inset:0,width:"100%",height:"100%",zIndex:1,overflow:"visible"}},
      h("defs",null,h("marker",{id:"ah",viewBox:"0 0 12 12",refX:"11",refY:"6",markerWidth:"7",markerHeight:"7",orient:"auto"},h("path",{d:"M1 2L10 6L1 10",fill:"none",stroke:"context-stroke",strokeWidth:"1.5",strokeLinecap:"round"}))),
      // Drawings
      drawings.map(function(dr,i){if(dr.points.length<2)return null;var d2='M'+dr.points[0].x+' '+dr.points[0].y;for(var j=1;j<dr.points.length;j++)d2+='L'+dr.points[j].x+' '+dr.points[j].y;return h("path",{key:"dr"+i,d:d2,fill:"none",stroke:dr.color,strokeWidth:dr.width/cam[0].z,opacity:0.7,strokeLinecap:"round",transform:"translate("+cam[0].x+","+cam[0].y+") scale("+cam[0].z+")"});}),
      dp[0]&&dp[0].points.length>1?(function(){var d2='M'+dp[0].points[0].x+' '+dp[0].points[0].y;for(var j=1;j<dp[0].points.length;j++)d2+='L'+dp[0].points[j].x+' '+dp[0].points[j].y;return h("path",{d:d2,fill:"none",stroke:dp[0].color,strokeWidth:dp[0].width/cam[0].z,opacity:0.7,strokeLinecap:"round",transform:"translate("+cam[0].x+","+cam[0].y+") scale("+cam[0].z+")"});})():null,
      // Hulls
      hulls.map(function(hl){return h("path",{key:hl.key,d:hl.d,fill:P.hullFill,stroke:P.hullStroke,strokeWidth:1,transform:"translate("+cam[0].x+","+cam[0].y+") scale("+cam[0].z+")"});}),
      // Edges
      Object.keys(ep).map(function(k){return ep[k];}).reduce(function(a,b){return a.concat(b);},[]).map(function(e,i){
        var s=nm[e.source],t=nm[e.target];if(!s||!t)return null;
        var cat=edgeCat(e.relation_type),st=P.edges[cat]||P.edges.custom;var conf=e.confidence||0.5,thick=st.w*(0.5+conf*0.5);
        var hi=sel[0]===e.source||sel[0]===e.target||hov[0]===e.source||hov[0]===e.target;
        var path=(cat==='compositional'||cat==='pedagogical')?sPath(s.x,s.y,t.x,t.y):edgePath(s.x,s.y,t.x,t.y,e.idx,ep[[e.source,e.target].sort().join('|')].length);
        var tr="translate("+cam[0].x+","+cam[0].y+") scale("+cam[0].z+")";var useA=ARROW_CATS.has(cat);
        return h("g",{key:"e"+i},hi?h("path",{d:path,fill:"none",stroke:st.color,strokeWidth:thick+7,opacity:0.12,transform:tr,strokeLinecap:"round"}):null,h("path",{d:path,fill:"none",stroke:st.color,strokeWidth:hi?thick*1.5:thick,strokeDasharray:st.dash,opacity:hi?0.9:0.55,transform:tr,strokeLinecap:"round",markerEnd:useA?"url(#ah)":""}));
      }),
      // Nodes
      vn.map(function(n){
        var t=typeColor(P,n.concept_type);var isSel=sel[0]===n.id,isHov=hov[0]===n.id;
        var dl=showD?(n.dl||[]):[];var totalH=(n.lh||30)+(dl.length?dl.length*16+20:0)+(n.imgH||0);
        var sx2=n.x*cam[0].z+cam[0].x,sy2=n.y*cam[0].z+cam[0].y;
        var labelSz=impSize(n.id,14),descSz=impSize(n.id,10);
        return h("g",{key:n.id,transform:"translate("+sx2+","+sy2+") scale("+cam[0].z+")",style:{cursor:tool[0]==='select'?'pointer':'inherit'},
          onClick:function(ev){ev.stopPropagation();if(tool[0]==='magnify'){zoomTo(n.id);}else if(tool[0]==='select'){magnify(n.id,ev);}},
          onPointerDown:function(ev){if(tool[0]!=='select')return;ev.stopPropagation();var rc=cRef.current?cRef.current.getBoundingClientRect():null;if(!rc)return;var px=ev.clientX-rc.left,py=ev.clientY-rc.top;var nbrs=getNeighbors(n.id,edges);var offsets={};Object.keys(nbrs).forEach(function(id){offsets[id]={dx:(nm[id]?nm[id].x:0)-n.x,dy:(nm[id]?nm[id].y:0)-n.y};});drag[1]({t:'c',nid:n.id,nbrs:nbrs,sx:px,sy:py,ox:n.x,oy:n.y,off:offsets});ev.preventDefault();}},
          isSel?h("rect",{x:-n.w/2-6,y:-totalH/2-6,width:n.w+12,height:totalH+12,rx:14,fill:SURF,stroke:t.a,strokeWidth:2,opacity:0.95}):null,
          isHov&&!isSel?h("rect",{x:-n.w/2-4,y:-totalH/2-4,width:n.w+8,height:totalH+8,rx:12,fill:"none",stroke:t.a,strokeWidth:1,opacity:0.3,strokeDasharray:"4 3"}):null,
          h("circle",{cx:-n.w/2+6,cy:-totalH/2+6,r:4,fill:t.a,opacity:isSel?1:0.7}),
          (n.ll||[]).map(function(line,li){return h("text",{key:"l"+li,x:0,y:-totalH/2+20+li*24,textAnchor:"middle",dominantBaseline:"central",fontSize:labelSz,fontWeight:"600",fill:t.a,fontFamily:"'Inter',sans-serif",style:{pointerEvents:"none"}},line);}),
          dl.map(function(line,di){return h("text",{key:"d"+di,x:0,y:-totalH/2+(n.lh||30)+8+di*16,textAnchor:"middle",dominantBaseline:"central",fontSize:descSz,fill:t.s,opacity:0.75,fontFamily:"'Inter',sans-serif",style:{pointerEvents:"none"}},line);})
        );
      })
    ),
    // Detail card
    selN?(function(){
      var sc=w2s(selN.x,selN.y);var t=typeColor(P,selN.concept_type);var rc=cRef.current?cRef.current.getBoundingClientRect():{width:800};
      var cW=280;var cx2=Math.min(Math.max(10,sc.x+80),rc.width-cW-16);var cy2=Math.max(10,sc.y-50);
      return h("div",{style:{position:"absolute",left:cx2,top:cy2,width:cW,background:SURF,border:"1px solid "+BRD,borderRadius:14,padding:"14px 16px",boxShadow:"0 8px 32px rgba(0,0,0,0.3)",zIndex:20,maxHeight:"55vh",overflowY:"auto"}},
        h("div",{style:{display:"flex",alignItems:"center",gap:6,marginBottom:6}},
          h("div",{style:{width:8,height:8,borderRadius:"50%",background:t.a}}),
          h("select",{value:selN.concept_type,onChange:function(ev){setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(nd){if(nd.id!==sel[0])return nd;return Object.assign({},nd,{concept_type:ev.target.value});})});});},style:{fontSize:12,color:t.a,fontWeight:600,textTransform:"uppercase",background:"transparent",border:"1px solid "+t.a+"30",borderRadius:4,padding:"2px 6px",cursor:"pointer"}},["theory","principle","definition","method","example","evidence","argument","term","framework","phenomenon"].map(function(ct){return h("option",{key:ct,value:ct,style:{background:BG,color:TXT}},ct);})),
          h("span",{style:{fontSize:12,color:DIM,marginLeft:"auto"}},Math.round((selN.confidence||0)*100)+"%"),
          h("button",{onClick:function(){sel[1](null);},style:{background:"none",border:"none",color:DIM,fontSize:16,cursor:"pointer"}},"×")),
        ef[0]==='label'?h("input",{value:ev[0],onChange:function(e){ev[1](e.target.value);},autoFocus:true,
          onBlur:function(){setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(nd){if(nd.id!==sel[0])return nd;var up=Object.assign({},nd,{label:ev[0]});return Object.assign(up,nSize(up));})});});ef[1](null);},
          onKeyDown:function(e){if(e.key==='Enter')e.target.blur();if(e.key==='Escape')ef[1](null);},
          style:{width:"100%",fontSize:17,fontWeight:600,background:BG,border:"1px solid "+t.a+"50",borderRadius:8,color:t.a,padding:"4px 8px",marginBottom:6,fontFamily:"inherit"}}):
          h("h3",{onClick:function(){ef[1]('label');ev[1](selN.label);},style:{fontSize:17,fontWeight:600,marginBottom:6,cursor:"text",color:t.a}},selN.label),
        ef[0]==='desc'?h("textarea",{value:ev[0],onChange:function(e){ev[1](e.target.value);},rows:3,autoFocus:true,
          onBlur:function(){setData(function(dd){return Object.assign({},dd,{nodes:dd.nodes.map(function(nd){if(nd.id!==sel[0])return nd;var up=Object.assign({},nd,{description:ev[0]});return Object.assign(up,nSize(up));})});});ef[1](null);},
          style:{width:"100%",fontSize:14,background:BG,border:"1px solid "+t.a+"50",borderRadius:8,color:t.s,padding:"6px 8px",marginBottom:8,fontFamily:"inherit",lineHeight:1.5,resize:"vertical"}}):
          h("p",{onClick:function(){ef[1]('desc');ev[1](selN.description||'');},style:{fontSize:14,color:t.s,lineHeight:1.6,marginBottom:8,cursor:"text"}},selN.description||"Click to add"),
        h("div",{style:{display:"flex",gap:4,marginBottom:8}},
          h("button",{onClick:function(){submitCorrection({map_id:mapId[0],type:"approve",original:{id:sel[0]}}).catch(function(){});},style:B("#51CF66","rgba(81,207,102,0.1)")},"✓ Correct"),
          h("button",{onClick:function(){setData(function(dd){return{nodes:dd.nodes.filter(function(nd){return nd.id!==sel[0];}),edges:dd.edges.filter(function(ed){return ed.source!==sel[0]&&ed.target!==sel[0];}),drawings:dd.drawings};});sel[1](null);},style:B("#FF6B6B","rgba(255,107,107,0.1)")},"Remove")),
        connE.length>0?h("div",null,
          h("div",{style:{fontSize:12,color:DIM,fontWeight:600,marginBottom:4}},"Connections ("+connE.length+")"),
          connE.map(function(e,i){var isSrc=e.source===sel[0],oId=isSrc?e.target:e.source,o=nm[oId];var cat=edgeCat(e.relation_type),es=P.edges[cat]||P.edges.custom;
            return h("div",{key:i,onClick:function(){magnify(oId);},style:{padding:"6px 8px",background:BG,borderRadius:6,marginBottom:3,borderLeft:"3px solid "+es.color,cursor:"pointer"}},
              h("div",{style:{display:"flex",justifyContent:"space-between",fontSize:12}},
                h("select",{value:e.relation_type||"REQUIRES",onClick:function(ev){ev.stopPropagation();},onChange:function(ev){ev.stopPropagation();setData(function(dd){return Object.assign({},dd,{edges:dd.edges.map(function(ed){if(ed.source===e.source&&ed.target===e.target&&ed.relation_type===e.relation_type)return Object.assign({},ed,{relation_type:ev.target.value});return ed;})});});},style:{color:es.color,fontWeight:600,fontSize:10,textTransform:"uppercase",background:"transparent",border:"none",cursor:"pointer",padding:0}},["IMPLIES","REQUIRES","DEFINED_BY","CONTAINS","PART_OF","CAUSES","ENABLES","GENERALIZES","SPECIALIZES","ILLUSTRATES","EXTENDS","CONSTRAINS","CONTRADICTS","PREREQUISITE_FOR"].map(function(rt){return h("option",{key:rt,value:rt,style:{background:BG,color:TXT}},rt.replace(/_/g," "));})),
                h("span",{style:{color:DIM}},(isSrc?"→ ":"← ")+(o?o.label:"?"))));})
        ):null);
    })():null,
    // Legend
    h("div",{style:{position:"absolute",top:10,left:10,background:SURF+"DD",backdropFilter:"blur(8px)",padding:"14px 18px",borderRadius:14,border:"1px solid "+BRD,fontSize:14,zIndex:5}},
      ["theorem","definition","principle","method","framework","example"].map(function(t2){var c=P.types[t2];if(!c)return null;return h("div",{key:t2,style:{display:"flex",alignItems:"center",gap:6,marginBottom:3}},h("div",{style:{width:10,height:10,borderRadius:"50%",background:c.a}}),h("span",{style:{color:c.a}},t2));}),
      h("div",{style:{marginTop:6,borderTop:"1px solid "+BRD,paddingTop:6,color:DIM,lineHeight:1.6,fontSize:11}},"Click=magnify · Drag=move · Dbl=fold")),
    // Zoom
    h("div",{style:{position:"absolute",bottom:10,right:10,display:"flex",gap:4,zIndex:5}},
      [{l:"+",f:1.2},{l:"−",f:1/1.2},{l:"⊡",f:0}].map(function(b){return h("button",{key:b.l,onClick:function(){b.f?cam[1](function(c){return{x:c.x,y:c.y,z:Math.max(0.15,Math.min(5,c.z*b.f))};}):fit(nodes);},style:{width:56,height:56,borderRadius:12,background:SURF,border:"1px solid "+BRD,color:TXT,fontSize:24,cursor:"pointer",display:"flex",alignItems:"center",justifyContent:"center"}},b.l);}))
  ):null;

  // ═══ ASSEMBLE ═══
  return h("div",{style:{height:"100vh",display:"flex",flexDirection:"column",background:BG,color:TXT,fontFamily:"'Inter',system-ui,sans-serif"}},
    onboardView,
    headerView,
    homeView,
    libraryView,
    communityView,
    helpView,
    palaceView,
    accountView,
    graphView
  );
}
