/* LineCrew Pro - retry timekeeping equipment data after profile startup */
(() => {
  'use strict';

  let loadedCompanyId = '';
  let employeeDefaults = new Map();
  let equipment = [];
  let loading = false;

  const getClient = () => {
    try {
      if (typeof sb !== 'undefined' && sb) return sb;
    } catch (_) {}
    return window.sb || window.supabaseClient || null;
  };

  const getProfile = () => {
    try {
      if (typeof currentProfile !== 'undefined' && currentProfile) return currentProfile;
    } catch (_) {}
    return window.currentProfile || null;
  };

  const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[char]));

  function options(selected) {
    return '<option value="">Select truck / equipment</option>' + equipment
      .filter((item) => item.active !== false)
      .map((item) => {
        const label = `${item.unit_number}${item.description ? ' — ' + item.description : ''}`;
        return `<option value="${esc(item.unit_number)}" ${item.unit_number === selected ? 'selected' : ''}>${esc(label)}</option>`;
      })
      .join('');
  }

  function populateRow(row) {
    const employeeId = row.querySelector('.tk-employee')?.value || '';
    const select = row.querySelector('.tk-equipment');
    if (!employeeId || !select || !equipment.length) return;

    const existing = select.value || '';
    const fallback = employeeDefaults.get(employeeId) || '';
    const selected = existing || fallback;
    select.innerHTML = options(selected);
    select.value = selected;
  }

  function populateRows() {
    document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(populateRow);
  }

  async function loadData() {
    const client = getClient();
    const profile = getProfile();
    const companyId = profile?.company_id || '';
    if (!client || !companyId || loading) return;
    if (loadedCompanyId === companyId && equipment.length) {
      populateRows();
      return;
    }

    loading = true;
    try {
      const [employeesResult, equipmentResult] = await Promise.all([
        client.from('timekeeping_employees')
          .select('id,default_equipment,active')
          .eq('company_id', companyId),
        client.from('timekeeping_equipment')
          .select('unit_number,description,active')
          .eq('company_id', companyId)
          .order('unit_number')
      ]);

      if (employeesResult.error || equipmentResult.error) return;
      employeeDefaults = new Map((employeesResult.data || [])
        .filter((employee) => employee.active !== false)
        .map((employee) => [employee.id, employee.default_equipment || '']));
      equipment = equipmentResult.data || [];
      loadedCompanyId = companyId;
      populateRows();
    } finally {
      loading = false;
    }
  }

  function start() {
    loadData();
    const observer = new MutationObserver(() => {
      if (loadedCompanyId && equipment.length) populateRows();
      else loadData();
    });
    observer.observe(document.body, { childList: true, subtree: true });
    setInterval(loadData, 500);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
