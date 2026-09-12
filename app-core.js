/* LineCrew Pro — shared app core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  function uniqueOfflineJsaJobs(jobs){
    const unique = new Map();
    (jobs || []).forEach(job => {
      const id = String(job?.id || '');
      if(!id || unique.has(id)) return;
      unique.set(id,{id,job_number:String(job.job_number || 'Job').slice(0,100),job_name:String(job.job_name || 'Unnamed').slice(0,180)});
    });
    return [...unique.values()];
  }
  function offlineJsaNetworkFailure(error){ const message=String(error?.message || error || '').toLowerCase(); return !navigator.onLine || /failed to fetch|network|load failed|timeout|timed out|connection/.test(message); }
  function companyAccessInactive(error){ const text=String(error?.message || '')+' '+String(error?.hint || ''); return /company access is inactive/i.test(text); }
  function firstStackFrame(error){ return String(error?.stack || '').split('\n').map(line=>line.trim()).find(line=>/:\d+:\d+/.test(line)) || ''; }
  function desktopViewEnabled(){ try{return localStorage.getItem('linecrew-pro-desktop-view')==='1';}catch(error){return document.documentElement.classList.contains('desktop-view');} }
  function currentErrorPage(){ return [...document.querySelectorAll('main > section')].find(section=>!section.classList.contains('hidden'))?.id || window.location.pathname || 'app'; }
  function formatTeamRole(role){ const roleLabels={owner:'Owner',manager:'Manager',admin:'Admin',superintendent:'Superintendent',gf:'General Foreman',foreman:'Foreman',safety:'Safety'}; return roleLabels[String(role || '').toLowerCase()] || 'Foreman'; }
  function formatAuditTimestamp(value){ if(!value)return 'Not recorded'; const date=new Date(value); if(Number.isNaN(date.getTime()))return String(value); return date.toLocaleString(undefined,{year:'numeric',month:'short',day:'numeric',hour:'numeric',minute:'2-digit'}); }
  function formatCurrency(value){ const amount=Number(value || 0); return amount.toLocaleString('en-US',{style:'currency',currency:'USD'}); }
  function csvCell(value){ let text=String(value ?? ''); if(typeof value==='string' && (/^[\t\r\n]/.test(text) || /^\s*[=+\-@]/.test(text))) text="'"+text; return '"'+text.replace(/"/g,'""')+'"'; }
  function companyLogoExtension(file){ if(file?.type==='image/png')return 'png'; if(file?.type==='image/jpeg')return 'jpg'; if(file?.type==='image/webp')return 'webp'; return ''; }
  function companyJsaFileKey(file){ return [file.name,file.size,file.lastModified].join(':'); }
  function safeJsaFilename(name){ return String(name || 'jsa-file').replace(/[^a-zA-Z0-9._-]+/g,'-').replace(/^-+|-+$/g,'').slice(-140) || 'jsa-file'; }
  function allowedJsaFile(file){
    return ['application/pdf','image/jpeg','image/png','image/heic','image/heif'].includes(String(file?.type || '').toLowerCase()) &&
      Number(file?.size || 0) > 0 && Number(file?.size || 0) <= 15728640;
  }
  function userCanSeeSafetyRecords(){
    const role = typeof window.currentUserRole === 'function' ? String(window.currentUserRole() || '').toLowerCase() : '';
    if(role === 'safety') return true;
    if(['gf','foreman'].includes(role)) return true;
    return typeof window.userHasCapability === 'function' && window.userHasCapability('safety_records');
  }

  const api = Object.freeze({uniqueOfflineJsaJobs,offlineJsaNetworkFailure,companyAccessInactive,firstStackFrame,desktopViewEnabled,currentErrorPage,formatTeamRole,formatAuditTimestamp,formatCurrency,csvCell,companyLogoExtension,companyJsaFileKey,safeJsaFilename,allowedJsaFile,userCanSeeSafetyRecords});
  window.LineCrewAppCore = api;
  window.uniqueOfflineJsaJobs=uniqueOfflineJsaJobs;
  window.offlineJsaNetworkFailure=offlineJsaNetworkFailure;
  window.companyAccessInactive=companyAccessInactive;
  window.firstStackFrame=firstStackFrame;
  window.desktopViewEnabled=desktopViewEnabled;
  window.currentErrorPage=currentErrorPage;
  window.formatTeamRole=formatTeamRole;
  window.formatAuditTimestamp=formatAuditTimestamp;
  window.formatCurrency=formatCurrency;
  window.csvCell=csvCell;
  window.companyLogoExtension=companyLogoExtension;
  window.companyJsaFileKey=companyJsaFileKey;
  window.safeJsaFilename=safeJsaFilename;
  window.allowedJsaFile=allowedJsaFile;
  window.userCanSeeSafetyRecords=userCanSeeSafetyRecords;
})();
