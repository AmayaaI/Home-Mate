import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
const auth = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/';
const root = 'http://127.0.0.1:8080/v1/projects/demo-homemate/databases/(default)/documents';
async function login(action, body) {
 const response = await fetch(`${auth}${action}?key=demo-key`, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
 assert.equal(response.status,200,await response.clone().text()); return response.json();
}
async function doc(path, token, method='GET', body) {
 return fetch(`${root}/${path}`,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},...(body?{body:JSON.stringify(body)}:{})});
}
test('Authentication, record CRUD, validation and account isolation', async () => {
 const email=`owner-${randomUUID()}@example.test`, password='test-password-123';
 const owner=await login('accounts:signUp',{email,password,returnSecureToken:true});
 const signed=await login('accounts:signInWithPassword',{email,password,returnSecureToken:true});
 assert.equal(owner.localId,signed.localId);
 const other=await login('accounts:signUp',{email:`other-${randomUUID()}@example.test`,password,returnSecureToken:true});
 const id=randomUUID(), path=`households/${owner.localId}/records/${id}`;
 const dueAt=new Date(Date.now()+3600000).toISOString();
 const record={fields:{id:{stringValue:id},kind:{stringValue:'Tasks'},title:{stringValue:'Clean kitchen'},amount:{doubleValue:0},dueAt:{timestampValue:dueAt},category:{stringValue:'Other'},assignee:{stringValue:'Me'},important:{booleanValue:false},completed:{booleanValue:false},notes:{stringValue:''}}};
 assert.equal((await doc(path,owner.idToken,'PATCH',record)).status,200);
 assert.equal((await doc(path,owner.idToken)).status,200);
 assert.equal((await doc(`households/${owner.localId}/records`,owner.idToken)).status,200);
 for (const token of [undefined,other.idToken]) {
  for (const [method,body] of [['GET'],['PATCH',record],['DELETE']]) assert.equal((await doc(path,token,method,body)).status,403,`${method} isolation`);
 }
 for (const fields of [{...record.fields,amount:{doubleValue:-1}},{...record.fields,title:{stringValue:''}},{...record.fields,title:{stringValue:'   '}},{...record.fields,amount:{doubleValue:1000000000001}},{...record.fields,category:{stringValue:'x'.repeat(101)}},{...record.fields,notes:{stringValue:'x'.repeat(10001)}},{...record.fields,extra:{stringValue:'denied'}},{...record.fields,kind:{stringValue:'Unknown'}}]) {
  assert.equal((await doc(path,owner.idToken,'PATCH',{fields})).status,403,'invalid record must be denied');
 }
 for (const extra of [{latitude:{doubleValue:91},longitude:{doubleValue:0}},{latitude:{doubleValue:0},longitude:{doubleValue:181}},{latitude:{doubleValue:6.9}},{latitude:{stringValue:'6.9'},longitude:{doubleValue:79.8}}]) {
  assert.equal((await doc(path,owner.idToken,'PATCH',{fields:{...record.fields,...extra}})).status,403,'invalid coordinates denied');
 }
 assert.equal((await doc(path,owner.idToken,'PATCH',{fields:{...record.fields,reminderEnabled:{stringValue:'true'}}})).status,403,'invalid reminder setting denied');
 assert.equal((await doc(path,owner.idToken,'PATCH',{fields:{...record.fields,reminderEnabled:{booleanValue:false}}})).status,200,'valid reminder setting accepted');
 assert.equal((await doc(path,owner.idToken,'PATCH',{fields:{...record.fields,referenceNumber:{stringValue:'TASK-123'},reminderAt:{timestampValue:new Date(Date.now()+60000).toISOString()}}})).status,200,'reference number and earlier reminder accepted');
 assert.equal((await doc(path,owner.idToken,'PATCH',{fields:{...record.fields,reminderAt:{timestampValue:new Date(Date.now()+7200000).toISOString()}}})).status,403,'reminder after due date denied');
 assert.equal((await doc(path,owner.idToken,'PATCH',{fields:{...record.fields,latitude:{doubleValue:6.9271},longitude:{doubleValue:79.8612}}})).status,200,'valid coordinate pair accepted');
 assert.equal((await(await doc(path,owner.idToken)).json()).fields.latitude.doubleValue,6.9271);
 record.fields.completed={booleanValue:true};
 assert.equal((await doc(path,owner.idToken,'PATCH',record)).status,200);
 assert.equal((await (await doc(path,owner.idToken)).json()).fields.completed.booleanValue,true);
 const backup=`households/${owner.localId}`;
 assert.equal((await doc(backup,owner.idToken,'PATCH',{fields:{records:{stringValue:'[]'}}})).status,200);
 assert.equal((await doc(backup,other.idToken)).status,403);
 assert.equal((await doc(path,owner.idToken,'DELETE')).status,200);
 assert.equal((await doc(path,owner.idToken)).status,404);
 await login('accounts:sendOobCode',{requestType:'PASSWORD_RESET',email});
});

