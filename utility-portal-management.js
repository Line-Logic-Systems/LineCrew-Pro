(function () {
  'use strict';

  const state = {
    contracts: [],
    organizations: [],
    selectedOrganization: null,
    grants: [],
    viewer: null
  };

  const byId = id => document.getElementById(id);
  const clean = value => String(value ?? '').trim();
  const html = value => clean(value)
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;').replaceAll("'", '&#039;');
  const dateText = value => value ? new Date(value).toLocaleString() : '—';
  const buttonBusy = (button, busy, label) => {
    if (!button) return;
    if (busy) button.dataset.normalLabel = button.textContent;
    button.disabled = busy;
    button.textContent = busy ? label : (button.dataset.normalLabel || button.textContent);
  };
  const rpc = async (name, args) => {
    const result = await sb.rpc(name, args || {});
    if (result.error) throw result.error;
    return result.data;
  };
  const neutralMessage = error => {
    const message = clean(error?.message);
    if (error?.code === '42501' || /not available|access denied/i.test(message)) {
      return 'Utility Portal is not enabled for this company yet.';
    }
    return message || 'The request could not be completed.';
  };

  function contractLabel(contract) {
    const customer = contract.customers?.name ? contract.customers.name + ' — ' : '';
    const number = contract.contract_number ? ' (' + contract.contract_number + ')' : '';
    return customer + contract.contract_name + number;
  }

  function contractChoices(host, contracts, prefix) {
    host.replaceChildren();
    if (!contracts.length) {
      host.innerHTML = '<p class="muted">No eligible active contracts are available.</p>';
      return;
    }
    contracts.forEach(contract => {
      const row = document.createElement('div');
      row.className = 'job-card';
      row.innerHTML = '<label class="checkbox-row"><input type="checkbox" data-utility-contract="' +
        html(contract.id) + '"><span><strong>' + html(contractLabel(contract)) +
        '</strong></span></label><label class="checkbox-row"><input type="checkbox" data-utility-quantities="' +
        html(contract.id) + '"><span>Allow quantity details</span></label>';
      row.dataset.utilityChoiceGroup = prefix;
      host.appendChild(row);
    });
  }

  function selectedContracts(host) {
    return Array.from(host.querySelectorAll('[data-utility-contract]:checked')).map(input => ({
      id: input.dataset.utilityContract,
      showQuantities: host.querySelector('[data-utility-quantities="' + input.dataset.utilityContract + '"]')?.checked === true
    }));
  }

  async function loadContracts() {
    const { data, error } = await sb.from('contracts')
      .select('id,contract_name,contract_number,active,customers(name)')
      .eq('company_id', currentProfile.company_id)
      .order('contract_name');
    if (error) throw error;
    state.contracts = data || [];
    contractChoices(byId('utilityCreateContractChoices'), state.contracts.filter(contract => contract.active), 'create');
  }

  function renderOrganizations() {
    const host = byId('utilityOrganizationList');
    host.replaceChildren();
    if (!state.organizations.length) {
      host.innerHTML = '<p class="muted">No utility organizations have been created yet.</p>';
      return;
    }
    state.organizations.forEach(org => {
      const card = document.createElement('div');
      card.className = 'job-card';
      card.innerHTML = '<div class="section-header"><div><strong>' + html(org.organization_name) +
        '</strong><p class="muted">' + Number(org.active_grant_count || 0) + ' active of ' +
        Number(org.total_grant_count || 0) + ' total contract grants · ' +
        Number(org.active_representative_count || 0) + ' active representatives · ' +
        Number(org.invited_representative_count || 0) + ' pending</p></div></div>';
      const open = document.createElement('button');
      open.className = 'secondary small';
      open.textContent = 'Manage Access';
      open.onclick = () => openOrganization(org);
      card.appendChild(open);
      host.appendChild(card);
    });
  }

  async function loadManagement() {
    if (!currentProfile || !userIsCompanyAdmin()) {
      await returnToDashboard();
      return;
    }
    byId('utilityPortalStatus').textContent = 'Checking access…';
    byId('utilityPortalUnavailable').classList.add('hidden');
    byId('utilityPortalWorkspace').classList.add('hidden');
    try {
      const [organizations, unassigned] = await Promise.all([
        rpc('utility_list_organizations', { p_include_inactive: false }),
        rpc('utility_unassigned_job_count')
      ]);
      state.organizations = organizations || [];
      await loadContracts();
      renderOrganizations();
      const count = Number(unassigned?.[0]?.unassigned_count || 0);
      const warning = byId('utilityUnassignedJobs');
      warning.classList.toggle('hidden', count === 0);
      warning.textContent = count === 1
        ? '1 job is not assigned to a contract and cannot be shared.'
        : count + ' jobs are not assigned to contracts and cannot be shared.';
      byId('utilityPortalWorkspace').classList.remove('hidden');
      byId('utilityPortalStatus').textContent = 'Enabled';
    } catch (error) {
      byId('utilityPortalUnavailable').classList.remove('hidden');
      byId('utilityPortalStatus').textContent = 'Unavailable';
      byId('utilityPortalUnavailable').querySelector('p').textContent = neutralMessage(error);
    }
  }

  async function createOrganization() {
    const name = clean(byId('utilityOrganizationName').value);
    const selected = selectedContracts(byId('utilityCreateContractChoices'));
    if (name.length < 2) return alert('Enter the utility or cooperative name.');
    if (!selected.length) return alert('Choose at least one contract to share.');
    const button = byId('createUtilityOrganization');
    buttonBusy(button, true, 'Creating…');
    try {
      await rpc('utility_create_organization_with_grants', {
        p_name: name,
        p_contract_ids: selected.map(item => item.id),
        p_show_quantities: selected.map(item => item.showQuantities)
      });
      byId('utilityOrganizationName').value = '';
      await loadManagement();
    } catch (error) {
      alert(neutralMessage(error));
    } finally {
      buttonBusy(button, false);
    }
  }

  async function openOrganization(org) {
    state.selectedOrganization = org;
    byId('utilityDetailName').textContent = org.organization_name;
    byId('utilityDetailSummary').textContent = 'Only contracts explicitly listed below are shared.';
    byId('utilityOrganizationDetail').classList.remove('hidden');
    await refreshOrganizationDetail();
    byId('utilityOrganizationDetail').scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  async function refreshOrganizationDetail() {
    const org = state.selectedOrganization;
    if (!org) return;
    try {
      const [representatives, grants, activity] = await Promise.all([
        rpc('utility_list_representatives', { p_utility_organization_id: org.organization_id }),
        rpc('utility_contract_visibility_state', { p_utility_organization_id: org.organization_id, p_contract_id: null }),
        rpc('utility_activity_feed', { p_before_created_at: null, p_before_id: null, p_limit: 50 })
      ]);
      state.grants = grants || [];
      renderRepresentatives(representatives || []);
      renderGrants();
      renderActivity(activity || []);
    } catch (error) {
      alert(neutralMessage(error));
    }
  }

  function renderRepresentatives(rows) {
    const host = byId('utilityRepresentativeList');
    host.replaceChildren();
    if (!rows.length) {
      host.innerHTML = '<p class="muted">No representatives have been invited.</p>';
      return;
    }
    rows.forEach(rep => {
      const card = document.createElement('div');
      card.className = 'job-card';
      card.innerHTML = '<strong>' + html(rep.full_name || rep.email) + '</strong><br><span class="muted">' +
        html(rep.email) + ' · ' + html(rep.status) +
        (rep.status === 'invited' ? ' · expires ' + html(dateText(rep.invite_expires_at)) : '') + '</span>';
      if (rep.status === 'invited' && rep.invited_by_this_company) {
        const actions = document.createElement('div');
        actions.className = 'button-row';
        const resend = document.createElement('button');
        resend.className = 'secondary small'; resend.textContent = 'Resend Invitation';
        resend.onclick = () => sendInvitation(rep);
        const cancel = document.createElement('button');
        cancel.className = 'danger small'; cancel.textContent = 'Cancel Invitation';
        cancel.onclick = () => cancelInvitation(rep);
        actions.append(resend, cancel); card.appendChild(actions);
      }
      host.appendChild(card);
    });
  }

  async function sendInvitation(existing) {
    const org = state.selectedOrganization;
    const email = clean(existing?.email || byId('utilityInviteEmail').value).toLowerCase();
    const fullName = clean(existing?.full_name || byId('utilityInviteName').value);
    if (!/^\S+@\S+\.\S+$/.test(email)) return alert('Enter a valid representative email.');
    const button = byId('sendUtilityInvitation');
    buttonBusy(button, true, existing ? 'Resending…' : 'Sending…');
    try {
      const result = await sb.functions.invoke('send-utility-invitation', {
        body: { organizationId: org.organization_id, email, fullName }
      });
      if (result.error) throw result.error;
      byId('utilityInviteEmail').value = '';
      byId('utilityInviteName').value = '';
      await refreshOrganizationDetail();
      alert(existing ? 'A new invitation link was sent. The previous link is no longer valid.' : 'Invitation sent.');
    } catch (error) {
      alert(neutralMessage(error));
    } finally {
      buttonBusy(button, false);
    }
  }

  async function cancelInvitation(rep) {
    if (!confirm('Cancel this pending invitation? The email can be invited again later.')) return;
    try {
      await rpc('utility_cancel_invitation', { p_utility_user_id: rep.representative_id });
      await refreshOrganizationDetail();
    } catch (error) { alert(neutralMessage(error)); }
  }

  function hiddenReasonLabel(reason) {
    return ({
      contract_inactive: 'contract inactive', contract_not_started: 'contract not started',
      contract_ended: 'contract ended', grant_expired: 'grant expired', grant_revoked: 'access revoked',
      company_flag_disabled: 'company rollout disabled', global_flag_disabled: 'global rollout disabled',
      entitlement_inactive: 'company subscription inactive'
    })[reason] || 'not visible';
  }

  function renderGrants() {
    const host = byId('utilityGrantList');
    host.replaceChildren();
    const currentGrantContractIds = new Set(state.grants
      .filter(grant => !grant.hidden_reasons?.includes('grant_revoked'))
      .map(grant => grant.contract_id));
    state.grants.forEach(grant => {
      const contract = state.contracts.find(item => item.id === grant.contract_id);
      const card = document.createElement('div');
      card.className = 'job-card';
      const reasons = (grant.hidden_reasons || []).map(hiddenReasonLabel).join(', ');
      card.innerHTML = '<strong>' + html(contract ? contractLabel(contract) : 'Contract') +
        '</strong><br><span class="muted">' + (grant.is_visible ? 'Visible now' : html(reasons || 'Not visible')) +
        ' · Quantities ' + (grant.show_quantities ? 'shown' : 'hidden') + '</span>';
      const grantExpired = (grant.hidden_reasons || []).includes('grant_expired');
      const grantRevoked = (grant.hidden_reasons || []).includes('grant_revoked');
      if (!grantRevoked) {
        const actions = document.createElement('div'); actions.className = 'button-row';
        const revoke = document.createElement('button'); revoke.className = 'danger small'; revoke.textContent = 'Stop Sharing';
        revoke.onclick = () => revokeGrant(grant);
        if (grantExpired) {
          revoke.textContent = 'Close Expired Grant';
          actions.append(revoke);
        } else {
          const toggle = document.createElement('button'); toggle.className = 'secondary small';
          toggle.textContent = grant.show_quantities ? 'Hide Quantities' : 'Show Quantities';
          toggle.onclick = () => updateQuantities(grant, !grant.show_quantities);
          actions.append(toggle, revoke);
        }
        card.appendChild(actions);
      }
      host.appendChild(card);
    });
    const eligible = state.contracts.filter(contract => contract.active && !currentGrantContractIds.has(contract.id));
    contractChoices(byId('utilityAddContractChoices'), eligible, 'add');
  }

  async function updateQuantities(grant, show) {
    try {
      await rpc('utility_set_grant_show_quantities', { p_grant_id: grant.grant_id, p_show_quantities: show });
      await refreshOrganizationDetail();
    } catch (error) { alert(neutralMessage(error)); }
  }

  async function revokeGrant(grant) {
    const expired = (grant.hidden_reasons || []).includes('grant_expired');
    const prompt = expired
      ? 'Close this expired grant? You can create a replacement afterward.'
      : 'Stop sharing this contract? The utility will immediately lose access to its jobs.';
    if (!confirm(prompt)) return;
    try {
      await rpc('utility_revoke_contract_grant', { p_grant_id: grant.grant_id });
      await loadManagement();
      if (state.selectedOrganization) await refreshOrganizationDetail();
    } catch (error) { alert(neutralMessage(error)); }
  }

  async function addGrants() {
    const selected = selectedContracts(byId('utilityAddContractChoices'));
    if (!selected.length) return alert('Choose at least one contract.');
    try {
      await rpc('utility_add_contract_grants', {
        p_organization_id: state.selectedOrganization.organization_id,
        p_contract_ids: selected.map(item => item.id),
        p_show_quantities: selected.map(item => item.showQuantities)
      });
      await loadManagement();
      await refreshOrganizationDetail();
    } catch (error) { alert(neutralMessage(error)); }
  }

  function renderActivity(rows) {
    const host = byId('utilityActivityList');
    host.replaceChildren();
    if (!rows.length) { host.innerHTML = '<p class="muted">No activity recorded yet.</p>'; return; }
    rows.forEach(item => {
      const row = document.createElement('div'); row.className = 'job-info';
      row.innerHTML = '<strong>' + html(clean(item.action).replaceAll('_', ' ')) + '</strong> · ' +
        html(dateText(item.occurred_at)) + '<br><span class="muted">' +
        html([item.organization_name, item.actor_name, item.contract_name, item.job_number].filter(Boolean).join(' · ')) + '</span>';
      host.appendChild(row);
    });
  }

  function applyUtilityInvitationMode(active) {
    let name = byId('utilitySignupName');
    if (!name) {
      const label = document.createElement('label'); label.id = 'utilitySignupNameLabel'; label.textContent = 'Full Name';
      name = document.createElement('input'); name.id = 'utilitySignupName'; name.maxLength = 120; name.autocomplete = 'name';
      byId('signupCard').insertBefore(label, byId('signupEmail').previousElementSibling);
      byId('signupCard').insertBefore(name, byId('signupEmail').previousElementSibling);
    }
    byId('utilitySignupNameLabel').classList.toggle('hidden', !active);
    name.classList.toggle('hidden', !active);
  }

  async function completeInvitation(values) {
    const fullName = clean(byId('utilitySignupName')?.value);
    if (pendingInviteEmail && values.email.toLowerCase() !== pendingInviteEmail.toLowerCase()) return alert('Use the email address that received this invitation.');
    if (fullName.length < 2) return alert('Enter your full name.');
    if (values.password.length < 8) return alert('Use a password with at least 8 characters.');
    if (values.password !== values.passwordConfirmation) return alert('The passwords do not match.');
    const button = byId('signupBtn');
    buttonBusy(button, true, 'Creating Utility Account…');
    try {
      const result = await sb.functions.invoke('complete-utility-invitation-signup', {
        body: { email: values.email, password: values.password, fullName, token: pendingUtilityInviteToken }
      });
      if (result.error) throw result.error;
      const signedIn = await sb.auth.signInWithPassword({ email: values.email, password: values.password });
      if (signedIn.error) throw signedIn.error;
      pendingUtilityInviteToken = '';
      pendingInviteEmail = '';
      const url = new URL(location.href); url.searchParams.delete('utilityInvite'); url.searchParams.delete('email');
      history.replaceState(null, '', url.toString());
      await loadApp();
    } catch (error) {
      alert('Unable to create the Utility Portal account. Request a new invitation and try again.');
    } finally { buttonBusy(button, false); }
  }

  async function tryLoadViewer() {
    try {
      const me = await rpc('utility_me');
      if (!me?.length) return false;
      state.viewer = me[0];
      byId('utilityViewerOrganization').textContent = me[0].organization_name || 'Utility Portal';
      show('utilityViewerPage');
      await loadViewerJobs();
      return true;
    } catch (_) { return false; }
  }

  async function loadViewerJobs() {
    const host = byId('utilityViewerJobs');
    host.innerHTML = '<p class="muted">Loading shared jobs…</p>';
    try {
      const jobs = await rpc('utility_list_jobs');
      host.replaceChildren();
      const heading = document.createElement('h3'); heading.textContent = 'Shared Jobs'; host.appendChild(heading);
      if (!jobs?.length) { host.insertAdjacentHTML('beforeend', '<p class="muted">No active jobs are currently shared.</p>'); return; }
      jobs.forEach(job => {
        const card = document.createElement('div'); card.className = 'job-card';
        card.innerHTML = '<strong>' + html(job.job_number) + ' — ' + html(job.job_name) +
          '</strong><p class="muted">' + html(job.contractor_company_name) + ' · ' + html(job.contract_name) +
          ' · ' + Number(job.overall_approved_percent || 0).toFixed(1) + '% approved</p>';
        const open = document.createElement('button'); open.className = 'secondary small'; open.textContent = 'View Progress';
        open.onclick = () => openViewerJob(job); card.appendChild(open); host.appendChild(card);
      });
    } catch (error) { host.innerHTML = '<p class="muted">' + html(neutralMessage(error)) + '</p>'; }
  }

  async function openViewerJob(job) {
    const host = byId('utilityViewerJobDetail');
    host.classList.remove('hidden');
    host.innerHTML = '<h3>' + html(job.job_number) + ' — ' + html(job.job_name) + '</h3><p class="muted">Loading progress…</p>';
    try {
      const rows = await rpc('utility_get_job_progress', { p_job_id: job.job_id });
      const body = (rows || []).map(row => '<tr><td>' + html(row.work_point_code) + '</td><td>' +
        html(row.unit_code) + '</td><td>' + Number(row.percent_complete || 0).toFixed(1) + '%</td><td>' +
        (row.authorized_install_quantity == null ? 'Hidden' : html(row.approved_install_quantity) + ' / ' + html(row.authorized_install_quantity)) +
        '</td><td>' +
        (row.authorized_retirement_quantity == null ? 'Hidden' : html(row.approved_retirement_quantity) + ' / ' + html(row.authorized_retirement_quantity)) +
        '</td></tr>').join('');
      host.innerHTML = '<div class="section-header"><div><h3>' + html(job.job_number) + ' — ' + html(job.job_name) +
        '</h3><p class="muted">Approved production only</p></div><button id="closeUtilityViewerJob" class="secondary small">Close</button></div>' +
        '<div style="overflow-x:auto"><table><thead><tr><th>Work Point</th><th>Unit</th><th>Complete</th><th>Installed Qty</th><th>Retired Qty</th></tr></thead><tbody>' +
        (body || '<tr><td colspan="5">No approved production yet.</td></tr>') + '</tbody></table></div>';
      byId('closeUtilityViewerJob').onclick = () => host.classList.add('hidden');
      host.scrollIntoView({ behavior: 'smooth', block: 'start' });
    } catch (error) { host.innerHTML = '<p class="muted">' + html(neutralMessage(error)) + '</p>'; }
  }

  function bind() {
    byId('utilityPortalTile').onclick = () => navigateToAppPage('utilityPortalPage');
    byId('backFromUtilityPortal').onclick = () => returnToDashboard();
    byId('refreshUtilityPortal').onclick = loadManagement;
    byId('createUtilityOrganization').onclick = createOrganization;
    byId('closeUtilityDetail').onclick = () => byId('utilityOrganizationDetail').classList.add('hidden');
    byId('sendUtilityInvitation').onclick = () => sendInvitation(null);
    byId('addUtilityGrants').onclick = addGrants;
    byId('utilityViewerSignOut').onclick = signOut;
    applyUtilityInvitationMode(Boolean(pendingUtilityInviteToken));
  }

  window.LineCrewUtilityPortal = {
    loadManagement,
    tryLoadViewer,
    completeInvitation,
    applyInvitationMode: applyUtilityInvitationMode
  };
  bind();
})();
