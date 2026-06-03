#!/bin/bash
set -e
echo "🍄 Mycel — Palettes + Advanced Settings..."

# ═══ Update theme.js with all palettes ═══
cat > frontend/src/utils/theme.js << 'THEOF'
// All palettes — dark and light
export var PALETTES = {
  aurora: {
    name:"Aurora",mode:"dark",bg:"#0B1120",surface:"#131B2E",border:"#1E2A45",
    text:"#E8ECF4",muted:"#8B95A8",dim:"#5A6478",
    dot:"#1E2A4518",hullFill:"#ffffff04",hullStroke:"#ffffff0C",
    types:{
      theory:{a:"#B8B0FF",s:"#9890E8",b:"#6C5CE750"},
      principle:{a:"#9AA4E0",s:"#7B88C8",b:"#5B6ABF50"},
      definition:{a:"#5EECD5",s:"#40C8B0",b:"#00B8A950"},
      method:{a:"#63B3F3",s:"#4898D8",b:"#0984E350"},
      example:{a:"#F0A08A",s:"#D88870",b:"#E1705550"},
      evidence:{a:"#F7C463",s:"#D8A848",b:"#F39C1250"},
      argument:{a:"#E87070",s:"#D05858",b:"#D6303150"},
      term:{a:"#5EE8E4",s:"#40C8C4",b:"#00CEC950"},
      framework:{a:"#C8C3FF",s:"#A8A0E8",b:"#A29BFE50"},
      phenomenon:{a:"#FEA8C8",s:"#E090B0",b:"#FD79A850"},
    },
    edges:{logical:{color:"#A29BFE",w:3.5,dash:""},compositional:{color:"#74B9FF",w:3,dash:"10 5"},pedagogical:{color:"#FD79A8",w:2.5,dash:"5 4"},causal:{color:"#FDCB6E",w:3.5,dash:""},custom:{color:"#55EFC4",w:2.5,dash:"8 4"}},
  },
  dracula: {
    name:"Dracula",mode:"dark",bg:"#282A36",surface:"#44475A",border:"#6272A4",
    text:"#F8F8F2",muted:"#BFBFBF",dim:"#6272A4",
    dot:"#6272A418",hullFill:"#ffffff04",hullStroke:"#ffffff0C",
    types:{
      theory:{a:"#BD93F9",s:"#A77BDF",b:"#BD93F950"},
      principle:{a:"#8BE9FD",s:"#6DD4E8",b:"#8BE9FD50"},
      definition:{a:"#50FA7B",s:"#3ADE65",b:"#50FA7B50"},
      method:{a:"#FFB86C",s:"#E0A050",b:"#FFB86C50"},
      example:{a:"#F1FA8C",s:"#D8E070",b:"#F1FA8C50"},
      evidence:{a:"#FF79C6",s:"#E060B0",b:"#FF79C650"},
      argument:{a:"#FF5555",s:"#E04040",b:"#FF555550"},
      term:{a:"#8BE9FD",s:"#6DD4E8",b:"#8BE9FD50"},
      framework:{a:"#BD93F9",s:"#A77BDF",b:"#BD93F950"},
      phenomenon:{a:"#FF79C6",s:"#E060B0",b:"#FF79C650"},
    },
    edges:{logical:{color:"#BD93F9",w:3.5,dash:""},compositional:{color:"#8BE9FD",w:3,dash:"10 5"},pedagogical:{color:"#FF79C6",w:2.5,dash:"5 4"},causal:{color:"#FFB86C",w:3.5,dash:""},custom:{color:"#50FA7B",w:2.5,dash:"8 4"}},
  },
  nord: {
    name:"Nord",mode:"dark",bg:"#2E3440",surface:"#3B4252",border:"#4C566A",
    text:"#ECEFF4",muted:"#D8DEE9",dim:"#616E88",
    dot:"#4C566A18",hullFill:"#ffffff04",hullStroke:"#ffffff0C",
    types:{
      theory:{a:"#B48EAD",s:"#A07098",b:"#B48EAD50"},
      principle:{a:"#81A1C1",s:"#6B8BAB",b:"#81A1C150"},
      definition:{a:"#A3BE8C",s:"#8DA876",b:"#A3BE8C50"},
      method:{a:"#88C0D0",s:"#70AABA",b:"#88C0D050"},
      example:{a:"#EBCB8B",s:"#D5B575",b:"#EBCB8B50"},
      evidence:{a:"#D08770",s:"#BA715A",b:"#D0877050"},
      argument:{a:"#BF616A",s:"#A94B54",b:"#BF616A50"},
      term:{a:"#8FBCBB",s:"#79A6A5",b:"#8FBCBB50"},
      framework:{a:"#5E81AC",s:"#486B96",b:"#5E81AC50"},
      phenomenon:{a:"#B48EAD",s:"#A07098",b:"#B48EAD50"},
    },
    edges:{logical:{color:"#B48EAD",w:3.5,dash:""},compositional:{color:"#88C0D0",w:3,dash:"10 5"},pedagogical:{color:"#BF616A",w:2.5,dash:"5 4"},causal:{color:"#EBCB8B",w:3.5,dash:""},custom:{color:"#A3BE8C",w:2.5,dash:"8 4"}},
  },
  tokyo: {
    name:"Tokyo Night",mode:"dark",bg:"#1A1B26",surface:"#24283B",border:"#3B4261",
    text:"#C0CAF5",muted:"#9AA5CE",dim:"#565F89",
    dot:"#3B426118",hullFill:"#ffffff04",hullStroke:"#ffffff0C",
    types:{
      theory:{a:"#BB9AF7",s:"#A584E1",b:"#BB9AF750"},
      principle:{a:"#7AA2F7",s:"#648CE1",b:"#7AA2F750"},
      definition:{a:"#9ECE6A",s:"#88B854",b:"#9ECE6A50"},
      method:{a:"#7DCFFF",s:"#67B9E9",b:"#7DCFFF50"},
      example:{a:"#FF9E64",s:"#E9884E",b:"#FF9E6450"},
      evidence:{a:"#E0AF68",s:"#CA9952",b:"#E0AF6850"},
      argument:{a:"#F7768E",s:"#E16078",b:"#F7768E50"},
      term:{a:"#73DACA",s:"#5DC4B4",b:"#73DACA50"},
      framework:{a:"#2AC3DE",s:"#14ADC8",b:"#2AC3DE50"},
      phenomenon:{a:"#FF9E64",s:"#E9884E",b:"#FF9E6450"},
    },
    edges:{logical:{color:"#BB9AF7",w:3.5,dash:""},compositional:{color:"#7DCFFF",w:3,dash:"10 5"},pedagogical:{color:"#F7768E",w:2.5,dash:"5 4"},causal:{color:"#E0AF68",w:3.5,dash:""},custom:{color:"#9ECE6A",w:2.5,dash:"8 4"}},
  },
  // ── LIGHT PALETTES ──
  notion: {
    name:"Notion",mode:"light",bg:"#FFFFFF",surface:"#F7F7F5",border:"#E8E8E3",
    text:"#37352F",muted:"#6B6B6B",dim:"#9B9A97",
    dot:"#E8E8E318",hullFill:"#00000004",hullStroke:"#0000000C",
    types:{
      theory:{a:"#6940A5",s:"#8B5CF6",b:"#6940A530"},
      principle:{a:"#0B6E99",s:"#2E8FBD",b:"#0B6E9930"},
      definition:{a:"#0F7B6C",s:"#4DAB9A",b:"#0F7B6C30"},
      method:{a:"#2E7CF6",s:"#5B9AFF",b:"#2E7CF630"},
      example:{a:"#D9730D",s:"#E9830C",b:"#D9730D30"},
      evidence:{a:"#DFAB01",s:"#F0C000",b:"#DFAB0130"},
      argument:{a:"#E03E3E",s:"#F05050",b:"#E03E3E30"},
      term:{a:"#0B6E99",s:"#2E8FBD",b:"#0B6E9930"},
      framework:{a:"#6940A5",s:"#8B5CF6",b:"#6940A530"},
      phenomenon:{a:"#AD1A72",s:"#D53F8C",b:"#AD1A7230"},
    },
    edges:{logical:{color:"#6940A5",w:3.5,dash:""},compositional:{color:"#2E7CF6",w:3,dash:"10 5"},pedagogical:{color:"#AD1A72",w:2.5,dash:"5 4"},causal:{color:"#D9730D",w:3.5,dash:""},custom:{color:"#0F7B6C",w:2.5,dash:"8 4"}},
  },
  paper: {
    name:"Paper",mode:"light",bg:"#FAF8F5",surface:"#FFFFFF",border:"#E8E0D4",
    text:"#3D3229",muted:"#6B5A48",dim:"#9C8B78",
    dot:"#E8E0D418",hullFill:"#00000004",hullStroke:"#0000000C",
    types:{
      theory:{a:"#6B4F8A",s:"#8B6FB0",b:"#6B4F8A30"},
      principle:{a:"#2C5282",s:"#4A70A0",b:"#2C528230"},
      definition:{a:"#2E8B8B",s:"#4AABAB",b:"#2E8B8B30"},
      method:{a:"#4A6FA5",s:"#6A8FC5",b:"#4A6FA530"},
      example:{a:"#C78D33",s:"#E0A850",b:"#C78D3330"},
      evidence:{a:"#598B6E",s:"#79AB8E",b:"#598B6E30"},
      argument:{a:"#943B4F",s:"#B45B6F",b:"#943B4F30"},
      term:{a:"#2C5282",s:"#4A70A0",b:"#2C528230"},
      framework:{a:"#6B4F8A",s:"#8B6FB0",b:"#6B4F8A30"},
      phenomenon:{a:"#D4726A",s:"#F0928A",b:"#D4726A30"},
    },
    edges:{logical:{color:"#6B4F8A",w:3.5,dash:""},compositional:{color:"#4A6FA5",w:3,dash:"10 5"},pedagogical:{color:"#943B4F",w:2.5,dash:"5 4"},causal:{color:"#C78D33",w:3.5,dash:""},custom:{color:"#598B6E",w:2.5,dash:"8 4"}},
  },
  ice: {
    name:"Ice",mode:"light",bg:"#F0F4F8",surface:"#FFFFFF",border:"#D9E2EC",
    text:"#243B53",muted:"#486581",dim:"#829AB1",
    dot:"#D9E2EC18",hullFill:"#00000004",hullStroke:"#0000000C",
    types:{
      theory:{a:"#6366F1",s:"#8183FF",b:"#6366F130"},
      principle:{a:"#3B82F6",s:"#60A0FF",b:"#3B82F630"},
      definition:{a:"#10B981",s:"#30D9A1",b:"#10B98130"},
      method:{a:"#3B82F6",s:"#60A0FF",b:"#3B82F630"},
      example:{a:"#F59E0B",s:"#FFBE30",b:"#F59E0B30"},
      evidence:{a:"#8B5CF6",s:"#AB7CFF",b:"#8B5CF630"},
      argument:{a:"#F43F5E",s:"#FF6080",b:"#F43F5E30"},
      term:{a:"#06B6D4",s:"#26D6F4",b:"#06B6D430"},
      framework:{a:"#6366F1",s:"#8183FF",b:"#6366F130"},
      phenomenon:{a:"#EC4899",s:"#FF68B9",b:"#EC489930"},
    },
    edges:{logical:{color:"#6366F1",w:3.5,dash:""},compositional:{color:"#3B82F6",w:3,dash:"10 5"},pedagogical:{color:"#EC4899",w:2.5,dash:"5 4"},causal:{color:"#F59E0B",w:3.5,dash:""},custom:{color:"#10B981",w:2.5,dash:"8 4"}},
  },
};