test('Verified email family invitations, atomic acceptance, shared records/chat and revocation', async () => {
 const password='family-test-password-123';
 async function verified(label) {
  const email=`family-${label}-${randomUUID()}@example.test`;
  const account=await login('accounts:signUp',{email,password,returnSecureToken:true});
  const update=await fetch(`${auth}accounts:update?key=demo-key`,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer owner'},body:JSON.stringify({localId:account.localId,emailVerified:true})});
  assert.equal(update.status,200,await update.text());
  return login('accounts:signInWithPassword',{email,password,returnSecureToken:true});
 }
 const owner=await verified('owner'), member=await verified('member'), stranger=await verified('stranger');
 const unverified=await login('accounts:signUp',{email:`unverified-${randomUUID()}@example.test`,password,returnSecureToken:true});
 const familyId=randomUUID(), familyPath=`families/${familyId}`, inviteId=randomUUID();
 const str=stringValue=>({stringValue});
 function write(path,fields,timestamp,exists=false) {
  return {update:{name:`projects/demo-homemate/databases/(default)/documents/${path}`,fields},currentDocument:{exists},...(timestamp?{updateTransforms:[{fieldPath:timestamp,setToServerValue:'REQUEST_TIME'}]}:{})};
 }
 async function commit(token,writes){return fetch(root+':commit',{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${token}`},body:JSON.stringify({writes})});}
 const ownerMember={uid:str(owner.localId),email:str(owner.email.toLowerCase()),displayName:str('Sarah'),role:str('owner')};
 let response=await commit(owner.idToken,[write(familyPath,{name:str('Test family'),ownerID:str(owner.localId),currency:str('LKR')},'createdAt'),write(`${familyPath}/members/${owner.localId}`,ownerMember,'joinedAt'),write(`users/${owner.localId}/families/${familyId}`,{familyID:str(familyId)})]);
 assert.equal(response.status,200,await response.text());
 const rename=write(familyPath,{name:str('Renamed family')},undefined,true);rename.updateMask={fieldPaths:['name']};
 assert.equal((await commit(owner.idToken,[rename])).status,200,'owner can rename family');
 assert.equal((await(await doc(familyPath,owner.idToken)).json()).fields.name.stringValue,'Renamed family');
 const forgedRename=write(familyPath,{name:str('Member rename')},undefined,true);forgedRename.updateMask={fieldPaths:['name']};
 assert.equal((await commit(member.idToken,[forgedRename])).status,403,'member cannot rename family');
 assert.equal((await doc(familyPath,stranger.idToken)).status,403,'stranger must not read family');
 const expiresAt={timestampValue:new Date(Date.now()+86400000).toISOString()};
 const inviteFields={familyID:str(familyId),familyName:str('Renamed family'),inviterID:str(owner.localId),email:str(member.email.toLowerCase()),status:str('pending'),expiresAt};
 response=await commit(owner.idToken,[write(`familyInvites/${inviteId}`,inviteFields,'createdAt')]);assert.equal(response.status,200,await response.text());
 function acceptWrites(user,id=inviteId){
  const accept=write(`familyInvites/${id}`,{status:str('accepted'),acceptedBy:str(user.localId)},undefined,true);accept.updateMask={fieldPaths:['status','acceptedBy']};
  const index=write(`users/${user.localId}/families/${familyId}`,{familyID:str(familyId)});delete index.currentDocument;
  return [accept,write(`${familyPath}/members/${user.localId}`,{uid:str(user.localId),email:str(user.email.toLowerCase()),displayName:str('Nimal'),role:str('member'),inviteID:str(id)},'joinedAt'),index];
 }
 response=await commit(stranger.idToken,acceptWrites(stranger));assert.equal(response.status,403,'wrong email cannot accept');
 response=await commit(unverified.idToken,acceptWrites(unverified));assert.equal(response.status,403,'unverified account cannot join');
 // A member cannot create a membership without atomically consuming the matching invite.
 response=await commit(member.idToken,[acceptWrites(member)[1]]);assert.equal(response.status,403,'forged membership must fail');
 response=await commit(member.idToken,acceptWrites(member));assert.equal(response.status,200,await response.text());
 assert.equal((await doc(familyPath,member.idToken)).status,200);
 response=await commit(member.idToken,acceptWrites(member));assert.equal(response.status,403,'accepted invite cannot be reused');
 const recordId=randomUUID(), recordPath=`${familyPath}/records/${recordId}`;
 const record={fields:{id:str(recordId),kind:str('Bills'),title:str('Shared electricity'),amount:{doubleValue:8500},dueAt:{timestampValue:new Date().toISOString()},category:str('Utilities'),assignee:str(member.email),important:{booleanValue:false},completed:{booleanValue:false},notes:str('')}};
 assert.equal((await doc(recordPath,owner.idToken,'PATCH',record)).status,200);
 assert.equal((await doc(recordPath,member.idToken)).status,200,'member must see owner record');
 const paidAt = new Date().toISOString();
 record.fields.completed={booleanValue:true};
 record.fields.paidAt={timestampValue:paidAt};
 assert.equal((await doc(recordPath,member.idToken,'PATCH',record)).status,200,'member can mark shared bill paid with the actual app timestamp');
 let reloaded = (await(await doc(recordPath,owner.idToken)).json()).fields;
 assert.equal(reloaded.completed.booleanValue,true);
 assert.equal(Date.parse(reloaded.paidAt.timestampValue),Date.parse(paidAt),'payment date survives reload by another member');
 for (const token of [stranger.idToken,undefined]) {
  for (const method of ['GET','PATCH','DELETE']) assert.equal((await doc(recordPath,token,method,method==='PATCH'?record:undefined)).status,403,'paid bill remains isolated');
 }
 assert.equal((await doc(recordPath,member.idToken,'PATCH',{fields:{...record.fields,paidAt:{stringValue:paidAt}}})).status,403,'payment timestamp must be a timestamp');
 record.fields.completed={booleanValue:false};
 delete record.fields.paidAt;
 assert.equal((await doc(recordPath,member.idToken,'PATCH',record)).status,200,'member can reopen bill');
 reloaded = (await(await doc(recordPath,owner.idToken)).json()).fields;
 assert.equal(reloaded.completed.booleanValue,false);
 assert.equal(reloaded.paidAt,undefined,'reopening removes the old payment timestamp');
 for(const token of [stranger.idToken,undefined]) assert.equal((await doc(recordPath,token)).status,403);
 // Shared membership never grants access to either user's private account records.
 assert.equal((await doc(`households/${owner.localId}/records`,member.idToken)).status,403);
 const sarahMessageId=randomUUID();response=await commit(owner.idToken,[write(`${familyPath}/messages/${sarahMessageId}`,{authorID:str(owner.localId),authorName:str('Sarah'),text:str('Dinner at seven?')},'createdAt')]);assert.equal(response.status,200,await response.text());
 assert.equal((await doc(`${familyPath}/messages/${sarahMessageId}`,member.idToken)).status,200,'Nimal sees Sarah’s message');
 const messageId=randomUUID();response=await commit(member.idToken,[write(`${familyPath}/messages/${messageId}`,{authorID:str(member.localId),authorName:str('Nimal'),text:str('Yes, I will be there.')},'createdAt')]);assert.equal(response.status,200,await response.text());
 assert.equal((await doc(`${familyPath}/messages/${messageId}`,owner.idToken)).status,200,'Sarah sees Nimal’s reply');
 response=await commit(stranger.idToken,[write(`${familyPath}/messages/${randomUUID()}`,{authorID:str(member.localId),authorName:str('Fake'),text:str('forged')},'createdAt')]);assert.equal(response.status,403);
 assert.equal((await doc(`${familyPath}/members/${owner.localId}`,member.idToken,'DELETE')).status,403,'member cannot remove owner');
 const announcementId=randomUUID(), announcementPath=`${familyPath}/announcements/${announcementId}`;
 const announcement={title:str('Water outage'),body:str('Water will be off tomorrow.'),authorID:str(member.localId),authorName:str('Member'),important:{booleanValue:true}};
 assert.equal((await commit(member.idToken,[write(announcementPath,announcement,'createdAt')])).status,200);
 assert.equal((await doc(announcementPath,owner.idToken)).status,200);
 const savedAnnouncement=(await(await doc(announcementPath,member.idToken)).json()).fields;
 for(const token of [stranger.idToken,undefined]) {
  for(const method of ['GET','PATCH','DELETE']) assert.equal((await doc(announcementPath,token,method,method==='PATCH'?{fields:savedAnnouncement}:undefined)).status,403);
 }
 assert.equal((await doc(announcementPath,owner.idToken,'PATCH',{fields:{...savedAnnouncement,title:str('Updated notice')}})).status,200,'owner may moderate');
 assert.equal((await doc(announcementPath,member.idToken,'PATCH',{fields:{...savedAnnouncement,authorID:str(owner.localId)}})).status,403,'authorship immutable');
 assert.equal((await commit(member.idToken,[write(`${familyPath}/announcements/${randomUUID()}`,{...announcement,authorID:str(owner.localId)},'createdAt')])).status,403,'cannot forge author');
 const ownerNotice=`${familyPath}/announcements/${randomUUID()}`;
 assert.equal((await commit(owner.idToken,[write(ownerNotice,{...announcement,authorID:str(owner.localId)},'createdAt')])).status,200);
 assert.equal((await doc(ownerNotice,member.idToken,'DELETE')).status,403,'ordinary member cannot delete others notice');
 assert.equal((await doc(announcementPath,member.idToken,'DELETE')).status,200,'author may delete own notice');
 assert.equal((await doc(`${familyPath}/members/${member.localId}`,owner.idToken,'DELETE')).status,200);
 for(const method of ['GET','PATCH','DELETE']) assert.equal((await doc(recordPath,member.idToken,method,method==='PATCH'?record:undefined)).status,403,'removed member must lose record access');
 assert.equal((await doc(`${familyPath}/messages`,member.idToken)).status,403,'removed member must lose chat access');
 // Cancelled invitations cannot be accepted, even by the correct verified recipient.
 const cancelled=randomUUID();response=await commit(owner.idToken,[write(`familyInvites/${cancelled}`,inviteFields,'createdAt')]);assert.equal(response.status,200);
 const cancel=write(`familyInvites/${cancelled}`,{status:str('cancelled')},undefined,true);cancel.updateMask={fieldPaths:['status']};assert.equal((await commit(owner.idToken,[cancel])).status,200);
 assert.equal((await commit(member.idToken,acceptWrites(member,cancelled))).status,403);
 const unverifiedInvite=randomUUID();
 response=await commit(owner.idToken,[write(`familyInvites/${unverifiedInvite}`,{...inviteFields,email:str(unverified.email.toLowerCase())},'createdAt')]);assert.equal(response.status,200);
 assert.equal((await commit(unverified.idToken,acceptWrites(unverified,unverifiedInvite))).status,403,'correct email still needs verification');
 const expired=randomUUID();
 response=await commit(owner.idToken,[write(`familyInvites/${expired}`,{...inviteFields,expiresAt:{timestampValue:new Date(Date.now()+1500).toISOString()}},'createdAt')]);assert.equal(response.status,200);
 await new Promise(resolve=>setTimeout(resolve,1800));
 assert.equal((await commit(member.idToken,acceptWrites(member,expired))).status,403,'expired invitation cannot be consumed');
 async function queryInvites(user,key,value) {
  return fetch(root+':runQuery',{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${user.idToken}`},body:JSON.stringify({structuredQuery:{from:[{collectionId:'familyInvites'}],where:{compositeFilter:{op:'AND',filters:[[key,value],['status','pending']].map(([fieldPath,value])=>({fieldFilter:{field:{fieldPath},op:'EQUAL',value:str(value)}}))}}}})});
 }
 assert.equal((await queryInvites(owner,'inviterID',owner.localId)).status,200,'owner invitation query must be authorized');
 assert.equal((await queryInvites(member,'email',member.email.toLowerCase())).status,200,'verified recipient query must be authorized');
 assert.equal((await queryInvites(stranger,'email',member.email.toLowerCase())).status,403,'another email cannot query invitations');
 assert.equal((await queryInvites(unverified,'email',unverified.email.toLowerCase())).status,403,'unverified email cannot query invitations');
 const rejoin=randomUUID();
 assert.equal((await commit(owner.idToken,[write(`familyInvites/${rejoin}`,inviteFields,'createdAt')])).status,200);
 response=await commit(member.idToken,acceptWrites(member,rejoin));assert.equal(response.status,200,await response.text());
 assert.equal((await doc(recordPath,member.idToken)).status,200,'new valid invite must restore family access after removal');
});

