import fs from 'node:fs';

const path = 'index.html';
let text = fs.readFileSync(path, 'utf8');

if (text.includes('id="takeCompanyJsaPhotoBtn"')) {
  console.log('JSA camera capture already present.');
  process.exit(0);
}

const oldHtml = `    <label for="companyJsaUploadFiles">JSA File(s) *</label>\n    <input id="companyJsaUploadFiles" type="file" multiple accept="application/pdf,image/jpeg,image/png,image/heic,image/heif">\n    <p class="muted">PDF, JPG, PNG or HEIC/HEIF. Up to 15 MB per file. Multiple pages/photos are allowed.</p>`;

const newHtml = `    <label>JSA Photo(s) / File(s) *</label>\n    <button id="takeCompanyJsaPhotoBtn" type="button" class="success">📷 Take JSA Photo</button>\n    <input id="companyJsaCameraInput" class="hidden" type="file" accept="image/*" capture="environment">\n    <div id="companyJsaCameraStatus" class="muted">No camera photos attached yet.</div>\n\n    <label for="companyJsaUploadFiles">Or Choose Existing File(s)</label>\n    <input id="companyJsaUploadFiles" type="file" multiple accept="application/pdf,image/jpeg,image/png,image/heic,image/heif">\n    <p class="muted">Take one photo per page, or choose PDF/JPG/PNG/HEIC files. Up to 15 MB per file. Multiple pages/photos are allowed.</p>`;

if (!text.includes(oldHtml)) throw new Error('JSA file input anchor not found');
text = text.replace(oldHtml, newHtml);

const cameraJs = `\nlet pendingCompanyJsaCameraFiles = [];\n\nfunction companyJsaFileKey(file){\n  return [file.name, file.size, file.lastModified].join(':');\n}\n\nfunction getCompanyJsaUploadFiles(){\n  const chosen = [...($('companyJsaUploadFiles')?.files || [])];\n  const all = [...pendingCompanyJsaCameraFiles, ...chosen];\n  const seen = new Set();\n  return all.filter(file => {\n    const key = companyJsaFileKey(file);\n    if(seen.has(key)) return false;\n    seen.add(key);\n    return true;\n  });\n}\n\nfunction updateCompanyJsaCameraStatus(){\n  const cameraCount = pendingCompanyJsaCameraFiles.length;\n  const chosenCount = [...($('companyJsaUploadFiles')?.files || [])].length;\n  const total = getCompanyJsaUploadFiles().length;\n  const status = $('companyJsaCameraStatus');\n  if(!status) return;\n  if(total === 0){\n    status.textContent = 'No camera photos attached yet.';\n    return;\n  }\n  const parts = [];\n  if(cameraCount) parts.push(cameraCount + ' camera photo' + (cameraCount === 1 ? '' : 's'));\n  if(chosenCount) parts.push(chosenCount + ' chosen file' + (chosenCount === 1 ? '' : 's'));\n  status.textContent = parts.join(' + ') + ' attached. Tap Take JSA Photo again for another page.';\n}\n\nfunction resetCompanyJsaCameraFiles(){\n  pendingCompanyJsaCameraFiles = [];\n  if($('companyJsaCameraInput')) $('companyJsaCameraInput').value = '';\n  updateCompanyJsaCameraStatus();\n}\n\n$('takeCompanyJsaPhotoBtn').onclick = () => {\n  const input = $('companyJsaCameraInput');\n  if(!input) return;\n  input.value = '';\n  input.click();\n};\n\n$('companyJsaCameraInput').addEventListener('change', event => {\n  const files = [...(event.target.files || [])];\n  if(!files.length) return;\n  const invalid = files.find(file => !allowedJsaFile(file));\n  if(invalid){\n    alert('Unsupported or oversized photo: ' + invalid.name + '. Use a supported image up to 15 MB.');\n    event.target.value = '';\n    return;\n  }\n  pendingCompanyJsaCameraFiles.push(...files);\n  event.target.value = '';\n  updateCompanyJsaCameraStatus();\n});\n\n$('companyJsaUploadFiles').addEventListener('change', updateCompanyJsaCameraStatus);\n\n`;

const uploadButtonAnchor = `$('uploadCompanyJsaBtn').onclick = async () => {`;
if (!text.includes(uploadButtonAnchor)) throw new Error('Upload button anchor not found');
text = text.replace(uploadButtonAnchor, cameraJs + uploadButtonAnchor);

const resetAnchor = `  $('companyJsaUploadFiles').value = '';\n`;
if (!text.includes(resetAnchor)) throw new Error('Upload reset anchor not found');
text = text.replace(resetAnchor, resetAnchor + `  resetCompanyJsaCameraFiles();\n`);

const filesAnchor = `  const files = [...($('companyJsaUploadFiles').files || [])];`;
if (!text.includes(filesAnchor)) throw new Error('Save files anchor not found');
text = text.replace(filesAnchor, `  const files = getCompanyJsaUploadFiles();`);

fs.writeFileSync(path, text);
console.log('Added direct JSA camera capture UI and queued-photo handling.');
