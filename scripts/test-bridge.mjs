import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const code=readFileSync(new URL('../Sources/OCloudSync/Resources/bridge.js',import.meta.url),'utf8');
function fixture({exitCode=200,exitResponse,exitError,origin="https://cloud.oppo.com"}={}){
 const item={userId:'account1',globalUniqId:'id1',oosId:'file1',fileName:'A.heic',fileSize:123,width:3,height:4,fileMediaType:1,fileExtension:'{"isOlive":0}',fileModifyTime:55};
 const c={ $data:{renderObj:{}},$children:[],showDownloadPage:false,currentPage:1,pageSize:1000,photoFlallsTotal:1,curTabName:'photo',currentDevice:{modeType:'sync'},selectList:[],renderObj:{renderList:[item],final:true,finalPage:true},
  loadData(){this.appendRenderList({})},appendRenderList(){},open(){this.showDownloadPage=true;this.loadData()},loadPhotoCount(){this.loadData()},handleCurrentChange(n){this.currentPage=n;this.loadData()},selectDownload(){this.downloaded=this.renderObj.renderList.map(x=>({...x}));this.selectList=[];this.renderObj.renderList.forEach(x=>x.selected=false)} };
 const requests=[];
 let releaseExit;
 const api={post(endpoint,body){requests.push({endpoint,body});return new Promise((resolve,reject)=>{releaseExit=()=>exitError?reject(exitError):resolve(exitResponse===undefined?{code:exitCode,data:true}:exitResponse)})}};
 const modules={'ccde':{b:api},'9ca4':{a:{photodownloadexit:'https://ck-rest-cn.oppo.com/albumpc/v2/download-mode-exit'}}};
 const window={webpackJsonp:{push(entry){const id=entry[0][0];entry[1][id]({}, {},name=>modules[name])}}};vm.runInNewContext(code,{window,URL,Promise,Date,location:{origin},document:{querySelectorAll:()=>[{__vue__:c}]},Map,Set,JSON,Number,String,Error});
 return {b:window.OCloudBridge,c,item,requests,modules,releaseExit:()=>releaseExit()};
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
console.log('bridge tests: 22 groups passed');

async function preparedFixture(){
 const f=fixture();const p=f.b.prepare();f.releaseExit();await new Promise(resolve=>setImmediate(resolve));
 assert.equal(f.b.prepared(p.ticket).kind,'ready');return f;
}