test('Private paid bills retain timestamps without weakening account isolation', async () => {
 const password='private-bill-test-123';
 const owner=await login('accounts:signUp',{email:`bill-${randomUUID()}@example.test`,password,returnSecureToken:true});
 const other=await login('accounts:signUp',{email:`bill-other-${randomUUID()}@example.test`,password,returnSecureToken:true});
 const id=randomUUID(), path=`households/${owner.localId}/records/${id}`;
 const paidAt=new Date().toISOString();
 const fields={id:{stringValue:id},kind:{stringValue:'Bills'},title:{stringValue:'Electricity'},amount:{doubleValue:8500},dueAt:{timestampValue:paidAt},category:{stringValue:'Utilities'},assignee:{stringValue:'Me'},important:{booleanValue:false},completed:{booleanValue:false},notes:{stringValue:''}};
 assert.equal((await doc(path,owner.idToken,'PATCH',{fields})).status,200);
 fields.completed={booleanValue:true}; fields.paidAt={timestampValue:paidAt};
 assert.equal((await doc(path,owner.idToken,'PATCH',{fields})).status,200);
 const reloaded=(await(await doc(path,owner.idToken)).json()).fields;
 assert.equal(reloaded.completed.booleanValue,true);
 assert.equal(Date.parse(reloaded.paidAt.timestampValue),Date.parse(paidAt));
 for(const token of [other.idToken,undefined]) {
  for(const method of ['GET','PATCH','DELETE']) assert.equal((await doc(path,token,method,method==='PATCH'?{fields}:undefined)).status,403);
 }
 for(const invalid of [{stringValue:paidAt},{integerValue:'1'},{nullValue:null}]) {
  assert.equal((await doc(path,owner.idToken,'PATCH',{fields:{...fields,paidAt:invalid}})).status,403);
 }
 fields.completed={booleanValue:false}; delete fields.paidAt;
 assert.equal((await doc(path,owner.idToken,'PATCH',{fields})).status,200);
 assert.equal((await(await doc(path,owner.idToken)).json()).fields.paidAt,undefined);
 // Legacy paid bills without a payment date remain readable/writable.
 fields.completed={booleanValue:true};
 assert.equal((await doc(path,owner.idToken,'PATCH',{fields})).status,200);
});

