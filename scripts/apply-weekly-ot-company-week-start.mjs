import fs from 'node:fs';

function replaceOnce(text, from, to, label){
  if(!text.includes(from)) throw new Error(`Missing ${label}`);
  return text.replace(from,to);
}

let detail=fs.readFileSync('timekeeping-input-v2.js','utf8');
detail=replaceOnce(detail,
`  function syncPayrollFromClock(row){const total=workedHours(row),out=row.querySelector('.tk-hours-worked');if(total===null){if(out)out.textContent='Worked: —';return;}const reg=Math.min(8,total),ot=Math.max(0,total-8),ri=row.querySelector('.tk-regular'),oi=row.querySelector('.tk-ot');if(ri)ri.value=reg.toFixed(2);if(oi)oi.value=ot.toFixed(2);ri?.dispatchEvent(new Event('change',{bubbles:true}));oi?.dispatchEvent(new Event('change',{bubbles:true}));if(out)out.textContent=\`Worked: \${total.toFixed(2)} h\`;}`,
`  function syncPayrollFromClock(row){const total=workedHours(row),out=row.querySelector('.tk-hours-worked');if(total===null){if(out)out.textContent='Worked: —';return;}const ri=row.querySelector('.tk-regular'),oi=row.querySelector('.tk-ot');if(ri)ri.value=total.toFixed(2);if(oi)oi.value='0.00';ri?.dispatchEvent(new Event('change',{bubbles:true}));oi?.dispatchEvent(new Event('change',{bubbles:true}));if(out)out.textContent=\`Worked: \${total.toFixed(2)} h · Weekly OT is calculated after save\`;}`,
'daily 8-hour OT splitter');
fs.writeFileSync('timekeeping-input-v2.js',detail);

let tk=fs.readFileSync('timekeeping.js','utf8');
tk=replaceOnce(tk,
`    const {error:deleteError}=await staleQuery;\n    if(deleteError)throw deleteError;\n    crewRowsLoadedForReport=reportId;`,
`    const {error:deleteError}=await staleQuery;\n    if(deleteError)throw deleteError;\n    for(const row of snapshot){\n      const {error:otError}=await getSb().rpc('recalculate_timekeeping_employee_week',{p_report_id:reportId,p_employee_id:row.employee_id});\n      if(otError)throw otError;\n    }\n    if(snapshot.length){\n      const {data:recalculated,error:reloadError}=await getSb().from('timekeeping_entries').select('employee_id,regular_hours,overtime_hours').eq('daily_report_id',reportId);\n      if(reloadError)throw reloadError;\n      const byEmployee=new Map((recalculated||[]).map(entry=>[entry.employee_id,entry]));\n      document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>{\n        const employeeId=row.querySelector('.tk-employee')?.value||'';\n        const saved=byEmployee.get(employeeId);\n        if(!saved)return;\n        const regular=row.querySelector('.tk-regular'),ot=row.querySelector('.tk-ot');\n        if(regular)regular.value=number(saved.regular_hours).toFixed(2);\n        if(ot)ot.value=number(saved.overtime_hours).toFixed(2);\n      });\n      syncDailyTotals();\n    }\n    crewRowsLoadedForReport=reportId;`,
'weekly OT persistence hook');
fs.writeFileSync('timekeeping.js',tk);

let html=fs.readFileSync('index.html','utf8');
html=replaceOnce(html,
`<div>\n<label for="companyContactEmail">Company Email</label>`,
`<div>\n<label for="companyWeekStartDay">Workweek Starts On</label>\n<select id="companyWeekStartDay">\n<option value="1">Monday</option>\n<option value="0">Sunday</option>\n<option value="2">Tuesday</option>\n<option value="3">Wednesday</option>\n<option value="4">Thursday</option>\n<option value="5">Friday</option>\n<option value="6">Saturday</option>\n</select>\n<p class="muted" style="font-size:12px;margin-top:5px">Weekly overtime resets on this day. Default: Monday.</p>\n</div>\n<div>\n<label for="companyContactEmail">Company Email</label>`,
'company week-start field');
html=replaceOnce(html,
`$('companyTimezone').value =\ncompany?.timezone || 'America/Chicago';`,
`$('companyTimezone').value =\ncompany?.timezone || 'America/Chicago';\n$('companyWeekStartDay').value = String(Number.isInteger(Number(company?.week_start_day)) ? Number(company.week_start_day) : 1);`,
'company week-start load');
html=replaceOnce(html,
`if(error){\nalert('Unable to save company settings: ' + error.message);\nreturn;\n}\ncurrentCompany = {`,
`if(error){\nalert('Unable to save company settings: ' + error.message);\nreturn;\n}\nconst weekStartDay = Number($('companyWeekStartDay').value || 1);\nconst { error:weekStartError } = await sb.rpc('update_company_week_start', { p_week_start_day:weekStartDay });\nif(weekStartError){\nalert('Company details saved, but the workweek start day could not be saved: ' + weekStartError.message);\nreturn;\n}\ncurrentCompany = {`,
'company week-start save');
html=replaceOnce(html,
`...(Array.isArray(data) ? data[0] : data)\n};`,
`...(Array.isArray(data) ? data[0] : data),\nweek_start_day:weekStartDay\n};`,
'company week-start local state');
fs.writeFileSync('index.html',html);
console.log('Applied weekly OT, configurable workweek, and company settings source changes.');
