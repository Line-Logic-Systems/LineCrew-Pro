import fs from 'node:fs';
const path='index.html';
let html=fs.readFileSync(path,'utf8');
const done=[];
function r(before,after,label){ if(!html.includes(before)) throw new Error('Missing target: '+label); html=html.replace(before,after); done.push(label); }

r(`function userCanReviewProduction(){ return userHasCapability('production_review') || currentUserRole() === 'gf'; }`,
`function userCanReviewProduction(){ return userHasCapability('production_review') || currentUserRole() === 'gf'; }\nfunction userCanManageProductionRecords(){ return userHasCapability('production_review'); }`, 'production management helper');

r(`function dailyReportAuthorizationSummaryMarkup(report, summary){\n  if(!summary || !['admin', 'gf'].includes(\n    String(currentProfile?.role || '').toLowerCase()\n  )) return '';`,
`function dailyReportAuthorizationSummaryMarkup(report, summary){\n  if(!summary || (!userCanReviewProduction() && !userCanUseReporting())) return '';`, 'authorization summary visibility');

r(` if(\n  String(report.status || '').toLowerCase() === 'submitted' &&\n  ['admin','gf'].includes(\n    String(currentProfile.role || '').toLowerCase()\n  )\n){`,
` if(\n  String(report.status || '').toLowerCase() === 'submitted' &&\n  userCanReviewProduction()\n){`, 'review action visibility');

r(`    const requiresAdminOverride =\n      redlineCount > 0 &&\n      currentCompany?.require_gf_redline_approval === true &&\n      String(currentProfile?.role || '').toLowerCase() === 'admin';`,
`    const requiresAdminOverride =\n      redlineCount > 0 &&\n      currentCompany?.require_gf_redline_approval === true &&\n      currentUserRole() !== 'gf';`, 'redline override hierarchy');

html=html.replaceAll('Enter the Admin override reason:', 'Enter the leadership override reason:');
html=html.replaceAll('An Admin override reason is required for a redline report.', 'An override reason is required for a redline report.');
html=html.replaceAll('Your Admin override reason will be recorded. Continue?', 'Your override reason will be recorded. Continue?');

r(`if(String(currentProfile?.role || '').toLowerCase() === 'admin'){\n  const reportStatus = String(report.status || 'draft').toLowerCase();`,
`if(userCanManageProductionRecords()){\n  const reportStatus = String(report.status || 'draft').toLowerCase();`, 'destructive report management capability');

fs.writeFileSync(path,html);
console.log('Applied:',done.join(', '));