test('Account profile is restored on a second login and isolated by UID', async () => {
 const password = 'profile-password-123', email = `profile-${randomUUID()}@example.test`;
 const owner = await login('accounts:signUp', {email, password, returnSecureToken:true});
 const other = await login('accounts:signUp', {email:`other-profile-${randomUUID()}@example.test`, password, returnSecureToken:true});
 const path = `users/${owner.localId}/profile/details`;
 const profile = {name:'Amaya', household:'Home', personalDetails:{fullName:'Amaya', phone:'0771234567', avatarData:'AQID'}};
 const body = {fields:{payload:{stringValue:JSON.stringify(profile)},version:{integerValue:'1'}}};
 assert.equal((await doc(path, owner.idToken, 'PATCH', body)).status, 200);
 const secondDevice = await login('accounts:signInWithPassword', {email, password, returnSecureToken:true});
 const restored = await doc(path, secondDevice.idToken);
 assert.equal(restored.status, 200);
 assert.deepEqual(JSON.parse((await restored.json()).fields.payload.stringValue), profile);
 for (const token of [undefined, other.idToken]) {
  for (const [method, data] of [['GET'], ['PATCH', body], ['DELETE']]) {
   assert.equal((await doc(path, token, method, data)).status, 403);
  }
 }
 for (const fields of [
  {payload:{stringValue:'{}'}},
  {...body.fields,version:{integerValue:'2'}},
  {...body.fields,payload:{stringValue:'x'.repeat(800001)}},
  {...body.fields,extra:{stringValue:'denied'}}
 ]) assert.equal((await doc(path, owner.idToken, 'PATCH', {fields})).status, 403);
});

