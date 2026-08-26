import fs from 'node:fs';

const path='index.html';
let html=fs.readFileSync(path,'utf8');
function replaceOnce(from,to,label){
  if(!html.includes(from)) throw new Error(`Missing ${label}`);
  html=html.replace(from,to);
}

replaceOnce(
`<div class="button-row">\n<button id="addDailyUnitRowsBtn" class="secondary">\n+ Add 5 Unit Lines\n</button>\n<button id="saveDailyUnitBatchBtn" class="success">\nSave Pole &amp; Add Next\n</button>\n</div>`,
`<div class="button-row">\n<button id="addDailyUnitRowsBtn" class="secondary">\n+ Add 5 Unit Lines\n</button>\n<button id="saveDailyUnitBatchBtn" class="success">\nSave Pole &amp; Add Next\n</button>\n<button id="closeDailyUnitEditorBottomBtn" class="secondary">\nDone Adding Units\n</button>\n</div>`,
'bottom unit-entry controls');

replaceOnce(
`$('addDailyUnitRowsBtn').onclick = () => addDailyUnitBatchRows(5);\n$('saveDailyUnitBatchBtn').onclick = saveDailyUnitBatch;`,
`$('addDailyUnitRowsBtn').onclick = () => addDailyUnitBatchRows(5);\n$('saveDailyUnitBatchBtn').onclick = saveDailyUnitBatch;`,
'unit-entry action anchor');

replaceOnce(
`$('closeDailyUnitEditorBtn').onclick = async () => {\nif(!userCanEditDailyReportDraft(currentDailyUnitReport)){\ncloseDailyUnitEditor();\nreturn;\n}\nconst hasUnsavedLines = currentDailyUnitBatchRows.some(row =>\nrow.selectedItem || row.searchInput.value.trim() ||\nrow.quantityInput.value.trim()\n) || $('dailyUnitPoleLocation').value.trim();\nif(hasUnsavedLines){\nconst doneButton = $('closeDailyUnitEditorBtn');\ndoneButton.disabled = true;\ndoneButton.textContent = 'Saving & Finishing...';\nconst saved = await saveDailyUnitBatch({ closeAfterSave:true });\nif(!saved){\ndoneButton.disabled = false;\ndoneButton.textContent = 'Done Adding Units';\n}\nreturn;\n}\nif(currentDailySavedUnits.length === 0){\nalert('No units are saved yet. Enter a pole/location and unit before finishing.');\n$('dailyUnitPoleLocation').focus();\nreturn;\n}\ncloseDailyUnitEditor();\n};`,
`async function finishDailyUnitEntry(triggerButton){\nif(!userCanEditDailyReportDraft(currentDailyUnitReport)){\ncloseDailyUnitEditor();\nreturn;\n}\nconst hasUnsavedLines = currentDailyUnitBatchRows.some(row =>\nrow.selectedItem || row.searchInput.value.trim() ||\nrow.quantityInput.value.trim()\n) || $('dailyUnitPoleLocation').value.trim();\nif(hasUnsavedLines){\nconst topButton = $('closeDailyUnitEditorBtn');\nconst bottomButton = $('closeDailyUnitEditorBottomBtn');\n[topButton,bottomButton].filter(Boolean).forEach(button=>{\nbutton.disabled = true;\nbutton.textContent = 'Saving & Finishing...';\n});\nconst saved = await saveDailyUnitBatch({ closeAfterSave:true });\nif(!saved){\n[topButton,bottomButton].filter(Boolean).forEach(button=>{\nbutton.disabled = false;\nbutton.textContent = 'Done Adding Units';\n});\n}\nreturn;\n}\nif(currentDailySavedUnits.length === 0){\nalert('No units are saved yet. Enter a pole/location and unit before finishing.');\n$('dailyUnitPoleLocation').focus();\nreturn;\n}\ncloseDailyUnitEditor();\n}\n$('closeDailyUnitEditorBtn').onclick = () => finishDailyUnitEntry($('closeDailyUnitEditorBtn'));\n$('closeDailyUnitEditorBottomBtn').onclick = () => finishDailyUnitEntry($('closeDailyUnitEditorBottomBtn'));`,
'done-adding-units handler');

replaceOnce(
`const doneButton = $('closeDailyUnitEditorBtn');\ndoneButton.disabled = false;\ndoneButton.textContent = 'Done Adding Units';`,
`const doneButton = $('closeDailyUnitEditorBtn');\nconst bottomDoneButton = $('closeDailyUnitEditorBottomBtn');\n[doneButton,bottomDoneButton].filter(Boolean).forEach(button=>{\nbutton.disabled = false;\nbutton.textContent = 'Done Adding Units';\n});`,
'done button reset');

fs.writeFileSync(path,html);
console.log('Patched unit-entry finish controls.');
