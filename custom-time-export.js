/* LineCrew Pro - Custom Time Report export options */
(() => {
  'use strict';

  const byId = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (ch) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const num = (value) => Number(value || 0) || 0;
  const getSb = () => {
    try { return typeof sb !== 'undefined' ? sb : (window.sb || window.supabaseClient || null); }
    catch (_) { return window.sb || window.supabaseClient || null; }
  };
  const profile = () => typeof currentProfile !== 'undefined' ? currentProfile : window.currentProfile;
  const toast = (message, type = 'info') => {
    if (window.LineCrewUI?.toast) window.LineCrewUI.toast(message, type);
    else console.log(message);
  };

  function csvCell(value) {
    let text = String(value ?? '');
    if (typeof value === 'string' && (/^[\t\r\n]/.test(text) || /^\s*[=+\-@]/.test(text))) text = "'" + text;
    return /[",\n]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text;
  }

  function fileName(extension) {
    const from = byId('tkFromDate')?.value || '';
    const through = byId('tkThroughDate')?.value || '';
    return 'linecrew-custom-time-' + from + '-to-' + through + '.' + extension;
  }

  function timeText(value) {
    return value ? String(value).slice(0, 5) : '';
  }

  async function getRows() {
    const client = getSb();
    const current = profile();
    if (!client || !current?.company_id) throw new Error('Timekeeping session is not ready.');

    const from = byId('tkFromDate')?.value;
    const through = byId('tkThroughDate')?.value;
    if (!from || !through) throw new Error('Choose a From and Through date first.');

    const employeeId = byId('tkEmployeeFilter')?.value || null;
    const jobId = byId('tkJobFilter')?.value || null;

    const results = await Promise.all([
      client.rpc('timekeeping_report_rows_v3', {p_from:from, p_through:through, p_employee:employeeId, p_job:jobId}),
      client.from('timekeeping_employees').select('id,employee_number,full_name,classification,default_crew_name,default_equipment').eq('company_id', current.company_id),
      client.from('jobs').select('id,job_number,job_name').eq('company_id', current.company_id)
    ]);

    const reportResult = results[0];
    const employeeResult = results[1];
    const jobResult = results[2];
    if (reportResult.error) throw reportResult.error;
    if (employeeResult.error) throw employeeResult.error;
    if (jobResult.error) throw jobResult.error;

    const employeeMap = new Map((employeeResult.data || []).map((item) => [item.id, item]));
    const jobMap = new Map((jobResult.data || []).map((item) => [item.id, item]));
    const crewFilter = (byId('tkCrewFilter')?.value || '').trim().toLowerCase();

    return (reportResult.data || [])
      .filter((row) => {
        if (!crewFilter) return true;
        const employee = employeeMap.get(row.employee_id) || {};
        return String(row.crew_name || employee.default_crew_name || '').trim().toLowerCase() === crewFilter;
      })
      .map((row) => {
        const employee = employeeMap.get(row.employee_id) || {};
        const job = jobMap.get(row.job_id) || {};
        return {
          'Employee #': employee.employee_number || '',
          'Employee': employee.full_name || '',
          'Classification': employee.classification || '',
          'Date': row.work_date || '',
          'Job #': job.job_number || row.labor_code || '',
          'Job Name': job.job_name || (row.labor_code ? 'Overhead' : ''),
          'Crew': row.crew_name || employee.default_crew_name || '',
          'Start': timeText(row.start_time),
          'Stop': timeText(row.stop_time),
          'Lunch Minutes': num(row.lunch_minutes),
          'Regular Hours': num(row.regular_hours).toFixed(2),
          'OT Hours': num(row.overtime_hours).toFixed(2),
          'Total Hours': (num(row.regular_hours) + num(row.overtime_hours)).toFixed(2),
          'Per Diem': row.per_diem ? 'Yes' : 'No',
          'Equipment': row.equipment_not_used ? 'Not used' : (row.equipment_used || employee.default_equipment || ''),
          'Storm': row.storm_work ? 'Yes' : 'No'
        };
      });
  }

  async function exportExcel() {
    const data = await getRows();
    if (!data.length) throw new Error('No time matches the current filters.');
    if (typeof XLSX === 'undefined') throw new Error('Excel export library is unavailable.');
    const sheet = XLSX.utils.json_to_sheet(data);
    const book = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(book, sheet, 'Custom Time Report');
    XLSX.writeFile(book, fileName('xlsx'));
  }

  async function exportCsv() {
    const data = await getRows();
    if (!data.length) throw new Error('No time matches the current filters.');
    const headers = Object.keys(data[0]);
    const lines = [headers].concat(data.map((row) => headers.map((header) => row[header])));
    const text = lines.map((row) => row.map(csvCell).join(',')).join('\n');
    const blob = new Blob([text], {type:'text/csv;charset=utf-8'});
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = fileName('csv');
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  }

  async function exportPdf() {
    const data = await getRows();
    if (!data.length) throw new Error('No time matches the current filters.');
    const popup = window.open('', '_blank');
    if (!popup) throw new Error('Allow pop-ups to create the PDF/print report.');

    const columns = ['Employee','Date','Job #','Crew','Start','Stop','Regular Hours','OT Hours','Total Hours','Per Diem'];
    const headerHtml = columns.map((column) => '<th>' + esc(column) + '</th>').join('');
    const rowsHtml = data.map((row) => {
      const cells = columns.map((column) => '<td>' + esc(row[column]) + '</td>').join('');
      return '<tr>' + cells + '</tr>';
    }).join('');
    const from = esc(byId('tkFromDate')?.value || '');
    const through = esc(byId('tkThroughDate')?.value || '');

    const html = '<!doctype html><html><head><title>Custom Time Report</title>' +
      '<style>body{font-family:Arial,sans-serif;padding:24px;color:#102235}h2{margin:0 0 4px}p{margin:0 0 14px;color:#617284}table{width:100%;border-collapse:collapse;font-size:10px}th,td{border-bottom:1px solid #dce5ed;padding:5px;text-align:left}th{background:#eef4f8}@media print{body{padding:0}}</style>' +
      '</head><body><h2>LineCrew Pro - Custom Time Report</h2><p>' + from + ' through ' + through + '</p>' +
      '<table><thead><tr>' + headerHtml + '</tr></thead><tbody>' + rowsHtml + '</tbody></table></body></html>';

    popup.document.open();
    popup.document.write(html);
    popup.document.close();
    popup.onload = () => popup.print();
  }

  function install() {
    const oldButton = byId('tkExportCsvBtn');
    if (!oldButton || byId('tkCustomExportWrap')) return false;

    const style = document.createElement('style');
    style.textContent = '.tk-custom-export{position:relative;display:inline-block}.tk-custom-export-menu{position:absolute;left:0;top:calc(100% + 4px);z-index:40;min-width:190px;background:#fff;border:1px solid #dce5ed;border-radius:9px;box-shadow:0 8px 24px rgba(11,45,77,.18);padding:4px}.tk-custom-export-menu.hidden{display:none}.tk-custom-export-menu button{display:block;width:100%!important;text-align:left;margin:0!important;padding:8px 10px!important;background:#fff;color:#102235}.tk-custom-export-menu button:hover{background:#eef4f8}';
    document.head.appendChild(style);

    const wrapper = document.createElement('div');
    wrapper.id = 'tkCustomExportWrap';
    wrapper.className = 'tk-custom-export';
    wrapper.innerHTML = '<button id="tkCustomExportBtn" type="button" class="secondary">Export Current Report ▾</button>' +
      '<div id="tkCustomExportMenu" class="tk-custom-export-menu hidden">' +
      '<button type="button" data-export="excel">Excel (.xlsx)</button>' +
      '<button type="button" data-export="pdf">PDF / Print</button>' +
      '<button type="button" data-export="csv">CSV (.csv)</button></div>';
    oldButton.replaceWith(wrapper);

    const menu = byId('tkCustomExportMenu');
    byId('tkCustomExportBtn').onclick = (event) => {
      event.stopPropagation();
      menu.classList.toggle('hidden');
    };

    menu.querySelectorAll('[data-export]').forEach((button) => {
      button.onclick = async () => {
        menu.classList.add('hidden');
        try {
          if (button.dataset.export === 'excel') await exportExcel();
          else if (button.dataset.export === 'pdf') await exportPdf();
          else await exportCsv();
          toast('Custom Time Report exported.', 'success');
        } catch (error) {
          toast(error.message, 'error');
        }
      };
    });

    document.addEventListener('click', () => menu.classList.add('hidden'));
    return true;
  }

  function boot() {
    if (install()) return;
    const observer = new MutationObserver(() => {
      if (install()) observer.disconnect();
    });
    observer.observe(document.body, {childList:true, subtree:true});
    setTimeout(() => observer.disconnect(), 30000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
