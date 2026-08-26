import fs from 'node:fs';
function replaceOnce(path,from,to,label){let text=fs.readFileSync(path,'utf8');if(!text.includes(from))throw new Error(`Missing ${label} in ${path}`);fs.writeFileSync(path,text.replace(from,to));}
replaceOnce('expanded-jsa.js',"load('timekeeping.js?v=20260823i'","load('timekeeping.js?v=20260826a'",'timekeeping cache version');
replaceOnce('expanded-jsa.js',"load('timekeeping-report-v2.js?v=20260823b'","load('timekeeping-report-v2.js?v=20260826c'",'timekeeping report cache version');
replaceOnce('index.html','expanded-jsa.js?v=20260825a','expanded-jsa.js?v=20260826a','expanded JSA cache version');