var EC={logical:["IMPLIES","REQUIRES","CONTRADICTS","EQUIVALENT","GENERALIZES","SPECIALIZES"],compositional:["PART_OF","CONTAINS","INSTANCE_OF","DEFINED_BY"],pedagogical:["PREREQUISITE_FOR","ILLUSTRATES","EXTENDS","CONTRASTS_WITH"],causal:["CAUSES","ENABLES","CONSTRAINS","ANALOGOUS_TO"]};
export var ARROW_CATS=new Set(["logical","causal"]);
export function edgeCat(t){for(var c in EC)if(EC[c].indexOf(t)>=0)return c;return"custom";}
export function typeColor(P,t){return P.types[t]||P.types.term;}
export function importanceFontSize(d,c,md){var raw=(d/Math.max(md,1))*0.6+c*0.4;return Math.round(11+raw*11);}
THEOF
echo "  ✓ theme.js — 7 palettes (4 dark + 3 light)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🍄 Palettes installed!"
echo ""
echo "PALETTES AVAILABLE:"
echo "  Dark:  aurora (default), dracula, nord, tokyo"
echo "  Light: notion, paper, ice"
echo ""
echo "TO USE IN App.jsx:"
echo "  1. Add palette state:"
echo '     var palName = useState(localStorage.getItem("mycel_palette") || "aurora");'
echo ""
echo "  2. Change palette reference:"
echo '     var P = PALETTES[palName[0]];'
echo ""
echo "  3. Update dark/light based on palette:"
echo '     var isDark = P.mode === "dark";'
echo '     var BG = P.bg, SURF = P.surface, BRD = P.border;'
echo '     var TXT = P.text, DIM = P.dim, MUT = P.muted;'
echo ""
echo "  4. Add palette picker in Account/Settings:"
echo '     h("div",{style:{display:"flex",gap:4,flexWrap:"wrap",marginBottom:12}},'
echo '       Object.keys(PALETTES).map(function(k){'
echo '         var p=PALETTES[k];'
echo '         return h("button",{key:k,onClick:function(){'
echo '           palName[1](k);localStorage.setItem("mycel_palette",k);'
echo '         },style:{padding:"6px 12px",borderRadius:6,fontSize:12,'
echo '           background:palName[0]===k?p.bg:"transparent",'
echo '           border:palName[0]===k?"2px solid "+p.types.theory.a:"1px solid "+BRD,'
echo '           color:palName[0]===k?p.text:DIM}},p.name);'
echo '       })'
echo '     )'
echo ""
echo "  5. Add leaderboard visibility toggle in Account:"
echo '     var showInLeaderboard = useState(localStorage.getItem("mycel_leaderboard")!=="false");'
echo '     // Toggle button:'
echo '     h("div",{style:{display:"flex",justifyContent:"space-between",alignItems:"center"}},'
echo '       h("span",null,"Show in leaderboard"),'
echo '       h("button",{onClick:function(){'
echo '         var n=!showInLeaderboard[0];showInLeaderboard[1](n);'
echo '         localStorage.setItem("mycel_leaderboard",n?"true":"false");'
echo '       },style:B(DIM,"transparent")},showInLeaderboard[0]?"Visible":"Hidden"))'
echo ""
echo "DEPLOY: git add -A && git commit -m 'palettes + split view' && git push"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"