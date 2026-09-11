import fs from 'node:fs';

function read(path){
  if(!fs.existsSync(path)) throw new Error(`Missing observer-scoping file: ${path}`);
  return fs.readFileSync(path,'utf8');
}

const tkPolish = read('timekeeping-polish.js');
const maps = read('job-map-documents.js');
const draftRestore = read('dark-contrast-draft-edit-fix.js');
const jsaSignatures = read('jsa-signatures.js');
const tkRoster = read('timekeeping-roster.js');

if(tkPolish.includes("obs.observe(document.body,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['class','disabled']})")){
  throw new Error('Timekeeping polish must not observe all body mutations.');
}
if(!tkPolish.includes("pageObserver.observe(page,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['class','disabled']})")){
  throw new Error('Timekeeping polish must scope its long-lived observer to #timekeepingPage.');
}
if(!tkPolish.includes("if(byId('timekeepingPage'))")){
  throw new Error('Timekeeping polish must support attaching after the dynamic Timekeeping page is created.');
}
if(!tkPolish.includes("attachObserver.disconnect()")){
  throw new Error('The temporary Timekeeping attach observer must disconnect after the page is found.');
}
if(maps.includes("observer.observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']})")){
  throw new Error('Job maps must not return to a broad whole-app class observer.');
}

if(draftRestore.includes("const observer=new MutationObserver(scan);observer.observe(document.body,{subtree:true,childList:true})")){
  throw new Error('Draft crew-time restore must not continuously observe the entire app.');
}
if(!draftRestore.includes("productionObserver.observe(production,{subtree:true,childList:true})")){
  throw new Error('Draft crew-time restore must keep a Production-scoped observer.');
}
if(!draftRestore.includes("formObserver.observe(form,{subtree:true,childList:true,attributes:true,attributeFilter:['class','data-report-id']})")){
  throw new Error('Draft crew-time restore must watch the Daily Report form for report changes.');
}
if(!draftRestore.includes("if(attachScopedObservers())attachObserver.disconnect()")){
  throw new Error('Temporary draft-restore attach observer must disconnect after required roots exist.');
}
if(!draftRestore.includes("throw new Error('Saved crew time is still loading. Your existing hours were preserved.")){
  throw new Error('Draft crew-time preservation save guard is missing.');
}

if(jsaSignatures.includes("const obs=new MutationObserver(upgrade);obs.observe(document.body,{subtree:true,childList:true})")){
  throw new Error('JSA signatures must not continuously observe the entire app.');
}
if(!jsaSignatures.includes("safetyObserver.observe(page,{subtree:true,childList:true})")){
  throw new Error('JSA signatures must scope their long-lived observer to #safetyPage.');
}
if(!jsaSignatures.includes("if(attachSafetyObserver())attachObserver.disconnect()")){
  throw new Error('Temporary JSA signature attach observer must disconnect after Safety is available.');
}
for(const token of ["window.addEventListener('pointermove'","window.addEventListener('touchmove'","window.addEventListener('pointerup'","window.addEventListener('pointercancel'","Signature captured","Clear Signature"]){
  if(!jsaSignatures.includes(token)) throw new Error(`JSA signature interaction wiring is missing: ${token}`);
}

if(tkRoster.includes("observer.observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']})")){
  throw new Error('Timekeeping roster must not continuously observe the entire app.');
}
if(!tkRoster.includes("timekeepingObserver.observe(timekeepingPage,{subtree:true,childList:true,attributes:true,attributeFilter:['class']})")){
  throw new Error('Timekeeping roster must observe only the Timekeeping workspace for roster UI changes.');
}
if(!tkRoster.includes("dailyObserver.observe(dailyForm,{subtree:true,childList:true,attributes:true,attributeFilter:['class','data-report-id']})")){
  throw new Error('Timekeeping roster must observe the Daily Report form for Foreman crew auto-load changes.');
}
if(!tkRoster.includes("if(attachScopedObservers())attachObserver.disconnect()")){
  throw new Error('Temporary roster attach observer must disconnect after required roots exist.');
}
for(const token of ['admin_import_timekeeping_roster','restrictDailySelectors','autoLoadAssignedCrew','assigned_foreman_id']){
  if(!tkRoster.includes(token)) throw new Error(`Timekeeping roster behavior is missing: ${token}`);
}

console.log('Observer scoping validation passed.');
