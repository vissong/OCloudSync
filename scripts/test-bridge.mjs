import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const code=readFileSync(new URL('../Sources/OCloudSync/Resources/bridge.js',import.meta.url),'utf8');
function fixture({exitCode=200,exitResponse,exitError,origin="https://cloud.oppo.com",listReplies,countLifecycle=false}={}){
 const item={userId:'account1',globalUniqId:'id1',oosId:'file1',fileName:'A.heic',fileSize:123,width:3,height:4,fileMediaType:1,fileExtension:'{"isOlive":0}',fileModifyTime:55};
 const c={ $data:{renderObj:{}},$children:[],showDownloadPage:false,currentPage:1,pageSize:1000,photoFlallsTotal:1,curTabName:'photo',currentDevice:{modeType:'sync'},selectList:[],renderObj:{renderList:[item],final:true,finalPage:true},
  loadData(){this.appendRenderList({})},appendRenderList(){},open(){this.showDownloadPage=true;this.loadData()},loadPhotoCount(){this.loadData()},handleCurrentChange(n){this.currentPage=n;this.loadData()},selectDownload(){this.downloaded=this.renderObj.renderList.map(x=>({...x}));this.selectList=[];this.renderObj.renderList.forEach(x=>x.selected=false)} };
 const requests=[];
 let releaseExit;
 const api={post(endpoint,body){requests.push({endpoint,body});return new Promise((resolve,reject)=>{releaseExit=()=>exitError?reject(exitError):resolve(exitResponse===undefined?{code:exitCode,data:true}:exitResponse)})}};
 const listCalls=[], timers=[];
 const encrypted={encryptPost(endpoint,body){listCalls.push({endpoint,body});const reply=listReplies?.shift();return reply instanceof Error?Promise.reject(reply):Promise.resolve(reply)}};
 const endpoints={photocount:'https://ck-rest-cn.oppo.com/portal/h5/album/v1/getAlbumCount',photodownloadlist:'https://ck-rest-cn.oppo.com/albumpc/v4/download-mode-data'};
 if(listReplies)c.loadData=function(){encrypted.encryptPost(endpoints.photodownloadlist,{index:this.currentPage,last:this.renderObj.last,ticket:'fixture-ticket'}).then(value=>{if(value?.code===200&&value.data)this.appendRenderList(value.data)}).catch(()=>{})};
 if(countLifecycle){
  // Mirrors the official count fallback: a rejection triggers count + list again.
  c.loadPhotoCount=function(){let failures=0;const attempt=()=>encrypted.encryptPost(endpoints.photocount,{}).then(value=>{if(value?.code===200&&value.data?.fileCount&&failures===0)this.loadData()}).catch(()=>{if(failures===0){attempt();this.loadData()}failures++});attempt()};
  c.open=function(){this.showDownloadPage=true;this.loadPhotoCount()};
 }
 const modules={'ff59':{a:encrypted},'ccde':{b:api},'9ca4':{a:{...endpoints,photodownloadexit:'https://ck-rest-cn.oppo.com/albumpc/v2/download-mode-exit'}}};
 const window={webpackJsonp:{push(entry){const id=entry[0][0];entry[1][id]({}, {},name=>modules[name])}}};vm.runInNewContext(code,{window,URL,Promise,Date,setTimeout:(fn,delay)=>{timers.push({fn,delay});return timers.length},location:{origin},document:{querySelectorAll:()=>[{__vue__:c}]},Map,Set,JSON,Number,String,Error});
 return {b:window.OCloudBridge,c,item,requests,modules,listCalls,timers,releaseExit:()=>releaseExit()};
}
{
 const {b}=await preparedFixture();b.begin();const result=b.read();assert.equal(result.serial,1);assert.equal(result.items[0].filename,'A.heic');assert.equal(result.items[0].isMotion,false);assert.equal(result.items[0].account,'account1');
 assert.equal(Object.keys(result.items[0]).some(k=>/token|url|sign|cookie/i.test(k)),false);
}
{
 const {b,c,item}=await preparedFixture();b.begin();const a=b.read().items[0];b.download(a);assert.equal(c.downloaded.length,1);assert.equal(c.downloaded[0].oosId,'file1');assert.equal(c.renderObj.renderList[0],item);
 c.renderObj.renderList[0]={...item,userId:'another'};assert.throws(()=>b.download(a),/ACCOUNT_CHANGED/);
}
{
 const {b,c}=await preparedFixture();b.begin();const before=b.read().items[0].version;c.renderObj.renderList[0].updateTime=123456;assert.equal(b.read().items[0].version,before);c.renderObj.renderList[0].oosId='new-original';assert.notEqual(b.read().items[0].version,before);
}
{
 const {b,c}=fixture();c.renderObj.renderList[0].fileExtension='{"isOlive":1}';assert.equal(b.read().items[0].isMotion,true);c.curTabName='recycle';assert.throws(()=>b.read(),/SOURCE_CHANGED/);
}
{
 const {b,c}=fixture();c.renderObj.renderList[0].userId='';assert.throws(()=>b.read(),/INVALID_ASSET/);
}
{
 const f=fixture(); const p=f.b.prepare();
 assert.equal(f.requests.length,1);assert.equal(f.b.prepare().ticket,p.ticket);assert.equal(f.requests.length,1);
 assert.equal(f.requests[0].body.businessType,'sync');
 assert.equal(f.b.prepared(p.ticket).kind,'pending');
 assert.throws(()=>f.b.begin(),/FRESH_LIST_REQUIRED/);
 f.releaseExit();await new Promise(resolve=>setImmediate(resolve));
 assert.equal(f.b.prepared(p.ticket).kind,'ready');
 f.b.begin();assert.throws(()=>f.b.begin(),/FRESH_LIST_REQUIRED/);
 // A new scan must exit the previous server snapshot even if the total is unchanged.
 const p2=f.b.prepare();assert.equal(f.requests.length,2);
 f.c.loadPhotoCount=function(){this.renderObj.renderList=[{...f.item,globalUniqId:'new-id',oosId:'new-file',fileName:'NEW.JPG'}];this.loadData()};
 f.releaseExit();await new Promise(resolve=>setImmediate(resolve));
 assert.equal(f.b.prepared(p2.ticket).kind,'ready');
 f.b.begin();assert.equal(f.b.read().items[0].filename,'NEW.JPG');
 assert.equal(f.b.read().total,1);
}
for (const options of [{exitCode:500},{exitCode:403},{exitError:{response:{status:403}}},{exitError:new Error('offline')}]) {
 const f=fixture(options),p=f.b.prepare();f.releaseExit();await new Promise(resolve=>setImmediate(resolve));
 assert.equal(f.b.prepared(p.ticket).kind, options.exitCode===403||options.exitError?.response?.status===403?'loginRequired':'failed');
 assert.throws(()=>f.b.begin(),/FRESH_LIST_REQUIRED/);
}
{
 const {b,c}=await preparedFixture();const marker=b.begin();
 const serial=b.read().serial;c.curTabName='';assert.equal(b.read(serial),null);
}
{
 const {b,c,requests}=fixture();c.currentDevice.modeType='backup';const p=b.prepare();
 assert.equal(b.prepared(p.ticket).kind,'failed');assert.equal(requests.length,0);
}
{
 const {b,modules,requests}=fixture();modules['9ca4'].a.photodownloadexit='https://example.com/albumpc/v2/download-mode-exit';const p=b.prepare();
 assert.equal(b.prepared(p.ticket).kind,'failed');assert.equal(requests.length,0);
}
// The actual download-mode-exit API acknowledges success with errorCode: 0.
for (const exitResponse of [{errorCode:0},{errorCode:'0'}]) {
 const f=fixture({exitResponse}),p=f.b.prepare();f.releaseExit();await new Promise(resolve=>setImmediate(resolve));
 assert.equal(f.b.prepared(p.ticket).kind,'ready');f.b.begin();
}
for (const exitResponse of [{errorCode:500},{errorCode:403},{errorCode:null},{errorCode:false},{errorCode:''},{},{errorCode:0,data:false}]) {
 const f=fixture({exitResponse}),p=f.b.prepare();f.releaseExit();await new Promise(resolve=>setImmediate(resolve));
 assert.equal(f.b.prepared(p.ticket).kind,exitResponse.errorCode===403?'loginRequired':'failed');
 assert.throws(()=>f.b.begin(),/FRESH_LIST_REQUIRED/);
}
{
 const {b,item}=fixture();
 for (const value of [1787742871054,'1787742871054']) {
  item.datetaken=value;assert.equal(b.read().items[0].dateTakenMilliseconds,1787742871054);
 }
 const key=b.read().items[0].version;
 for (const value of [undefined,null,'',0,-1,true,'2026-10-01',Infinity,Number.MAX_SAFE_INTEGER]) {
  item.datetaken=value;item.uploadTime=1787742871054;
  assert.equal(b.read().items[0].dateTakenMilliseconds,null);
  assert.equal(b.read().items[0].version,key);
 }
}
// Count failures must never invoke the vendor's fallback or overwrite terminal state.
{
 const f=fixture({countLifecycle:true,listReplies:[{code:400},{code:200,data:{fileCount:{photo:1}}},{code:200,data:{items:[]}}]});await prepare(f);const marker=f.b.begin();await settle();
 f.b.retire();f.timers.shift().fn();await settle();
 assert.equal(f.listCalls.length,1,'retiring count must suppress vendor fallback');assert.equal(f.b.read(marker.serial),null);
}
{
 const f=fixture({countLifecycle:true,listReplies:[Object.assign(new Error('private detail'),{response:{status:403}}),{code:200,data:{fileCount:{photo:1}}},{code:200,data:{items:[]}}]});await prepare(f);const marker=f.b.begin();await settle();
 assert.equal(f.b.requestState(marker.serial).kind,'loginRequired');assert.equal(f.listCalls.length,1);assert.equal(f.b.read(marker.serial),null);
 // A late vendor call in the failed context must not reopen it.
 f.c.loadData();await settle();assert.equal(f.listCalls.length,1);assert.equal(f.b.requestState(marker.serial).kind,'loginRequired');
}
{
 const f=fixture({listReplies:[{code:200,data:{items:null,final:true}}]});await prepare(f);const marker=f.b.begin();await settle();
 assert.equal(f.b.requestState(marker.serial).kind,'failed');assert.equal(f.b.read(marker.serial),null,'invalid response must not reach vendor append callback');
}
// Business errors do not invoke the vendor's append callback. Retry the same read only.
{
 const replies=[{code:400},{code:429},{code:200,data:{items:[]}}];
 const f=fixture({listReplies:replies});await prepare(f);const marker=f.b.begin();await settle();
 assert.equal(f.b.requestState(marker.serial).kind,'retrying');assert.equal(f.timers[0].delay,5000);
 f.timers.shift().fn();await settle();assert.equal(f.timers[0].delay,15000);
 f.timers.shift().fn();await settle();assert.ok(f.b.read(marker.serial));
 assert.equal(f.listCalls.length,3);assert.deepEqual(f.listCalls[0],f.listCalls[2]);
}
{
 const f=fixture({listReplies:[{code:400},{code:400},{code:400},{code:400}]});await prepare(f);const marker=f.b.begin();await settle();
 for(const delay of [5000,15000,30000]){assert.equal(f.timers[0].delay,delay);f.timers.shift().fn();await settle()}
 assert.equal(f.b.read(marker.serial),null);
 assert.deepEqual(JSON.parse(JSON.stringify(f.b.requestState(marker.serial))),{kind:'failed',code:400,retries:3,activity:7});
 assert.equal(f.timers.length,0);assert.equal(f.listCalls.length,4);
}
for(const reply of [{code:403},{code:401},{code:200},{code:'200',data:{items:[]}},Object.assign(new Error('private detail'),{response:{status:403}})]) {
 const f=fixture({listReplies:[reply]});await prepare(f);const marker=f.b.begin();await settle();
 const state=f.b.requestState(marker.serial);
 assert.equal(state.kind,reply.code===403||reply.code===401||reply.response?.status===403?'loginRequired':'failed');
 assert.equal(f.listCalls.length,1);assert.equal(f.timers.length,0);
 assert.equal(JSON.stringify(state).includes('private'),false);
}
{
 const f=fixture({listReplies:[{code:400},{code:200,data:{items:[]}}]});await prepare(f);const marker=f.b.begin();await settle();
 f.b.retire();f.timers.shift().fn();await settle();
 assert.equal(f.listCalls.length,1);assert.equal(f.b.requestState(marker.serial),null);
}
{
 const f=fixture({listReplies:[{code:400},{code:200,data:{items:[]}}]});await prepare(f);const marker=f.b.begin();await settle();
 const timer=f.timers.shift();f.b.page(2);await settle();timer.fn();await settle();
 assert.equal(f.listCalls.length,2);assert.ok(f.b.read(marker.serial));
}
{
 const f=fixture({listReplies:[{code:400},{code:200,data:{fileCount:{photo:1}}},{code:401}]});await prepare(f);
 f.c.open=function(){this.showDownloadPage=true;f.modules.ff59.a.encryptPost(f.modules['9ca4'].a.photocount,{}).then(value=>{if(value?.code===200&&value.data?.fileCount)this.loadData()}).catch(()=>{})};
 const marker=f.b.begin();await settle();f.timers.shift().fn();await settle();
 const state=f.b.requestState(marker.serial);assert.equal(state.code,401);
 assert.equal(state.retries,0,'a new endpoint must not inherit the count request retry count');
}
{
 const f=fixture({listReplies:[{code:200,data:{items:[]}},{code:400}]});await prepare(f);f.b.begin();await settle();
 const reply=await f.modules.ff59.a.encryptPost('https://ck-rest-cn.oppo.com/unrelated-write',{});
 assert.equal(reply.code,400);assert.equal(f.listCalls.length,2);assert.equal(f.timers.length,0);
}
{
 const f=fixture({listReplies:[{code:200,data:{items:[]}},{code:400}]});await prepare(f);f.b.begin();await settle();f.b.retire(true);
 const reply=await f.modules.ff59.a.encryptPost(f.modules['9ca4'].a.photodownloadlist,{});
 assert.equal(reply.code,400);assert.equal(f.listCalls.length,2);assert.equal(f.timers.length,0,'after scan, ordinary page requests must pass through');
}
{
 const f=fixture({listReplies:[{code:200,data:{items:[]}}]});await prepare(f);
 const load=f.c.loadData;let releaseSigning;
 f.c.loadData=function(){releaseSigning=()=>load.call(this)};
 const marker=f.b.begin();assert.equal(f.listCalls.length,0);f.b.retire(false);releaseSigning();await settle();
 assert.equal(f.listCalls.length,0,'cancelled scan must block a list request delayed by signing');assert.equal(f.b.read(marker.serial),null);
}

