import fs from 'node:fs';

function patch(path, replacements){
  let text=fs.readFileSync(path,'utf8');
  for(const [from,to,label] of replacements){
    if(!text.includes(from)) throw new Error(`Missing ${label} in ${path}`);
    text=text.replace(from,to);
  }
  fs.writeFileSync(path,text);
}

patch('timekeeping.js',[
  [
`      const regular_hours=number(row.querySelector('.tk-regular')?.value);
      const overtime_hours=number(row.querySelector('.tk-ot')?.value);
      if(regular_hours<0||overtime_hours<0||regular_hours+overtime_hours>24)return;
      rows.push({employee_id,regular_hours,overtime_hours});`,
`      const regular_hours=number(row.querySelector('.tk-regular')?.value);
      const overtime_hours=number(row.querySelector('.tk-ot')?.value);
      if(regular_hours<0||overtime_hours<0||regular_hours+overtime_hours>24)return;
      const perDiemInput=row.querySelector('.tk-per-diem');
      const equipmentNotUsed=!!row.querySelector('.tk-equipment-not-used')?.checked;
      rows.push({
        employee_id,
        regular_hours,
        overtime_hours,
        start_time:row.querySelector('.tk-start')?.value||null,
        stop_time:row.querySelector('.tk-stop')?.value||null,
        lunch_minutes:Math.max(0,Math.min(720,Math.round(number(row.querySelector('.tk-lunch')?.value)))),
        per_diem:perDiemInput?!!perDiemInput.checked:true,
        equipment_used:equipmentNotUsed?null:(row.querySelector('.tk-equipment')?.value||null),
        equipment_not_used:equipmentNotUsed
      });`,
    'crew row detail collection'
  ],
  [
`    const rows=snapshot.map(r=>({company_id:companyId(),employee_id:r.employee_id,daily_report_id:reportId,job_id:jobId,work_date:workDate,crew_name:crewName,regular_hours:r.regular_hours,overtime_hours:r.overtime_hours,storm_work:stormWork,created_by:user.id,updated_by:user.id,updated_at:new Date().toISOString()}));`,
`    const rows=snapshot.map(r=>({company_id:companyId(),employee_id:r.employee_id,daily_report_id:reportId,job_id:jobId,work_date:workDate,crew_name:crewName,regular_hours:r.regular_hours,overtime_hours:r.overtime_hours,storm_work:stormWork,start_time:r.start_time||null,stop_time:r.stop_time||null,lunch_minutes:r.lunch_minutes||0,per_diem:r.per_diem===true,equipment_used:r.equipment_not_used?null:(r.equipment_used||null),equipment_not_used:r.equipment_not_used===true,created_by:user.id,updated_by:user.id,updated_at:new Date().toISOString()}));`,
    'timekeeping source upsert detail columns'
  ],
  [
`  window.saveDailyReportCrewTime=async(reportId)=>{
    syncDailyTotals();
    await persistCrewTime(collectCrewRows(),reportId);
  };`,
`  window.LineCrewCoreSavesTimekeepingDetails=true;
  window.saveDailyReportCrewTime=async(reportId)=>{
    syncDailyTotals();
    await persistCrewTime(collectCrewRows(),reportId);
  };`,
    'core timekeeping detail marker'
  ]
]);

patch('timekeeping-input-v2.js',[[
`  function installSaveWrapper(){const current=window.saveDailyReportCrewTime;if(typeof current!=='function'||current===wrappedSave||current.__lcLaunchWrapped)return;`,
`  function installSaveWrapper(){if(window.LineCrewCoreSavesTimekeepingDetails)return;const current=window.saveDailyReportCrewTime;if(typeof current!=='function'||current===wrappedSave||current.__lcLaunchWrapped)return;`,
  'legacy detail wrapper guard'
]]);
