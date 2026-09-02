import Foundation

/// Kept as a raw string so the injected Gemini probe stays readable.
enum GeminiProbeScript {
    /// Appended after `ChromeTabMonitor.generatingHelperJavaScript`.
    static let body = #"""
function isProcessOnly(t){var s=(t||'').toLowerCase().replace(/\s+/g,' ').trim();if(!s)return true;var stages=['thinking','thoughts','researching','searching','analyzing','writing','crafting','planning','working','generating','reasoning','reading','browsing','synthesizing','reflecting','compiling','drafting','connecting','considering'];var tokens=s.split(/[^a-z]+/).filter(Boolean);if(!tokens.length)return true;if(tokens.every(function(w){return stages.indexOf(w)!==-1;}))return true;if(tokens.length<=4&&stages.indexOf(tokens[0])!==-1)return true;return false;}
function cleanText(t){var s=(t||'').replace(/Show message actions for /ig,'').replace(/Gemini said:?\s*/ig,'').replace(/You said:?\s*/ig,'').replace(/\bjust now\b/ig,' ').replace(/\b\d+\s*(second|minute|hour|day|week|month|year)s?\s+ago\b/ig,' ').replace(/\byesterday\b/ig,' ').replace(/[\uE000-\uF8FF]/g,' ').replace(/\s+/g,' ').trim();return s;}
function makeFingerprint(t){var s=cleanText(t);if(!s)return '';return s.length+'#'+s.slice(0,200);}
function isInDOM(node){if(!node)return false;try{if(node.closest('[hidden],template'))return false;var style=window.getComputedStyle?window.getComputedStyle(node):null;if(style&&(style.display==='none'||style.visibility==='hidden'))return false;}catch(e){}return true;}
function collectNodes(selectors,skipProcessOnly){var entries=[];var seen={};for(var s=0;s<selectors.length;s++){var nodes=document.querySelectorAll(selectors[s]);for(var i=0;i<nodes.length;i++){var node=nodes[i];if(!isInDOM(node))continue;var t=cleanText(node.innerText||node.textContent||'');if(!t)continue;if(skipProcessOnly&&isProcessOnly(t))continue;var key=t.slice(0,240);if(seen[key]!==undefined){entries[seen[key]]={text:t,node:node,order:seen[key]};continue;}seen[key]=entries.length;entries.push({text:t,node:node,order:entries.length});}}return entries;}
function collectUserAnchors(){return collectNodes(['user-query','.query-text','.user-query','[data-test-id="user-query"]','[data-role="user"]','.user-query-container','.query-text-line'],false);}
function collectAssistantsAfter(latestUser){var all=collectNodes(['model-response','.model-response-text','.model-response','[data-test-id="model-response"]','[data-message-author="model"]','[data-role="model"]','message-content','.markdown-main-panel','.markdown-content','.response-container'],true);if(!all.length)return [];if(!latestUser||!latestUser.node)return [all[all.length-1]];var following=all.filter(function(entry){try{return !!(latestUser.node.compareDocumentPosition(entry.node)&Node.DOCUMENT_POSITION_FOLLOWING);}catch(e){return entry.order>=latestUser.order;}});if(!following.length)return [];var best=following[0];for(var i=1;i<following.length;i++){if(following[i].text.length>=best.text.length)best=following[i];}return [best];}
function extractStreamText(body){
  var s=String(body||'');
  var best='';
  function consider(raw){
    var t=String(raw||'').replace(/\\n/g,' ').replace(/\\"/g,'"').replace(/\\u003c/g,'<');
    t=cleanText(t);
    if(t.length<=best.length)return;
    if(t.indexOf('http')===0)return;
    if(t.charAt(0)==='{'||t.charAt(0)==='[')return;
    if(isProcessOnly(t))return;
    var words=t.split(/\s+/).filter(Boolean);
    if(words.length<2&&t.length<48)return;
    best=t;
  }
  function walk(v,depth){
    if(depth>8||v==null)return;
    if(typeof v==='string'){
      consider(v);
      if(v.length>12&&(v.charAt(0)==='['||v.charAt(0)==='{')){try{walk(JSON.parse(v),depth+1);}catch(e){}}
      return;
    }
    if(typeof v!=='object')return;
    if(Array.isArray(v)){for(var i=0;i<v.length;i++)walk(v[i],depth+1);}
  }
  try{
    var rest=s.replace(/^\)\]\}'\s*/,'');
    var i=0;
    while(i<rest.length){
      while(i<rest.length&&(rest.charAt(i)==='\n'||rest.charAt(i)==='\r'||rest.charAt(i)===' '))i++;
      var n='';
      while(i<rest.length&&rest.charAt(i)>='0'&&rest.charAt(i)<='9'){n+=rest.charAt(i);i++;}
      if(!n)break;
      if(rest.charAt(i)==='\n'||rest.charAt(i)==='\r')i++;
      var len=parseInt(n,10);
      if(!(len>0)||i+len>rest.length+32)break;
      var frame=rest.substr(i,len);i+=len;
      try{walk(JSON.parse(frame),0);}catch(e0){consider(frame);}
    }
  }catch(e1){}
  if(!best){
    var re=/"((?:\\.|[^"\\]){32,})"/g;
    var m;
    while((m=re.exec(s)))consider(m[1]);
    re=/"text"\s*:\s*"((?:\\.|[^"\\]){8,})"/g;
    while((m=re.exec(s)))consider(m[1]);
  }
  return best.slice(0,800);
}
function isStreamURL(u){u=String(u||'').toLowerCase();return u.indexOf('streamgenerate')!==-1||u.indexOf('bardfrontendservice')!==-1||u.indexOf('assistant.lamda')!==-1||u.indexOf('batchexecute')!==-1||u.indexOf('bardchatui')!==-1||u.indexOf('/_/bard')!==-1||u.indexOf('generatefreeformstreamed')!==-1||u.indexOf('generatecontent')!==-1;}
window.__islandGeminiIsStreamURL=isStreamURL;
function matchesGeminiStream(u){var fn=window.__islandGeminiIsStreamURL;return typeof fn==='function'?fn(u):isStreamURL(u);}
function installStreamCapture(){
  var net=window.__islandGeminiNet;
  if(net&&net.v>=24) return net;
  net={v:24,pending:0,token:'',preview:''};
  function noteStart(u){if(!matchesGeminiStream(u))return; net.pending++;}
  function noteEnd(u,body){
    if(!matchesGeminiStream(u))return;
    net.pending=Math.max(0,net.pending-1);
    var text=extractStreamText(body);
    if(text.length>=8){net.preview=text; net.token=String(Date.now())+':'+text.length;}
    else if(!net.token){net.token=String(Date.now())+':end';}
  }
  if(!window.__islandGeminiFetchHooked){
    window.__islandGeminiFetchHooked=true;
  var XO=XMLHttpRequest.prototype.open;
  var XS=XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open=function(method,url){try{this.__islandU=url;}catch(e){}return XO.apply(this,arguments);};
  XMLHttpRequest.prototype.send=function(){
    var u=this.__islandU||'';
    noteStart(u);
    try{
      this.addEventListener('progress',function(){try{var t=extractStreamText(this.responseText);if(t.length>=8)net.preview=t;}catch(e0){}});
      this.addEventListener('loadend',function(){try{noteEnd(u,this.responseText);}catch(e1){noteEnd(u,'');}});
    }catch(e2){}
    return XS.apply(this,arguments);
  };
  var OF=window.fetch;
  if(typeof OF==='function'){
    window.fetch=function(input,init){
      var u=typeof input==='string'?input:(input&&input.url)||'';
      noteStart(u);
      return OF.apply(this,arguments).then(function(res){
        if(matchesGeminiStream(u)){
          try{res.clone().text().then(function(t){noteEnd(u,t);}).catch(function(){noteEnd(u,'');});}
          catch(e){noteEnd(u,'');}
        }
        return res;
      }).catch(function(err){
        if(matchesGeminiStream(u)) noteEnd(u,'');
        throw err;
      });
    };
  }
  }
  window.__islandGeminiNet=net;
  window.__islandGeminiCaptureVersion=24;
  return net;
}
function installVisibilitySpoof(){
  var info={captureVersion:0,spoofVersion:0,spoofed:false,errors:[]};
  try{
    if((window.__islandGeminiVisibilityVersion||0)<1){
      Object.defineProperty(document,'hidden',{get:function(){return false;},configurable:true});
      Object.defineProperty(document,'visibilityState',{get:function(){return 'visible';},configurable:true});
      try{Object.defineProperty(document,'webkitHidden',{get:function(){return false;},configurable:true});}catch(e1){}
      window.__islandGeminiVisibilityVersion=1;
      document.dispatchEvent(new Event('visibilitychange'));
    }
    info.spoofed=true;
  }catch(e2){info.errors.push(String(e2&&e2.message||e2));}
  info.spoofVersion=window.__islandGeminiVisibilityVersion||0;
  return info;
}
var installInfo=installVisibilitySpoof();
var net=installStreamCapture();
installInfo.captureVersion=window.__islandGeminiCaptureVersion||0;
var foundDOM=!!(document.querySelector('user-query')||document.querySelector('.query-text')||document.querySelector('.user-query')||document.querySelector('[data-test-id="user-query"]')||document.querySelector('.ql-editor')||document.querySelector('rich-textarea')||document.querySelector('model-response')||document.querySelector('.model-response')||document.querySelector('.model-response-text')||document.querySelector('message-content')||document.querySelector('.markdown-main-panel'));
var userEntries=collectUserAnchors();
var latestUser=userEntries.length?userEntries[userEntries.length-1]:null;
var assistantEntries=collectAssistantsAfter(latestUser);
var texts=assistantEntries.map(function(entry){return entry.text;});
var text=texts.length?texts[texts.length-1]:'';
var words=text?text.split(/\s+/).filter(Boolean).slice(0,40).join(' '):'';
var preview=!isProcessOnly(words)&&words.length>=8?words:'';
if(net.preview&&(net.token||net.pending>0)){
  var netWords=net.preview.split(/\s+/).filter(Boolean).slice(0,40).join(' ');
  var netP=!isProcessOnly(netWords)&&netWords.length>=8?netWords:'';
  var netHead=netP?netP.slice(0,Math.min(40,netP.length)):'';
  var domHasNet=!!(preview&&netHead&&preview.indexOf(netHead)!==-1);
  if(netP&&(!preview||net.pending>0||!domHasNet||netP.length>=preview.length||!assistantEntries.length)){
    text=net.preview;
    words=netWords;
    preview=netP;
  }
}
var generating=scanGenerating(document,0)||(net.pending>0&&!net.token)||(words.length>0&&isProcessOnly(words)&&!preview);
var anchored=!!((latestUser&&assistantEntries.length&&preview)||(latestUser&&preview&&net.token));
return JSON.stringify({isGenerating:generating,preview:preview,foundDOM:foundDOM||!!preview,textLength:text.length,assistantCount:Math.max(texts.length,preview?1:0),latestUserPrompt:latestUser?latestUser.text:'',latestUserFingerprint:latestUser?makeFingerprint(latestUser.text):'',replyFingerprint:makeFingerprint(text),replyAnchoredToLatestUser:anchored,networkCompletionToken:net.token||'',captureVersion:installInfo.captureVersion,visibilitySpoofVersion:installInfo.spoofVersion,visibilitySpoofed:installInfo.spoofed,networkPending:net.pending});
"""#
}