// Both transport and business failures get the same bounded backoff.
for(const code of [400,408,429,500,502,503,599]) {
 const error=Object.assign(new Error('private transport detail'),{response:{status:code}});
 const f=fixture({listReplies:[error,{code:200,data:{items:[]}}]});await prepare(f);const marker=f.b.begin();await settle();
 const state=f.b.requestState(marker.serial);
 assert.equal(state.kind,'retrying');assert.equal(state.code,code);assert.equal(state.retries,1);
 assert.equal(state.activity,2);assert.ok(state.retryInSeconds>=4 && state.retryInSeconds<=5);
 assert.equal(f.timers[0].delay,5000);assert.equal(JSON.stringify(state).includes('private'),false);
 f.timers.shift().fn();await settle();assert.ok(f.b.read(marker.serial));
 assert.deepEqual(f.listCalls[0],f.listCalls[1]);assert.equal(f.b.requestState(marker.serial).activity,3);
}
{
 const f=fixture({listReplies:[new Error('offline'),new Error('offline'),new Error('offline'),new Error('offline')]});await prepare(f);const marker=f.b.begin();await settle();
 for(const delay of [5000,15000,30000]){assert.equal(f.timers[0].delay,delay);f.timers.shift().fn();await settle()}
 assert.equal(f.b.requestState(marker.serial).kind,'failed');assert.equal(f.listCalls.length,4);assert.equal(f.timers.length,0);
}
for(const code of [401,403,404,422]) {
 const f=fixture({listReplies:[Object.assign(new Error('do not retry'),{response:{status:code}})]});await prepare(f);const marker=f.b.begin();await settle();
 assert.equal(f.b.requestState(marker.serial).kind,[401,403].includes(code)?'loginRequired':'failed');assert.equal(f.timers.length,0);
}
{
 const f=fixture({countLifecycle:true,listReplies:[{code:400},{code:200,data:{fileCount:{photo:1}}},{code:400},{code:200,data:{items:[]}}]});await prepare(f);const marker=f.b.begin();await settle();
 const countActivity=f.b.requestState(marker.serial).activity;
 f.timers.shift().fn();await settle();const listState=f.b.requestState(marker.serial);
 assert.equal(listState.retries,1);assert.ok(listState.activity>countActivity,'count/list progress must not reset the timeout marker');
 f.timers.shift().fn();await settle();assert.ok(f.b.read(marker.serial));assert.equal(f.listCalls.length,4);
}
{
 const f=fixture({listReplies:[{code:400},{code:400},{code:400},new Error('offline')]});await prepare(f);const marker=f.b.begin();await settle();
 for(let n=0;n<3;n++){f.timers.shift().fn();await settle()}
 const state=f.b.requestState(marker.serial);assert.equal(state.kind,'failed');assert.equal(state.code,undefined,'final network failure must clear earlier business code');
}
console.log('bridge tests: all cases passed');
async function settle(){await new Promise(resolve=>setImmediate(resolve))}
async function prepare(f){const p=f.b.prepare();f.releaseExit();await settle();assert.equal(f.b.prepared(p.ticket).kind,'ready')}


async function preparedFixture(){
 const f=fixture();const p=f.b.prepare();f.releaseExit();await new Promise(resolve=>setImmediate(resolve));
 assert.equal(f.b.prepared(p.ticket).kind,'ready');return f;
}
