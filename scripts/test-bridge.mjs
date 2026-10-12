import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const code=readFileSync(new URL('../Sources/OCloudSync/Resources/bridge.js',import.meta.url),'utf8');
function fixture(){
 const item={userId:'account1',globalUniqId:'id1',oosId:'file1',fileName:'A.heic',fileSize:123,width:3,height:4,fileMediaType:1,fileExtension:'{"isOlive":0}',fileModifyTime:55};
 const c={ $data:{renderObj:{}},$children:[],showDownloadPage:false,currentPage:1,pageSize:1000,photoFlallsTotal:1,curTabName:'photo',currentDevice:{modeType:'sync'},selectList:[],renderObj:{renderList:[item],final:true,finalPage:true},
  loadData(){this.appendRenderList({})},appendRenderList(){},open(){this.showDownloadPage=true;this.loadData()},loadPhotoCount(){this.loadData()},handleCurrentChange(n){this.currentPage=n;this.loadData()},selectDownload(){this.downloaded=this.renderObj.renderList.map(x=>({...x}));this.selectList=[];this.renderObj.renderList.forEach(x=>x.selected=false)} };
 const window={};vm.runInNewContext(code,{window,location:{origin:'https://cloud.oppo.com'},document:{querySelectorAll:()=>[{__vue__:c}]},Map,Set,JSON,Number,String,Error});
 return {b:window.OCloudBridge,c,item};
}
{
 const {b}=fixture();b.begin();const result=b.read();assert.equal(result.serial,1);assert.equal(result.items[0].filename,'A.heic');assert.equal(result.items[0].isMotion,false);assert.equal(result.items[0].account,'account1');
 assert.equal(Object.keys(result.items[0]).some(k=>/token|url|sign|cookie/i.test(k)),false);
}
{
 const {b,c,item}=fixture();b.begin();const a=b.read().items[0];b.download(a);assert.equal(c.downloaded.length,1);assert.equal(c.downloaded[0].oosId,'file1');assert.equal(c.renderObj.renderList[0],item);
 c.renderObj.renderList[0]={...item,userId:'another'};assert.throws(()=>b.download(a),/ACCOUNT_CHANGED/);
}
{
 const {b,c}=fixture();b.begin();const before=b.read().items[0].version;c.renderObj.renderList[0].updateTime=123456;assert.equal(b.read().items[0].version,before);c.renderObj.renderList[0].oosId='new-original';assert.notEqual(b.read().items[0].version,before);
}
{
 const {b,c}=fixture();c.renderObj.renderList[0].fileExtension='{"isOlive":1}';assert.equal(b.read().items[0].isMotion,true);c.curTabName='recycle';assert.throws(()=>b.read(),/SOURCE_CHANGED/);
}
{
 const {b,c}=fixture();c.renderObj.renderList[0].userId='';assert.throws(()=>b.read(),/INVALID_ASSET/);
}
console.log('bridge tests: 5 groups passed');
