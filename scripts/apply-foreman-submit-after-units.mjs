import fs from 'node:fs';

const path = 'index.html';
let html = fs.readFileSync(path, 'utf8');

const marker = `function closeDailyUnitEditor(){
const doneButton = $('closeDailyUnitEditorBtn');`;

if (!html.includes(marker)) {
  throw new Error('Expected closeDailyUnitEditor source marker was not found.');
}

const replacement = `async function offerForemanSubmitAfterUnits(report){
if(!report || currentUserRole() !== 'foreman') return;
if(String(report.status || '').toLowerCase() !== 'draft') return;
if(report.foreman_id && report.foreman_id !== currentProfile?.id) return;
const existing = $('dailyReportSubmitPrompt');
if(existing) existing.remove();
const backdrop = document.createElement('div');
backdrop.id = 'dailyReportSubmitPrompt';
backdrop.className = 'pilot-feedback-backdrop';
const card = document.createElement('div');
card.className = 'card pilot-feedback-card';
card.innerHTML = '<h3>Units Saved — Ready to Submit</h3>' +
'<p>Your Daily Report is still a draft. Submit it to your General Foreman now, or keep it as a draft if you still need to make changes.</p>';
const submitButton = document.createElement('button');
submitButton.className = 'success';
submitButton.textContent = 'Submit Report to GF';
const keepDraftButton = document.createElement('button');
keepDraftButton.className = 'secondary';
keepDraftButton.textContent = 'Keep as Draft';
submitButton.onclick = async () => {
submitButton.disabled = true;
keepDraftButton.disabled = true;
submitButton.textContent = 'Submitting...';
const { error } = await sb.rpc('submit_daily_report', {
p_report_id:report.id
});
if(error){
submitButton.disabled = false;
keepDraftButton.disabled = false;
submitButton.textContent = 'Submit Report to GF';
alert('Unable to submit report: ' + error.message);
return;
}
backdrop.remove();
alert('Daily report submitted to GF for review.');
await loadProductionReports();
};
keepDraftButton.onclick = async () => {
backdrop.remove();
await loadProductionReports();
};
card.appendChild(submitButton);
card.appendChild(keepDraftButton);
backdrop.appendChild(card);
document.body.appendChild(backdrop);
submitButton.focus();
}
function closeDailyUnitEditor(){
const reportFinished = currentDailyUnitReport;
const doneButton = $('closeDailyUnitEditorBtn');`;

html = html.replace(marker, replacement);

const closeTail = `$('productionList').classList.remove('hidden');
}`;
const firstCloseIndex = html.indexOf('function closeDailyUnitEditor(){');
const tailIndex = html.indexOf(closeTail, firstCloseIndex);
if (tailIndex === -1) {
  throw new Error('Expected closeDailyUnitEditor tail was not found.');
}
const closeTailReplacement = `$('productionList').classList.remove('hidden');
if(reportFinished){
void offerForemanSubmitAfterUnits(reportFinished);
}
}`;
html = html.slice(0, tailIndex) + closeTailReplacement + html.slice(tailIndex + closeTail.length);

fs.writeFileSync(path, html);
console.log('Patched Foreman Done Adding Units flow with immediate Submit-to-GF choice.');
