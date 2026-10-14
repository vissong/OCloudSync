/* Adapter for the user-authenticated OPPO page. No credentials leave the WebView. */
(() => {
  if (location.origin !== 'https://cloud.oppo.com') throw new Error('LOGIN_REQUIRED');
  if (window.OCloudBridge) return;
  const cache = new Map();
  const retryDelays = [5000, 15000, 30000];
  let component, requestSerial = 0, requirePage, preparation, preparationSerial = 0;
  let listRequest, listClientWrapped = false;
  function beginRead(action) {
    const serial=requestSerial;
    listRequest={serial,kind:'pending',retries:0,activity:0};
    action();return {serial};
  }
  function wrapListClient() {
    if(listClientWrapped)return;
    const client=requirePage('ff59').a, endpoints=requirePage('9ca4').a;
    const count=endpoints.photocount, list=endpoints.photodownloadlist;
    const paths=['/portal/h5/album/v1/getAlbumCount','/albumpc/v4/download-mode-data'];
    const origins=['https://cloud.oppo.com','https://ck-rest-cn.oppo.com','https://ck-rest-sg.oppo.com','https://ck-rest-in.oppo.com'];
    [count,list].forEach((endpoint,index)=>{
      const url=new URL(endpoint,location.origin);
      if(!origins.includes(url.origin)||url.pathname!==paths[index]||url.search||url.hash||url.username||url.password)throw new Error('API_CHANGED');
    });
    if(typeof client.encryptPost!=='function')throw new Error('API_CHANGED');
    const post=client.encryptPost;
    client.encryptPost=function(endpoint,...args) {
      const request=listRequest;
      if(!request || ![count,list].includes(endpoint))return post.call(this,endpoint,...args);
      const current=()=>listRequest===request && !['failed','loginRequired','retired'].includes(request.kind);
      // The vendor count catch starts extra requests. Native polling owns failure/cancellation;
      // leave abandoned vendor chains unsettled until this document is retired/reloaded.
      const abandon=()=>new Promise(()=>{});
      const fail=(code)=>{
        if(!current())return;
        delete request.code;
        Object.assign(request,{kind:code===401||code===403?'loginRequired':'failed',...(Number.isInteger(code)?{code}:{})});
      };
      if(!current())return abandon();
      request.retries=0;delete request.code;delete request.retryAt;
      return (async()=>{
        // Retry only these read-only endpoints, with the same page/ticket/cursor.
        for(let attempt=0; ; attempt++) {
          if(!current())return abandon();
          request.kind='pending';request.activity++;delete request.retryAt;
          let value, code, transportFailure=false;
          try {value=await post.call(client,endpoint,...args)}
          catch(error){transportFailure=true;const status=Number(error?.response?.status);if(Number.isInteger(status)&&status>0)code=status}
          if(!current())return abandon();
          if(!transportFailure)code=typeof value?.code==='number'?value.code:undefined;
          const retryable=code===400||code===408||code===429||code>=500&&code<=599||transportFailure&&code===undefined;
          if(retryable&&attempt<retryDelays.length) {
            request.kind='retrying';request.retries=attempt+1;request.activity++;
            if(Number.isInteger(code))request.code=code;else delete request.code;
            request.retryAt=Date.now()+retryDelays[attempt];
            await new Promise(resolve=>setTimeout(resolve,retryDelays[attempt]));
            continue;
          }
          if(code!==200 || !(endpoint===count?value?.data?.fileCount:Array.isArray(value?.data?.items))){fail(code);return abandon()}
          return value;
        }
      })();
    };
    listClientWrapped=true;
  }
  function exitClient() {
    if (!requirePage) {
      const queue=window.webpackJsonp, id='ocloud-list-'+Date.now();
      if (!queue || typeof queue.push!=='function') throw new Error('PAGE_NOT_READY');
      queue.push([[id],{[id]:function(module,exports,require){requirePage=require}},[[id]]]);
    }
    if (!requirePage) throw new Error('PAGE_NOT_READY');
    wrapListClient();
    const api=requirePage('ccde').b, endpoint=requirePage('9ca4').a.photodownloadexit;
    const url=new URL(endpoint,location.origin);
    const origins=['https://cloud.oppo.com','https://ck-rest-cn.oppo.com','https://ck-rest-sg.oppo.com','https://ck-rest-in.oppo.com'];
    if (!origins.includes(url.origin) || url.pathname!=='/albumpc/v2/download-mode-exit' || url.search || url.hash || url.username || url.password || typeof api.post!=='function') throw new Error('API_CHANGED');
    return {api,endpoint};
  }
  function find() {
    const seen=new Set(), all=[];
    function walk(v) { if(!v||seen.has(v))return;seen.add(v);all.push(v);(v.$children||[]).forEach(walk); }
    document.querySelectorAll('*').forEach(e=>walk(e.__vue__));
    component=all.find(v=>v.$data?.renderObj && typeof v.loadData==='function' && typeof v.selectDownload==='function');
    if(!component)throw new Error('LOGIN_REQUIRED');
    if(!component.__syncWrapped) {
      const append=component.appendRenderList;
      component.appendRenderList=function(data){append.call(this,data);requestSerial++};
      component.__syncWrapped=true;
    }
    return component;
  }
  function captureTime(value) {
    const number=typeof value==='number'||typeof value==='string'&&/^\d+$/.test(value)?Number(value):NaN;
    return Number.isSafeInteger(number)&&number>0&&number<253402300800000?number:null;
  }
  function row(a) {
    const account=String(a.userId||''),id=String(a.globalUniqId||a.globalId||''),fileID=String(a.oosId||a.fileId||'');
    let ext={};try{ext=JSON.parse(a.fileExtension||'{}')}catch{throw new Error('UNSUPPORTED_METADATA')}
    if(!account||!id||!fileID||!(Number(a.fileSize)>0))throw new Error('INVALID_ASSET');
    // Include immutable resource identity and content metadata, not album/UI update times.
    const version=JSON.stringify([fileID,a.fileSize,a.fileModifyTime||0,a.width,a.height,a.fileMD5||'']);
    const result={account,remoteID:id,fileID,filename:String(a.fileName||''),bytes:Number(a.fileSize),width:Number(a.width||0),height:Number(a.height||0),mediaType:Number(a.fileMediaType),version,isMotion:!!Number(ext.isOlive||0),dateTakenMilliseconds:captureTime(a.datetaken)};
    cache.set(account+'\0'+id+'\0'+version,a);
    return result;
  }
  window.OCloudBridge={
    requestState(afterSerial){
      if(!listRequest||listRequest.serial!==afterSerial)return null;
      const {kind,code,retries,activity,retryAt}=listRequest;
      return {kind,...(Number.isInteger(code)?{code}:{}),retries,activity,
        ...(kind==='retrying'?{retryInSeconds:Math.max(0,Math.ceil((retryAt-Date.now())/1000))}:{})};
    },
    // Failed scans require a page reload. Keep a tombstone to block late signing callbacks.
    retire(completed){listRequest=completed===true?undefined:{kind:'retired'}},
    status(){const c=find();return {ready:true,total:Number(c.photoFlallsTotal),serial:requestSerial,shown:!!c.showDownloadPage}},
    prepare(){
      if(preparation?.kind==='pending')return {ticket:preparation.ticket};
      const ticket=++preparationSerial;
      preparation={ticket,kind:'pending'};cache.clear();
      listRequest=undefined;
      try {
        const c=find();if(c.currentDevice.modeType!=='sync')throw new Error('SOURCE_CHANGED');
        const {api,endpoint}=exitClient();
        // Exit the server-side download snapshot before asking for a new count/list.
        Promise.resolve(api.post(endpoint,{businessType:c.currentDevice.modeType,deviceId:c.currentDevice.deviceId}))
          .then(value=>{
            // Album APIs use errorCode: 0; the newer portal envelope uses code: 200.
            const albumEnvelope=value?.errorCode!==undefined;
            const raw=albumEnvelope?value.errorCode:value?.code;
            const code=typeof raw==='number'||typeof raw==='string'&&/^\d+$/.test(raw)?Number(raw):NaN;
            const ready=code===(albumEnvelope?0:200)&&value.data!==false;
            preparation={ticket,kind:ready?'ready':code===403?'loginRequired':'failed',...(Number.isInteger(code)?{code}:{})};
          })
          .catch(error=>{const code=Number(error?.response?.status);preparation={ticket,kind:code===403?'loginRequired':'failed',...(Number.isInteger(code)?{code}:{})}});
      } catch {preparation={ticket,kind:'failed'}}
      return {ticket};
    },
    prepared(ticket){return preparation?.ticket===ticket?preparation:{ticket,kind:'failed'}},
    begin(){
      if(preparation?.kind!=='ready')throw new Error('FRESH_LIST_REQUIRED');
      preparation=undefined;
      const c=find();cache.clear();
      return beginRead(()=>{if(!c.showDownloadPage)c.open();else c.loadPhotoCount()});
    },
    read(afterSerial){if(Number.isInteger(afterSerial)&&requestSerial<=afterSerial)return null;const c=find();if(c.curTabName!=='photo'||c.currentDevice.modeType!=='sync')throw new Error('SOURCE_CHANGED');return {serial:requestSerial,page:c.currentPage,pageSize:c.pageSize,total:c.photoFlallsTotal,final:!!c.renderObj.final,finalPage:!!c.renderObj.finalPage,items:c.renderObj.renderList.map(row)}},
    next(){const c=find();return beginRead(()=>c.loadData(c.renderObj.last))},
    page(n){const c=find();return beginRead(()=>c.handleCurrentChange(n))},
    download(asset){
      const c=find(),key=asset.account+'\0'+asset.remoteID+'\0'+asset.version,item=cache.get(key);
      if(!item)throw new Error('RESCAN_REQUIRED');
      const current=c.renderObj.renderList[0];
      if(current && String(current.userId)!==asset.account)throw new Error('ACCOUNT_CHANGED');
      const old=c.renderObj.renderList,sel=c.selectList;
      try{c.renderObj.renderList=[{...item,selected:true}];c.selectList=[item];c.selectDownload()}
      finally{c.renderObj.renderList=old;c.selectList=sel}
      return {started:true};
    }
  };
})();
