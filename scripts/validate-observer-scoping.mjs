import fs from 'node:fs';

function read(path){
  if(!fs.existsSync(path)) throw new Error(`Missing observer-scoping file: ${path}`);
  return fs.readFileSync(path,'utf8');
}

const tkPolish = read('timekeeping-polish.js');
const maps = read('job-map-documents.js');

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

console.log('Observer scoping validation passed.');
