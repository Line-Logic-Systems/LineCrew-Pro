/* LineCrew Pro - Custom Time Report export options */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num=v=>Number(v||0)||0;
  const getSb=()=>{try{return typeof sb!=='undefined'?sb:(window.sb||window.supabaseClient||null);}catch(_){return window.sb||window.supabaseClient||null;}};
  const profile=()=>typeof currentProfile!=='undefined'?currentProfile:window.currentProfile;
  const toast=(m,t='info')=>window.LineCrewUI?.toast?.(m,t)||console.log(m);

  function csvCell(value){let s=String(value??'');if(typeof value==='string'&&(/^[\t\r\n]/.test(s)||/^\s*[=+\-@]/.test(s)))s="'"+s;return /[",\n]/.test(s)?'"'+s.replace(/"/g,'""')+'"':s;}
  function filename(ext){return `linecrew-custom-time-${byId('tkFromDate')?.value||''}-to-${byId('tkThroughDate')?.value||''}.${ext}`;}
  function timeText(v){return v?String(v).slice(0,5):'';}

  async function getRows(){
    const client=getSb(),p=profile();if(!client||!p?.company_id)throw new Error('Timekeeping session is not ready.');
    const from=byId('tkFromDate')?.value,through=byId('tkThroughDate')?.value;
    if(!from||!through)throw new Error('Choose a From and Through date first.');
    const emp=byId('tkEmployeeFilter')?.value||null,job=byId('tkJobFilter')?.value||null;
    const [{data,error},{data:emps,error:ee},{data:jobs,error:je}]=await Promise.all([
      client.rpc('timekeeping_report_rows_v2',{p_from:from,p_through:through,p_employee:emp,p_job:job}),
      client.from('timekeeping_employees').select('id,employee_number,full_name,classification,default_crew_name,default_equipment').eq('company_id',p.company_id),
      client.from('jobs').select('id,job_number,job_name').eq('company_id',p.company_id)
    ]);
    if(error)throw error;if(ee)throw ee;if(je)throw je;
    const em=new Map((emps||[]).map(x=>[x.id,x])),jm=new Map((jobs||[]).map(x=>[x.id,x]));
    const crew=(byId('tkCrewFilter')?.value||'').trim().toLowerCase();
    return (data||[]).filter(r=>!crew||String(r.crew_name||em.get(r.employee_id)?.default_crew_name||'').trim().toLowerCase()===crew).map(r=>{
      const e=em.get(r.employee_id)||{},j=jm.get(r.job_id)||{};
      return {'Employee #':e.employee_number||'','Employee':e.full_name||'','Classification':e.classification||'','Date':r.work_date||'','Job #':j.job_number||'','Job Name':j.job_name||'','Crew':r.crew_name||e.default_crew_name||'','Start':timeText(r.start_time),'Stop':timeText(r.stop_time),'Lunch Minutes':num(r.lunch_minutes),'Regular Hours':num(r.regular_hours).toFixed(2),'OT Hours':num(r.overtime_hours).toFixed(2),'Total Hours':(num(r.regular_hours)+num(r.overtime_hours)).toFixed(2),'Per Diem':r.per_diem?'Yes':'No','Equipment':r.equipment_not_used?'Not used':(r.equipment_used||e.default_equipment||''),'Storm':r.storm_work?'Yes':'No'};
    });
  }

  async function exportExcel(){const data=await getRows();if(!data.length)throw new Error('No time matches the current filters.');if(typeof XLSX==='undefined')throw new Error('Excel export library is unavailable.');const ws=XLSX.utils.json_to_sheet(data),wb=XLSX.utils.book_new();XLSX.utils.book_append_sheet(wb,ws,'Custom Time Report');XLSX.writeFile(wb,filename('xlsx'));}
  async function exportCsv(){const data=await getRows();if(!data.length)throw new Error('No time matches the current filters.');const headers=Object.keys(data[0]),text=[headers,...data.map(r=>headers.map(h=>r[h]))].map(row=>row.map(csvCell).join(',')).join('\n');const blob=new Blob([text],{type:'text/csv;charset=utf-8'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=filename('csv');document.body.appendChild(a);a.click();a.remove();URL.revokeObjectURL(url);}
  async function exportPdf(){const data=await getRows();if(!data.length)throw new Error('No time matches the current filters.');const win=window.open('','_blank');if(!win)throw new Error('Allow pop-ups to create the PDF/print report.');const cols=['Employee','Date','Job #','Crew','Start','Stop','Regular Hours','OT Hours','Total Hours','Per Diem'];const from=byId('tkFromDate')?.value||'',through=byId('tkThroughDate')?.value||'';win.document.write(`<html><head><title>Custom Time Report</title><style>body{font-family:Arial,sans-serif;padding:24px;color:#102235}h2{margin:0 0 4px}p{margin:0 0 14px;color:#617284}table{width:100%;border-collapse:collapse;font-size:10px}th,td{border-bottom:1px solid #dce5ed;padding:5px;text-align:left}th{background:#eef4f8}@media print{body{padding:0}}</style></head><body><h2>LineCrew Pro — Custom Time Report</h2><p>${esc(from)} through ${esc(through)}</p><table><thead><tr>${cols.map(c=>`<th>${esc(c)}</th>`).join('')}</tr></thead><tbody>${data.map(row=>`<tr>${cols.map(c=>`<td>${esc(row[c])}</td>`).join('')}</tr>`).join('')}</tbody></table><script>window.onload=()=>window.print()<\/script></body></html>`);win.document.close();}

  function install(){
    const old=byId('tkExportCsvBtn');if(!old||byId('tkCustomExportWrap'))return false;
    const style=document.createElement('style');style.textContent='.tk-custom-export{position:relative;display:inline-block}.tk-custom-export-menu{position:absolute;left:0;top:calc(100% + 4px);z-index:40;min-width:190px;background:#fff;border:1px solid #dce5ed;border-radius:9px;box-shadow:0 8px 24px rgba(11,45,77,.18);padding:4px}.tk-custom-export-menu.hidden{display:none}.tk-custom-export-menu button{display:block;width:100%!important;text-align:left;margin:0!important;padding:8px 10px!important;background:#fff;color:#102235}.tk-custom-export-menu button:hover{background:#eef4f8}';document.head.appendChild(style);
    const wrap=document.createElement('div');wrap.id='tkCustomExportWrap';wrap.className='tk-custom-export';wrap.innerHTML='<button id="tkCustomExportBtn" type="button" class="secondary">Export Current Report ▾</button><div id="tkCustomExportMenu" class="tk-custom-export-menu hidden"><button type="button" data-export="excel">Excel (.xlsx)</button><button type="button" data-export="pdf">PDF / Print</button><button type="button" data-export="csv">CSV (.csv)</button></div>';old.replaceWith(wrap);
    const menu=byId('tkCustomExportMenu');byId('tkCustomExportBtn').onclick=e=>{e.stopPropagation();menu.classList.toggle('hidden')};menu.querySelectorAll('[data-export]').forEach(btn=>btn.onclick=async()=>{menu.classList.add('hidden');try{if(btn.dataset.export==='excel')await exportExcel();else if(btn.dataset.export==='pdf')await exportPdf();else await exportCsv();toast('Custom Time Report exported.','success');}catch(err){toast(err.message,'error');}});document.addEventListener('click',()=>menu.classList.add('hidden'));return true;
  }
  function boot(){if(install())return;const obs=new MutationObserver(()=>{if(install())obs.disconnect()});obs.observe(document.body,{childList:true,subtree:true});setTimeout(()=>obs.disconnect(),30000);}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot);else boot();
})();