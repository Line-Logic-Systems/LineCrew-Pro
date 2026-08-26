import fs from 'node:fs';
const path='index.html';
let html=fs.readFileSync(path,'utf8');
function replaceOnce(from,to,label){if(!html.includes(from))throw new Error(`Missing ${label}`);html=html.replace(from,to);}
replaceOnce(
`const doneButton = $('closeDailyUnitEditorBtn');\nconst bottomDoneButton = $('closeDailyUnitEditorBottomBtn');\n[doneButton,bottomDoneButton].filter(Boolean).forEach(button=>{\nbutton.disabled = false;\nbutton.textContent = 'Done Adding Units';\n});`,
`const doneButton = $('closeDailyUnitEditorBtn');\nconst bottomDoneButton = $('closeDailyUnitEditorBottomBtn');\ndoneButton.disabled = false;\ndoneButton.textContent = 'Done Adding Units';\nif(bottomDoneButton){\nbottomDoneButton.disabled = false;\nbottomDoneButton.textContent = 'Done Adding Units';\n}`,
'close reset');
replaceOnce(
`const topButton = $('closeDailyUnitEditorBtn');\nconst bottomButton = $('closeDailyUnitEditorBottomBtn');\n[topButton,bottomButton].filter(Boolean).forEach(button=>{\nbutton.disabled = true;\nbutton.textContent = 'Saving & Finishing...';\n});\nconst saved = await saveDailyUnitBatch({ closeAfterSave:true });\nif(!saved){\n[topButton,bottomButton].filter(Boolean).forEach(button=>{\nbutton.disabled = false;\nbutton.textContent = 'Done Adding Units';\n});\n}`,
`const doneButton = $('closeDailyUnitEditorBtn');\nconst bottomDoneButton = $('closeDailyUnitEditorBottomBtn');\ndoneButton.disabled = true;\ndoneButton.textContent = 'Saving & Finishing...';\nif(bottomDoneButton){\nbottomDoneButton.disabled = true;\nbottomDoneButton.textContent = 'Saving & Finishing...';\n}\nconst saved = await saveDailyUnitBatch({ closeAfterSave:true });\nif(!saved){\ndoneButton.disabled = false;\ndoneButton.textContent = 'Done Adding Units';\nif(bottomDoneButton){\nbottomDoneButton.disabled = false;\nbottomDoneButton.textContent = 'Done Adding Units';\n}\n}`,
'save progress state');
fs.writeFileSync(path,html);
console.log('Patched shared Done Adding Units states.');
