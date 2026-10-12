import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const code=readFileSync(new URL('../Sources/OCloudSync/Resources/session.js',import.meta.url),'utf8');
function fixture(post, {path='/module.html', endpoint='/ucweb/token/v1/refresh'}={}) {
 const calls=[]; const window={webpackJsonp:{push([chunks,modules,entries]){modules[entries[0][0]]({}, {}, id=>id==='ccde'?{b:{post(...args){calls.push(args);return post(...args)}}}:{a:{refresh:endpoint}})}}};
 vm.runInNewContext(code,{window,location:{origin:'https://cloud.oppo.com',pathname:path},URL,Date,Math,Promise,Number});
 return {b:window.OCloudSession,calls};
}
const tick=()=>new Promise(r=>setImmediate(r));
{
 const {b,calls}=fixture(async()=>({code:200,secret:'must-not-escape'}));
 const a=b.begin(),same=b.begin();assert.equal(a.ticket,same.ticket);assert.equal(calls.length,1);
 await tick();assert.equal(b.read(a.ticket).kind,'active');assert.deepEqual(Object.keys(b.read(a.ticket)).sort(),['code','kind','ticket']);
 assert.equal(calls[0][0],'/ucweb/token/v1/refresh');assert.equal(calls[0][3],true);
 assert.equal(Object.keys(calls[0][1]).some(k=>/token|cookie/i.test(k)),false);
}
for(const status of [400,401,403,404,405,408,410,429,500,503]){
 const {b}=fixture(async()=>{throw {response:{status}}});const {ticket}=b.begin();await tick();
 assert.equal(b.read(ticket).kind,status===403?'loginRequired':status===408||status===429||status>=500?'retrying':'unsupported');
}
{
 const {b}=fixture(async()=>{throw new Error('network')});const {ticket}=b.begin();await tick();assert.equal(b.read(ticket).kind,'retrying');
}
{
 const {b,calls}=fixture(async()=>({code:200}),{path:'/login.html'});const {ticket}=b.begin();assert.equal(b.read(ticket).kind,'loginRequired');assert.equal(calls.length,0);
}
{
 const {b,calls}=fixture(async()=>({code:200}),{endpoint:'https://example.com/ucweb/token/v1/refresh'});const {ticket}=b.begin();assert.equal(b.read(ticket).kind,'unsupported');assert.equal(calls.length,0);
}
for(const response of [{code:403},{code:500},{},{code:200,data:false}]){
 const {b}=fixture(async()=>response);const {ticket}=b.begin();await tick();
 assert.equal(b.read(ticket).kind,response.code===403?'loginRequired':response.code===500?'retrying':'unsupported');
}
for(const endpoint of ['https://ck-rest-cn.oppo.com/ucweb/token/v1/refresh','https://ck-rest-sg.oppo.com/ucweb/token/v1/refresh','https://ck-rest-in.oppo.com/ucweb/token/v1/refresh']){
 const {b,calls}=fixture(async()=>({code:200}),{endpoint});const {ticket}=b.begin();await tick();
 assert.equal(b.read(ticket).kind,'active');assert.equal(calls[0][0],endpoint);
}
for(const endpoint of ['http://ck-rest-cn.oppo.com/ucweb/token/v1/refresh','https://ck-rest-cn.oppo.com.evil.test/ucweb/token/v1/refresh','https://ck-rest-cn.oppo.com:8443/ucweb/token/v1/refresh','https://ck-rest-cn.oppo.com/other/ucweb/token/v1/refresh']){
 const {b,calls}=fixture(async()=>({code:200}),{endpoint});const {ticket}=b.begin();await tick();
 assert.equal(b.read(ticket).kind,'unsupported');assert.equal(calls.length,0);
}
console.log('session adapter tests: 25 cases passed');
