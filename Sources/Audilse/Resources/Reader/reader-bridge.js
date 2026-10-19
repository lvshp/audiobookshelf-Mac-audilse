/* Audilse native-reader bridge. No server URLs or credentials enter this document. */
(()=>{
 let book, rendition, epubLocationsReady=false, mobi, mobiIndex=0, frame, mobiTracking, lastMobiLocation='', settings={fontSize:20,fontFamily:'serif',theme:'paper'};
 let openGeneration=0, disposeEPUB=()=>{};
 const emit=(type,value)=>window.webkit?.messageHandlers?.reader?.postMessage({type,value});
 const fail=error=>emit('error',String(error?.message||error));
 const bytes=base64=>Uint8Array.from(atob(base64),c=>c.charCodeAt(0));
 const colors=()=>settings.theme==='dark'?{background:'#1f2024',color:'#eee9df'}:settings.theme==='sepia'?{background:'#efe3ca',color:'#493c28'}:{background:'#faf8f4',color:'#252321'};
 const css=()=>{let c=colors();return `body{background:${c.background}!important;color:${c.color}!important;font-size:${settings.fontSize}px!important;font-family:${settings.fontFamily}!important;line-height:1.65!important;padding:0 28px!important;box-sizing:border-box}img,svg{max-width:100%!important;height:auto}a{color:#a47a36}`};
 function style(){document.body.style.background=colors().background;if(rendition){rendition.themes.default({body:{'background':colors().background,'color':colors().color,'font-size':settings.fontSize+'px','font-family':settings.fontFamily,'line-height':'1.65'}});rendition.themes.fontSize(settings.fontSize+'px');rendition.themes.font(settings.fontFamily);}if(frame?.contentDocument){let doc=frame.contentDocument;let el=doc.getElementById('shelf-style');if(!el){el=doc.createElement('style');el.id='shelf-style';doc.head.append(el)}el.textContent=css()}}
 const flatten=(entries,depth=0)=>entries.flatMap(x=>[{id:x.href,title:x.label||x.title||'',depth},...flatten(x.subitems||[],depth+1)]);
 async function mobiDisplay(index,anchor,restoreFraction=0){mobiIndex=Math.max(0,Math.min(index,mobi.sections.length-1));while(mobi.sections[mobiIndex]?.linear==='no'&&mobiIndex<mobi.sections.length-1)mobiIndex++;let url=await mobi.sections[mobiIndex].load();if(!frame){frame=document.createElement('iframe');frame.setAttribute('sandbox','allow-same-origin');document.getElementById('viewer').replaceChildren(frame)}frame.onload=()=>{style();let doc=frame.contentDocument;if(restoreFraction>0){frame.contentWindow.scrollTo(0,Math.max(0,doc.documentElement.scrollHeight-frame.clientHeight)*restoreFraction)}if(anchor){try{anchor(doc)?.scrollIntoView()}catch{}}doc.addEventListener('click',async e=>{let a=e.target.closest('a');if(!a)return;e.preventDefault();let href=a.getAttribute('href');if(mobi.isExternal?.(href))return;try{let target=await mobi.resolveHref(href);if(target)await mobiDisplay(target.index,target.anchor)}catch(error){fail(error)}});frame.contentWindow.addEventListener('scroll',()=>{let h=Math.max(1,doc.documentElement.scrollHeight-frame.clientHeight);emit('location',{location:`mobi:${mobiIndex}:${Math.round((doc.documentElement.scrollTop||doc.body.scrollTop)/h*1000)}`,progress:(mobiIndex+(doc.documentElement.scrollTop||0)/h)/mobi.sections.length})},{passive:true});let h=Math.max(1,doc.documentElement.scrollHeight-frame.clientHeight);let fraction=(doc.documentElement.scrollTop||doc.body.scrollTop||0)/h;emit('location',{location:`mobi:${mobiIndex}:${Math.round(fraction*1000)}`,progress:(mobiIndex+fraction)/mobi.sections.length})};frame.src=url;if(!mobiTracking)mobiTracking=setInterval(()=>{if(!frame?.contentDocument?.body)return;let doc=frame.contentDocument;let h=Math.max(1,doc.documentElement.scrollHeight-frame.clientHeight);let fraction=Math.min(1,Math.max(0,frame.contentWindow.scrollY/h));let location=`mobi:${mobiIndex}:${Math.round(fraction*1000)}`;if(location!==lastMobiLocation){lastMobiLocation=location;emit('location',{location,progress:(mobiIndex+fraction)/mobi.sections.length})}},250)}
 // epubjs 0.3.93 queues request their first tick inside Rendition's constructor.
 // Install per-instance scheduling before that enqueue; never replace window RAF.
 function createEPUBRendition(openedBook){
  let stopped=false, destroyed=false, resolveCancelled;
  const destroyBook=()=>{if(!destroyed){destroyed=true;openedBook.destroy()}};
  const cancelled=new Promise(resolve=>{resolveCancelled=resolve});
  const pending=new Set();
  function tick(callback){
   if(stopped)return;
   let frameID, timerID, done=false;
   const cancel=()=>{if(done)return;done=true;cancelAnimationFrame(frameID);clearTimeout(timerID);pending.delete(cancel)};
   const fire=time=>{if(done||stopped)return;cancel();callback(time)};
   pending.add(cancel);
   frameID=requestAnimationFrame(fire);
   timerID=setTimeout(()=>fire(performance.now()),250);
   return frameID;
  }
  class ScheduledRendition extends ePub.Rendition {
   get q(){return this.shelfQueue}
   set q(queue){queue.tick=tick;this.shelfQueue=queue}
   // The fixed library also schedules a bare RAF inside reportLocation.
   // Keep that callback in the same cancellable per-rendition scheduler.
   reportLocation(){return this.q.enqueue(()=>{tick(()=>{
    if(stopped)return;
    Promise.resolve(this.manager.currentLocation()).then(value=>{
     if(stopped||!value)return;
     const location=this.located(value);
     if(!location?.start||!location?.end)return;
     this.location=location;
     this.emit('locationChanged',{index:location.start.index,href:location.start.href,start:location.start.cfi,end:location.end.cfi,percentage:location.start.percentage});
     this.emit('relocated',location);
    });
   });})}
  }
  const rendered=new ScheduledRendition(openedBook,{width:'100%',height:'100%',spread:'none',allowScriptedContent:false,allowPopups:false});
  // Match Book.renderTo: keep book ownership and enqueue the same attachment.
  openedBook.rendition=rendered;
  rendered.on('started',()=>{if(rendered.manager?.q)rendered.manager.q.tick=tick});
  // Indexing does not require a paint frame. Yield between sections without
  // paying the rendering queue's 250 ms fallback for every spine item.
  openedBook.locations.q.tick=callback=>{
   if(stopped)return;
   let timerID;
   const cancel=()=>{clearTimeout(timerID);pending.delete(cancel)};
   pending.add(cancel);
   timerID=setTimeout(()=>{cancel();if(!stopped)callback(performance.now())},0);
   return timerID;
  };
  // epubjs 0.3.93 Locations.process awaits this timer after each section.
  openedBook.locations.pause=10;
  rendered.attachTo('viewer');
  return {rendered,wait:promise=>Promise.race([promise,cancelled]),dispose(openingFailed=false){
   if(stopped){if(openingFailed)destroyBook();return}stopped=true;resolveCancelled();
   for(const cancel of [...pending])cancel();
   rendered.q.stop();rendered.manager?.q?.stop();openedBook.locations?.q?.stop();
   // The default manager cannot destroy before attachTo has built its stage.
   // Its constructor has no DOM/listeners to release; its queue is stopped above.
   if(rendered.manager&&!rendered.manager.rendered)rendered.manager=undefined;
   // Wait for opening to settle before destroying its parsing structures.
   if(openingFailed)destroyBook();
   else openedBook.opened.then(destroyBook,()=>rendered.destroy());
  }};
 }
 window.addEventListener('pagehide',()=>{openGeneration++;disposeEPUB()});
 window.ShelfReader={
 async open(base64,format,location,options){
  const generation=++openGeneration;disposeEPUB();disposeEPUB=()=>{};book=undefined;rendition=undefined;epubLocationsReady=false;
  let failed=false;
  const current=()=>generation===openGeneration&&!failed;
  try{
   settings={...settings,...options};const data=bytes(base64);
   if(format==='epub'){
    const openedBook=ePub(data.buffer);book=openedBook;
    const session=createEPUBRendition(openedBook);disposeEPUB=session.dispose;
    const rendered=session.rendered;rendition=rendered;
    let displayed=false;
    const reportLocation=loc=>{
     if(!current()||!displayed||!loc?.start?.cfi)return;
     const value={location:loc.start.cfi};
     // CFI persistence must not wait for the whole-book percentage index.
     if(epubLocationsReady){
      const progress=openedBook.locations.percentageFromCfi(loc.end?.cfi||loc.start.cfi);
      if(Number.isFinite(progress))value.progress=progress;
     }
     emit('location',value);
    };
    rendered.on('relocated',reportLocation);
    emit('progressPending',true);
    // epubjs emits these failures without rejecting ready/display. End the
    // native loading state once and release this opening's pending waits.
    const reportError=(error,openingFailed=false)=>{
     if(current()){failed=true;fail(error)}
     session.dispose(openingFailed);
    };
    openedBook.on('openFailed',error=>reportError(error,true));
    rendered.on('displayerror',error=>reportError(error));
    await session.wait(openedBook.ready);if(!current())return;
    const navigation=await session.wait(openedBook.loaded.navigation);if(!current())return;
    emit('toc',flatten(navigation.toc));style();
    await session.wait(rendered.display(location?.startsWith('epubcfi(')?location:undefined));if(!current())return;
    displayed=true;emit('ready',true);reportLocation(rendered.currentLocation());
    await session.wait(openedBook.locations.generate(1600));if(!current())return;
    epubLocationsReady=true;reportLocation(rendered.currentLocation());emit('progressPending',false);
   }else{const unzlib=async array=>new Uint8Array(await new Response(new Blob([array]).stream().pipeThrough(new DecompressionStream('deflate'))).arrayBuffer());mobi=await new window.ShelfMOBI({unzlib}).open(new File([data],'book.'+format));emit('toc',flatten(mobi.toc||[]));let match=/^mobi:(\d+):(\d+)$/.exec(location||'');await mobiDisplay(match?Number(match[1]):0,undefined,match?Number(match[2])/1000:0);emit('ready',true)}}catch(error){if(current()){failed=true;disposeEPUB();fail(error)}}},
 async next(){try{if(rendition)await rendition.next();else if(frame){let win=frame.contentWindow;let doc=frame.contentDocument;if(win.scrollY+frame.clientHeight>=doc.documentElement.scrollHeight-5)await mobiDisplay(mobiIndex+1);else win.scrollBy({top:frame.clientHeight*.85,behavior:'smooth'})}}catch(error){fail(error)}},
 async previous(){try{if(rendition)await rendition.prev();else if(frame){if(frame.contentWindow.scrollY<5)await mobiDisplay(mobiIndex-1);else frame.contentWindow.scrollBy({top:-frame.clientHeight*.85,behavior:'smooth'})}}catch(error){fail(error)}},
 async go(href){try{if(rendition)await rendition.display(href);else{let target=await mobi.resolveHref(href);if(target)await mobiDisplay(target.index,target.anchor)}}catch(error){fail(error)}},
 configure(options){settings={...settings,...options};style()},
 async search(query){try{if(!query.trim()){emit('search',[]);return}let results=[];if(book){for(let section of book.spine.spineItems){await section.load(book.load.bind(book));results.push(...section.find(query).map(x=>({id:x.cfi,title:x.excerpt})));section.unload();if(results.length>=200)break}}else if(mobi){for(let i=0;i<mobi.sections.length;i++){if(!mobi.sections[i].createDocument)continue;let doc=await mobi.sections[i].createDocument();let text=doc.body?.textContent||'';let p=text.toLocaleLowerCase().indexOf(query.toLocaleLowerCase());if(p>=0)results.push({id:'mobi-section:'+i,title:text.slice(Math.max(0,p-40),p+query.length+80)});if(results.length>=200)break}}emit('search',results.slice(0,200))}catch(error){fail(error)}},
 async searchGo(id){if(id.startsWith('mobi-section:'))await mobiDisplay(Number(id.slice(13)));else await this.go(id)}
 };
})();