test('Full account snapshots keep chunks private, immutable and reject stale manifests', async () => {
 const password='sync-password-123';
 const owner=await login('accounts:signUp',{email:`sync-${randomUUID()}@example.test`,password,returnSecureToken:true});
 const other=await login('accounts:signUp',{email:`other-sync-${randomUUID()}@example.test`,password,returnSecureToken:true});
 const id='a'.repeat(64), chunk=`users/${owner.localId}/syncChunks/${id}`, manifest=`users/${owner.localId}/sync/state`;
 const bytes={fields:{data:{bytesValue:Buffer.from('account-data').toString('base64')}}};
 assert.equal((await doc(chunk,owner.idToken,'PATCH',bytes)).status,200);
 assert.equal((await doc(chunk,owner.idToken,'PATCH',bytes)).status,403,'immutable chunks');
 const body={fields:{version:{integerValue:'1'},chunks:{arrayValue:{values:[{stringValue:id}]}}}};
 const created=await doc(`${manifest}?currentDocument.exists=false`,owner.idToken,'PATCH',body);
 assert.equal(created.status,200);
 const revision=(await created.json()).updateTime;
 assert.equal((await doc(`${manifest}?currentDocument.updateTime=${encodeURIComponent(revision)}`,owner.idToken,'PATCH',body)).status,200);
 const stale=await doc(`${manifest}?currentDocument.updateTime=${encodeURIComponent(revision)}`,owner.idToken,'PATCH',body);
 assert.ok([400,409,412].includes(stale.status),'stale manifest must fail');
 for(const token of [undefined,other.idToken]) {
  assert.equal((await doc(chunk,token)).status,403);
  assert.equal((await doc(manifest,token)).status,403);
  assert.equal((await doc(manifest,token,'PATCH',body)).status,403);
 }
 assert.equal((await doc(`users/${owner.localId}/syncChunks/${'b'.repeat(64)}`,owner.idToken,'PATCH',{fields:{data:{bytesValue:Buffer.alloc(450001).toString('base64')}}})).status,403);
});
