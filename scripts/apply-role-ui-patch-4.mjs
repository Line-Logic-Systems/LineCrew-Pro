import fs from 'node:fs';
const path='index.html';
let html=fs.readFileSync(path,'utf8');
const done=[];
function r(before,after,label){ if(!html.includes(before)) throw new Error('Missing target: '+label); html=html.replace(before,after); done.push(label); }

r(`function stormExportReports(){\n  if(!['admin', 'gf'].includes(String(currentProfile?.role || '').toLowerCase())){\n    alert('Only an Admin or General Foreman can export storm reporting.');`,
`function stormExportReports(){\n  if(!userCanUseReporting() || !userCanExport()){\n    alert('You do not have permission to export storm reporting.');`, 'storm export capability');

r(`function exportFilteredProductionCsv(){\n  if(!['admin', 'gf'].includes(String(currentProfile?.role || '').toLowerCase())){\n    alert('Only an Admin or General Foreman can export company production reporting.');`,
`function exportFilteredProductionCsv(){\n  if(!userCanUseReporting() || !userCanExport()){\n    alert('You do not have permission to export company production reporting.');`, 'production export capability');

r(`  currentDailyAuthorizationSummaries = new Map();\n  const canReviewProduction = ['admin', 'gf'].includes(\n    String(currentProfile?.role || '').toLowerCase()\n  );\n\n  if(canReviewProduction){`,
`  currentDailyAuthorizationSummaries = new Map();\n  const canReviewProduction = userCanReviewProduction();\n  const canViewProductionReporting = userCanUseReporting();\n\n  if(canReviewProduction || canViewProductionReporting){`, 'production review and reporting split');

r(`  document.querySelectorAll('.production-reporting-control').forEach(control =>\n    control.classList.toggle('hidden', !canReviewProduction)\n  );\n  populateProductionReportingFilters(reports || [], canReviewProduction);`,
`  document.querySelectorAll('.production-reporting-control').forEach(control =>\n    control.classList.toggle('hidden', !canViewProductionReporting)\n  );\n  populateProductionReportingFilters(reports || [], canViewProductionReporting);`, 'reporting filter visibility');

for(const id of ['productionJobFilter','productionForemanFilter','productionCrewFilter','productionExceptionFilter','productionCompletionFilter','productionWorkModeFilter','productionStormEventFilter']){
  html = html.replace(`const ${id.replace('production','').replace('Filter','').replace(/^./,c=>c.toLowerCase())}Filter = canReviewProduction ? $('${id}').value : '';`, `const ${id.replace('production','').replace('Filter','').replace(/^./,c=>c.toLowerCase())}Filter = canViewProductionReporting ? $('${id}').value : '';`);
}
// Explicit replacements because a few local variable names don't follow the simple mapping above.
html = html.replaceAll(`const jobFilter = canReviewProduction ? $('productionJobFilter').value : '';`, `const jobFilter = canViewProductionReporting ? $('productionJobFilter').value : '';`);
html = html.replaceAll(`const foremanFilter = canReviewProduction ? $('productionForemanFilter').value : '';`, `const foremanFilter = canViewProductionReporting ? $('productionForemanFilter').value : '';`);
html = html.replaceAll(`const crewFilter = canReviewProduction ? $('productionCrewFilter').value : '';`, `const crewFilter = canViewProductionReporting ? $('productionCrewFilter').value : '';`);
html = html.replaceAll(`const exceptionFilter = canReviewProduction ? $('productionExceptionFilter').value : '';`, `const exceptionFilter = canViewProductionReporting ? $('productionExceptionFilter').value : '';`);
html = html.replaceAll(`const completionFilter = canReviewProduction ? $('productionCompletionFilter').value : '';`, `const completionFilter = canViewProductionReporting ? $('productionCompletionFilter').value : '';`);
html = html.replaceAll(`const workModeFilter = canReviewProduction ? $('productionWorkModeFilter').value : '';`, `const workModeFilter = canViewProductionReporting ? $('productionWorkModeFilter').value : '';`);
html = html.replaceAll(`const stormEventFilter = canReviewProduction ? $('productionStormEventFilter').value : '';`, `const stormEventFilter = canViewProductionReporting ? $('productionStormEventFilter').value : '';`);

r(`  renderProductionReportingSummary(filteredReports, canReviewProduction);\n  renderStormEventDashboard(filteredReports, canReviewProduction);`,
`  renderProductionReportingSummary(filteredReports, canViewProductionReporting);\n  renderStormEventDashboard(filteredReports, canViewProductionReporting);`, 'production reporting render access');

r(`      const canDelete =\n        attachment.uploaded_by === currentProfile?.id ||\n        ['admin','gf'].includes(String(currentProfile?.role || '').toLowerCase());`,
`      const canDelete =\n        attachment.uploaded_by === currentProfile?.id ||\n        userCanReviewProduction();`, 'attachment review delete capability');

fs.writeFileSync(path,html);
console.log('Applied:',done.join(', '));
