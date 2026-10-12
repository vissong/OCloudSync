/* Adapter for the user-authenticated OPPO page. No credentials leave the WebView. */
(() => {
  if (location.origin !== 'https://cloud.oppo.com') throw new Error('LOGIN_REQUIRED');
  if (window.OCloudBridge) return;
  const cache = new Map();
  let component, requestSerial = 0, requirePage, preparation, preparationSerial = 0;
  function exitClient() {
    if (!requirePage) {
      const queue=window.webpackJsonp, id='ocloud-list-'+Date.now();
      if (!queue || typeof queue.push!=='function') throw new Error('PAGE_NOT_READY');
      queue.push([[id],{[id]:function(module,exports,require){requirePage=require}},[[id]]]);
    }
    if (!requirePage) throw new Error('PAGE_NOT_READY');
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
  function row(a) {
    const account=String(a.userId||''),id=String(a.globalUniqId||a.globalId||''),fileID=String(a.oosId||a.fileId||'');
    let ext={};try{ext=JSON.parse(a.fileExtension||'{}')}catch{throw new Error('UNSUPPORTED_METADATA')}
    if(!account||!id||!fileID||!(Number(a.fileSize)>0))throw new Error('INVALID_ASSET');
    // Include immutable resource identity and content metadata, not album/UI update times.
    const version=JSON.stringify([fileID,a.fileSize,a.fileModifyTime||0,a.width,a.height,a.fileMD5||'']);
    const result={account,remoteID:id,fileID,filename:String(a.fileName||''),bytes:Number(a.fileSize),width:Number(a.width||0),height:Number(a.height||0),mediaType:Number(a.fileMediaType),version,isMotion:!!Number(ext.isOlive||0)};
    cache.set(account+'\0'+id+'\0'+version,a);
    return result;
  }
  window.OCloudBridge={
    status(){const c=find();return {ready:true,total:Number(c.photoFlallsTotal),serial:requestSerial,shown:!!c.showDownloadPage}},
    prepare(){
      if(preparation?.kind==='pending')return {ticket:preparation.ticket};
      const ticket=++preparationSerial;
      preparation={ticket,kind:'pending'};cache.clear();
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
      const c=find();cache.clear();const serial=requestSerial;
      if(!c.showDownloadPage)c.open();else c.loadPhotoCount();return {serial};
    },
    read(afterSerial){if(Number.isInteger(afterSerial)&&requestSerial<=afterSerial)return null;const c=find();if(c.curTabName!=='photo'||c.currentDevice.modeType!=='sync')throw new Error('SOURCE_CHANGED');return {serial:requestSerial,page:c.currentPage,pageSize:c.pageSize,total:c.photoFlallsTotal,final:!!c.renderObj.final,finalPage:!!c.renderObj.finalPage,items:c.renderObj.renderList.map(row)}},
    next(){const c=find();const s=requestSerial;c.loadData(c.renderObj.last);return {serial:s}},
    page(n){const c=find();const s=requestSerial;c.handleCurrentChange(n);return {serial:s}},
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
