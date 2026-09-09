(function(){
  'use strict';
  const byId=id=>document.getElementById(id);
  const esc=value=>String(value??'').replace(/[&<>'"]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[ch]));
  const value=id=>(byId(id)?.value||'').trim();
  const nullable=id=>value(id)||null;
  const dateLabel=iso=>iso?new Date(iso+'T12:00:00').toLocaleDateString():'Not set';
  const statusLabel=status=>({assigned:'Assigned',mobilizing:'Mobilizing',onsite:'On Site',standby:'Standby',released:'Released'})[status]||'Assigned';
  let workspace=null;
  let unavailable=false;
  let referenceCustomers=[];
  let referenceContracts=[];

  function catalog(name){
    if(name==='customers') return referenceCustomers.length?referenceCustomers:(typeof currentCustomerCatalog!=='undefined'&&Array.isArray(currentCustomerCatalog)?currentCustomerCatalog:[]);
    return referenceContracts.length?referenceContracts:(typeof currentContractCatalog!=='undefined'&&Array.isArray(currentContractCatalog)?currentContractCatalog:[]);
  }
  function fillSelect(select,items,label,selected){
    if(!select)return;
    select.innerHTML='<option value="">Not selected</option>';
    items.filter(item=>item.active!==false).forEach(item=>{
      const option=document.createElement('option');option.value=item.id;option.textContent=label(item);select.appendChild(option);
    });
    if(selected&&items.some(item=>String(item.id)===String(selected)))select.value=selected;
  }
  function populateReferences(active,preferCurrent=false){
    const customers=catalog('customers'),customerId=(preferCurrent?value('stormEventCustomer'):active?.customer_id)||value('stormEventCustomer');
    fillSelect(byId('stormEventCustomer'),customers,item=>item.name||'Unnamed utility',customerId);
    const contracts=catalog('contracts').filter(item=>!customerId||String(item.customer_id)===String(customerId));
    fillSelect(byId('stormEventContract'),contracts,item=>[item.contract_number,item.contract_name].filter(Boolean).join(' — ')||'Unnamed contract',active?.contract_id||value('stormEventContract'));
  }
  function setForm(active){
    populateReferences(active);
    if(!active)return;
    const values={stormEventLocation:active.location,stormEventStartDate:active.start_date,stormEventExpectedEndDate:active.expected_end_date,
      stormEventTimePolicy:active.time_policy||'record_only',stormEventPerDiemPolicy:active.per_diem_policy||'manual',
      stormEventPerDiemAmount:active.default_per_diem_amount,stormEventOperationsNotes:active.operations_notes};
    Object.entries(values).forEach(([id,next])=>{if(byId(id))byId(id).value=next??'';});
  }
  function renderHistory(history){
    const box=byId('stormEventHistory');if(!box)return;
    box.innerHTML=(history||[]).length?(history||[]).map(item=>`<div class="storm-history-row"><span><strong>${esc(item.event_name)}</strong><br><span class="muted">${esc(item.location||'No location')}</span></span><span>${esc(dateLabel(item.start_date))} · ${esc(item.status)}</span></div>`).join(''):'<p class="muted">No past storm events yet.</p>';
  }
  function crewCard(crew,editable){
    const checked=crew.has_report_today?'<span class="storm-status-onsite">Report entered today</span>':'<span>Daily report missing</span>';
    const controls=editable?`<div class="button-row"><select data-storm-status="${esc(crew.user_id)}">${['assigned','mobilizing','onsite','standby','released'].map(s=>`<option value="${s}" ${crew.deployment_status===s?'selected':''}>${statusLabel(s)}</option>`).join('')}</select><button class="secondary small" type="button" data-storm-update="${esc(crew.user_id)}">Update</button></div>`:'';
    return `<div class="storm-readiness-card"><div class="section-header"><div><strong>${esc(crew.full_name||'Unnamed crew leader')}</strong><div class="muted">${esc(crew.role||'Crew leader')}</div></div><span class="status storm-status-${esc(crew.deployment_status)}">${esc(statusLabel(crew.deployment_status))}</span></div><div class="storm-readiness-meta">${checked}${crew.current_location?`<span>${esc(crew.current_location)}</span>`:''}${crew.last_check_in_at?`<span>Checked in ${esc(new Date(crew.last_check_in_at).toLocaleString())}</span>`:''}</div>${crew.readiness_notes?`<p>${esc(crew.readiness_notes)}</p>`:''}${controls}</div>`;
  }
  function canManage(){return typeof userCanManageStormMode==='function'&&userCanManageStormMode();}
  function render(){
    const event=workspace?.active_event,crews=workspace?.crews||[],today=workspace?.today||{};
    window.LineCrewActiveStormEventId=event?.id||null;
    const command=byId('stormCommandCenter');if(command)command.classList.toggle('hidden',!event);
    if(event){
      byId('stormTodayMetrics').innerHTML=`<span><strong>${Number(today.reports||0)}</strong><br>Reports Today</span><span><strong>${Number(today.submitted||0)}</strong><br>Submitted</span><span><strong>${Number(today.approved||0)}</strong><br>Approved</span><span><strong>${Number(today.regular_hours||0)}</strong><br>Regular Hours</span><span><strong>${Number(today.overtime_hours||0)}</strong><br>OT Hours</span>`;
      const missing=crews.filter(c=>c.deployment_status!=='released'&&!c.has_report_today);
      byId('stormReadinessAlerts').innerHTML=missing.length?`<div class="storm-alert"><strong>${missing.length} crew${missing.length===1?'':'s'} without a Daily Report today</strong><div>${missing.map(c=>esc(c.full_name)).join(', ')}</div></div>`:'<div class="storm-alert storm-clear">All active storm crews have a Daily Report entered today.</div>';
      byId('stormCrewReadinessList').innerHTML=`<div class="storm-crew-readiness">${crews.map(c=>crewCard(c,canManage())).join('')}</div>`;
      byId('stormCrewReadinessList').querySelectorAll('[data-storm-update]').forEach(button=>button.onclick=async()=>{
        const userId=button.dataset.stormUpdate,select=byId('stormCrewReadinessList').querySelector(`[data-storm-status="${CSS.escape(userId)}"]`);
        await updateCheckIn(userId,select?.value||'assigned',null,null,null);
      });
    }
    renderHistory(workspace?.history||[]);
    const own=crews.find(c=>String(c.user_id)===String(currentProfile?.id));
    const field=byId('stormFieldWorkspace');if(field)field.classList.toggle('hidden',!event||!own||own.deployment_status==='released');
    if(event&&own){
      byId('stormFieldEventSummary').textContent=[event.event_name,event.location].filter(Boolean).join(' — ');
      byId('stormFieldDeploymentStatus').value=own.deployment_status||'assigned';
      byId('stormFieldLocation').value=own.current_location||'';byId('stormFieldLodging').value=own.lodging||'';byId('stormFieldNotes').value=own.readiness_notes||'';
      byId('stormFieldStatusBadge').textContent=statusLabel(own.deployment_status);
    }
  }
  function isUnavailable(error){return ['42883','PGRST202','PGRST204'].includes(error?.code)||/does not exist|schema cache/i.test(error?.message||'');}
  async function loadReferences(){
    if(!canManage())return;
    const [customersResult,contractsResult]=await Promise.all([
      sb.from('customers').select('id,name,active').eq('company_id',currentProfile.company_id).order('name'),
      sb.from('contracts').select('id,customer_id,contract_name,contract_number,active').eq('company_id',currentProfile.company_id).order('created_at',{ascending:false})
    ]);
    if(!customersResult.error)referenceCustomers=customersResult.data||[];
    if(!contractsResult.error)referenceContracts=contractsResult.data||[];
  }
  async function load(){
    if(unavailable||typeof sb==='undefined'||!currentProfile?.company_id)return;
    const {data,error}=await sb.rpc('get_storm_event_workspace');
    if(error){if(isUnavailable(error)){unavailable=true;byId('stormCommandCenter')?.classList.add('hidden');byId('stormFieldWorkspace')?.classList.add('hidden');return;}console.warn('Unable to load Storm Event workspace:',error.message);return;}
    workspace=data||null;await loadReferences();setForm(workspace?.active_event);render();
  }
  async function save(enabled,eventName){
    if(unavailable)return {error:null,skipped:true};
    const amount=nullable('stormEventPerDiemAmount');
    const args={p_enabled:enabled,p_event_name:eventName,p_customer_id:nullable('stormEventCustomer'),p_contract_id:nullable('stormEventContract'),
      p_location:nullable('stormEventLocation'),p_start_date:nullable('stormEventStartDate'),p_expected_end_date:nullable('stormEventExpectedEndDate'),
      p_time_policy:value('stormEventTimePolicy')||'record_only',p_per_diem_policy:value('stormEventPerDiemPolicy')||'manual',
      p_default_per_diem_amount:amount==null?null:Number(amount),p_operations_notes:nullable('stormEventOperationsNotes')};
    const result=await sb.rpc('save_storm_event_workspace',args);
    if(result.error&&isUnavailable(result.error)){unavailable=true;return {error:null,skipped:true};}
    if(!result.error)await load();return result;
  }
  async function updateCheckIn(userId,status,location,lodging,notes){
    if(!workspace?.active_event?.id)return;
    const {error}=await sb.rpc('update_storm_crew_check_in',{p_event_id:workspace.active_event.id,p_user_id:userId,p_deployment_status:status,p_current_location:location,p_lodging:lodging,p_readiness_notes:notes});
    if(error){alert('Unable to save Storm check-in: '+error.message);return;}
    await load();
  }
  byId('stormEventCustomer')?.addEventListener('change',()=>populateReferences(null,true));
  byId('saveStormFieldCheckIn')?.addEventListener('click',async()=>{
    const button=byId('saveStormFieldCheckIn');button.disabled=true;button.textContent='Saving...';
    await updateCheckIn(currentProfile.id,value('stormFieldDeploymentStatus'),nullable('stormFieldLocation'),nullable('stormFieldLodging'),nullable('stormFieldNotes'));
    button.disabled=false;button.textContent='Save Check-In';
  });
  window.LineCrewLoadStormWorkspace=load;
  window.LineCrewSaveStormWorkspace=save;
})();
