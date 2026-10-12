/* Uses only the official page's request client; no credentials leave the WebView. */
(() => {
  if (window.OCloudSession) return;
  let requirePage, serial=0, result;
  function client() {
    if (!requirePage) {
      const queue=window.webpackJsonp;
      if (!queue || typeof queue.push !== 'function') throw new Error('PAGE_NOT_READY');
      const id='ocloud-session-'+Date.now();
      queue.push([[id],{[id]:function(module,exports,require){requirePage=require}},[[id]]]);
    }
    if (!requirePage) throw new Error('PAGE_NOT_READY');
    const api=requirePage('ccde').b, endpoint=requirePage('9ca4').a.refresh;
    const url=new URL(endpoint,location.origin);
    // Official 2ca3 routing selects a regional production API, separate from the page origin.
    const origins=['https://cloud.oppo.com','https://ck-rest-cn.oppo.com','https://ck-rest-sg.oppo.com','https://ck-rest-in.oppo.com'];
    if (!origins.includes(url.origin) || url.pathname!=='/ucweb/token/v1/refresh' || url.search || url.hash || url.username || url.password || typeof api.post!=='function') throw new Error('API_CHANGED');
    return {api,endpoint};
  }
  function classify(value) {
    const code=Number(value?.code);
    if (code===200 && value.data!==false) return {kind:'active',code};
    if (code===403) return {kind:'loginRequired',code};
    return {kind:code>=500 || code===408 || code===429?'retrying':'unsupported',...(Number.isInteger(code)?{code}:{})};
  }
  window.OCloudSession={
    begin(){
      if(result?.kind==='pending') return {ticket:result.ticket};
      const ticket=++serial;
      result={ticket,kind:'pending'};
      if(location.origin!=='https://cloud.oppo.com' || location.pathname==='/login.html') {result={ticket,kind:'loginRequired'};return {ticket};}
      try {
        const {api,endpoint}=client();
        // Same payload, content type and JSON flag as the official df4c renewal module.
        Promise.resolve(api.post(endpoint,{timestamp:Date.now(),nonce:Math.floor(1e6*Math.random())},{'Content-Type':'application/json;charset=UTF-8'},true))
          .then(value=>{result={ticket,...classify(value)}})
          .catch(error=>{const code=Number(error?.response?.status);result={ticket,kind:code===403?'loginRequired':!Number.isInteger(code)||code===408||code===429||code>=500?'retrying':'unsupported',...(Number.isInteger(code)?{code}:{})}});
      } catch { result={ticket,kind:'unsupported'}; }
      return {ticket};
    },
    read(ticket){return result?.ticket===ticket?result:{ticket,kind:'pending'}}
  };
})();
