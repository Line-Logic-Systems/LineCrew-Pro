/* LineCrew Pro — retained job packet PDFs and work-point map access. */
(() => {
  'use strict';

  const BUCKET = 'job-packet-documents';
  const MAX_BYTES = 100 * 1024 * 1024;
  let pendingPacketPdf = null;
  let uploadInFlight = false;
  let lastUiKey = '';
  let syncScheduled = false;
  const observedTargets = new WeakSet();
  const completedUploads = new Set();

  function byId(id){ return document.getElementById(id); }
  function profile(){ try { return currentProfile || window.currentProfile || null; } catch (_) { return window.currentProfile || null; } }
  function role(){ return String(profile()?.role || '').toLowerCase(); }
  function sbClient(){ try { return sb; } catch (_) { return window.sb || null; } }
  function openPackage(){ try { return currentOpenJobPackage || null; } catch (_) { return null; } }
  function openReport(){ try { return currentDailyUnitReport || null; } catch (_) { return null; } }
  function packageCatalog(){ try { return Array.isArray(currentJobPackageCatalog) ? currentJobPackageCatalog : []; } catch (_) { return []; } }
  function openJobId(){ try { return currentOpenJobId || null; } catch (_) { return null; } }
  function escapeText(value){ return String(value ?? '').replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[char])); }
  function formatBytes(value){ const bytes=Number(value||0); if(bytes<1024)return bytes+' B'; if(bytes<1048576)return(bytes/1024).toFixed(1)+' KB'; return(bytes/1048576).toFixed(1)+' MB'; }

  function showNotice(message, error=false){
    byId('jobMapTransientNotice')?.remove();
    const notice=document.createElement('div');
    notice.id='jobMapTransientNotice';
    notice.setAttribute('role','status');
    notice.style.cssText='position:fixed;left:50%;bottom:22px;transform:translateX(-50%);z-index:10000;max-width:min(92vw,620px);padding:12px 16px;border-radius:12px;box-shadow:0 10px 30px rgba(0,0,0,.22);font:700 14px Arial,sans-serif;background:'+(error?'#7f1d1d;color:white':'#0b2d4d;color:white');
    notice.textContent=message;
    document.body.appendChild(notice);
    setTimeout(()=>notice.remove(),4500);
  }

  async function hashFile(file){
    if(!crypto?.subtle)return null;
    const digest=await crypto.subtle.digest('SHA-256',await file.arrayBuffer());
    return [...new Uint8Array(digest)].map(value=>value.toString(16).padStart(2,'0')).join('');
  }
  async function pdfPageCount(file){
    try{ if(!window.PDFLib?.PDFDocument)return null; const doc=await window.PDFLib.PDFDocument.load(await file.arrayBuffer(),{updateMetadata:false}); return doc.getPageCount(); }
    catch(_){ return null; }
  }

  function candidatePackageForFile(file){
    const current=openPackage();
    if(current&&(!file?.name||!current.source_filename||String(current.source_filename).toLowerCase()===String(file.name).toLowerCase()))return current;
    const jobId=String(openJobId()||'');
    return packageCatalog().filter(item=>!jobId||String(item.job_id)===jobId).filter(item=>!file?.name||!item.source_filename||String(item.source_filename).toLowerCase()===String(file.name).toLowerCase()).sort((a,b)=>Number(b.revision_number||1)-Number(a.revision_number||1))[0]||null;
  }

  async function preservePendingPacket(){
    if(uploadInFlight||!pendingPacketPdf)return;
    const client=sbClient(); const user=profile(); const packet=candidatePackageForFile(pendingPacketPdf);
    if(!client||!user?.company_id||!packet?.id||!packet?.job_id)return;
    const file=pendingPacketPdf; const key=[packet.id,file.name,file.size,file.lastModified].join('|');
    if(completedUploads.has(key)){pendingPacketPdf=null;return;}
    if(file.size>MAX_BYTES){showNotice('The original packet is larger than 100 MB, so it was not retained. The unit import can still continue.',true);pendingPacketPdf=null;return;}
    uploadInFlight=true;
    try{
      const [pageCount,sourceSha256]=await Promise.all([pdfPageCount(file),hashFile(file)]);
      const safeName=String(file.name||'job-packet.pdf').replace(/[^a-zA-Z0-9._-]+/g,'-').slice(-120)||'job-packet.pdf';
      const path=`${user.company_id}/${packet.job_id}/${packet.id}/${safeName}`;
      const upload=await client.storage.from(BUCKET).upload(path,file,{contentType:'application/pdf',upsert:true,cacheControl:'3600'});
      if(upload.error)throw upload.error;
      const registered=await client.rpc('register_job_package_document',{p_job_package_id:packet.id,p_storage_path:path,p_original_filename:file.name||'Job Packet.pdf',p_mime_type:'application/pdf',p_file_size_bytes:file.size,p_page_count:pageCount,p_source_sha256:sourceSha256});
      if(registered.error)throw registered.error;
      completedUploads.add(key); pendingPacketPdf=null;
      showNotice(`Original job packet saved${pageCount?` (${pageCount} pages)`:''}.`);
      await refreshPackageDocumentButton();
    }catch(error){
      console.error('LineCrew Pro packet retention failed',error);
      showNotice('The job data import can continue, but the original packet PDF could not be saved: '+(error?.message||'Unknown error'),true);
    }finally{ uploadInFlight=false; }
  }

  function isJobPacketPdfInput(input,file){
    if(!(input instanceof HTMLInputElement)||input.type!=='file'||!file)return false;
    if(String(file.type||'').toLowerCase()!=='application/pdf'&&!/\.pdf$/i.test(file.name||''))return false;
    const jobsPage=byId('jobsPage');
    if(!jobsPage||jobsPage.classList.contains('hidden')||!jobsPage.contains(input))return false;
    const context=[input.id,input.name,input.getAttribute('accept'),input.closest('label')?.textContent,input.parentElement?.textContent].filter(Boolean).join(' ').toLowerCase();
    return /packet|jacket|job package|utility/.test(context);
  }

  document.addEventListener('change',event=>{
    const input=event.target; const file=input?.files?.[0];
    if(!isJobPacketPdfInput(input,file))return;
    pendingPacketPdf=file;
    [250,1200,3500].forEach(delay=>setTimeout(preservePendingPacket,delay));
  },true);

  async function listDocuments({packageId=null,jobId=null}={}){
    const client=sbClient(); if(!client)return[];
    const result=await client.rpc('get_job_package_documents',{p_job_package_id:packageId,p_job_id:jobId});
    if(result.error)throw result.error; return result.data||[];
  }

  async function openStoredPdf(documentRow,pageNumber=null){
    const client=sbClient(); if(!client||!documentRow?.storage_path)return;
    const signed=await client.storage.from(BUCKET).createSignedUrl(documentRow.storage_path,900);
    if(signed.error)throw signed.error;
    let url=signed.data?.signedUrl; if(!url)throw new Error('Unable to create a secure packet link.');
    if(Number(pageNumber)>0)url+=`#page=${Number(pageNumber)}`;
    window.open(url,'_blank','noopener,noreferrer');
  }

  async function openPackageDocuments(packageId){
    try{ const docs=await listDocuments({packageId}); if(!docs.length){alert('No original PDF is stored for this package yet. New PDF job-packet imports will be retained automatically.');return;} if(docs.length===1){await openStoredPdf(docs[0]);return;} showDocumentChooser(docs); }
    catch(error){ alert('Unable to open job maps: '+(error?.message||'Unknown error')); }
  }

  function showDocumentChooser(docs){
    byId('jobMapDocumentChooser')?.remove();
    const backdrop=document.createElement('div'); backdrop.id='jobMapDocumentChooser'; backdrop.style.cssText='position:fixed;inset:0;z-index:9999;background:rgba(6,20,34,.78);display:grid;place-items:center;padding:18px';
    const card=document.createElement('div'); card.className='card'; card.style.cssText='width:min(620px,100%);max-height:88vh;overflow:auto;margin:0';
    card.innerHTML='<div style="display:flex;justify-content:space-between;gap:12px;align-items:flex-start"><div><h3 style="margin:0">Job Maps & Original Packets</h3><p class="muted">Open the retained source document.</p></div><button type="button" class="secondary small" data-close>Close</button></div><div data-docs></div>';
    const list=card.querySelector('[data-docs]');
    docs.forEach(doc=>{ const row=document.createElement('div'); row.className='job-card'; row.style.marginBottom='10px'; row.innerHTML=`<strong>${escapeText(doc.original_filename||'Job Packet.pdf')}</strong><div class="muted">${doc.page_count?`${doc.page_count} pages · `:''}${formatBytes(doc.file_size_bytes)}</div>`; const button=document.createElement('button'); button.type='button'; button.className='success small'; button.textContent='Open Maps / Packet'; button.onclick=async()=>{try{await openStoredPdf(doc);}catch(error){alert('Unable to open packet: '+error.message);}}; row.appendChild(button); list.appendChild(row); });
    card.querySelector('[data-close]').onclick=()=>backdrop.remove(); backdrop.addEventListener('click',event=>{if(event.target===backdrop)backdrop.remove();}); backdrop.appendChild(card); document.body.appendChild(backdrop);
  }

  async function openMapForCurrentDailyReport(){
    const report=openReport(); const client=sbClient();
    if(!report?.job_id||!client){alert('Open a Daily Report job before viewing its map.');return;}
    const location=String(byId('dailyUnitPoleLocation')?.value||'').trim();
    const result=await client.rpc('get_job_map_page',{p_job_id:report.job_id,p_work_point_code:location||null});
    if(result.error){alert('Unable to find the job map: '+result.error.message);return;}
    const map=(result.data||[])[0];
    if(!map){alert('No original job packet PDF is stored for this job yet.');return;}
    if(location&&!map.page_number){if(!confirm(`The packet is stored, but LineCrew Pro does not have a specific source page recorded for “${location}”. Open the full packet instead?`))return;}
    try{await openStoredPdf(map,map.page_number);}catch(error){alert('Unable to open the map: '+error.message);}
  }

  async function refreshPackageDocumentButton(){
    const card=byId('jobPackageDetailCard'); const packet=openPackage();
    if(!card||card.classList.contains('hidden')||!packet?.id){byId('jobPackageMapTools')?.remove();return;}
    let mount=byId('jobPackageMapTools');
    if(!mount){ mount=document.createElement('div'); mount.id='jobPackageMapTools'; mount.className='job-card'; mount.style.cssText='margin:12px 0;padding:12px;display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap'; const title=byId('jobPackageDetailTitle'); (title?.parentElement||card).insertAdjacentElement(title?'afterend':'afterbegin',mount); }
    const key=String(packet.id); if(mount.dataset.loading===key||mount.dataset.ready===key)return;
    mount.dataset.loading=key; mount.innerHTML='<div><strong>Maps & Original Job Packet</strong><div class="muted">Checking retained source document…</div></div>';
    try{ const docs=await listDocuments({packageId:packet.id}); mount.dataset.ready=key; delete mount.dataset.loading; const summary=docs.length?`${docs.length} retained PDF${docs.length===1?'':'s'}${docs[0]?.page_count?` · ${docs[0].page_count} pages`:''}`:'No original PDF retained yet'; mount.innerHTML=`<div><strong>Maps & Original Job Packet</strong><div class="muted">${escapeText(summary)}</div></div>`; const button=document.createElement('button'); button.type='button'; button.className='success small'; button.textContent=docs.length?'View Maps / Packet':'No Map Stored'; button.disabled=docs.length===0; button.onclick=()=>openPackageDocuments(packet.id); mount.appendChild(button); }
    catch(error){delete mount.dataset.loading; mount.innerHTML=`<div><strong>Maps & Original Job Packet</strong><div class="muted">Unable to load: ${escapeText(error?.message||'Unknown error')}</div></div>`;}
  }

  function syncDailyMapButton(){
    const header=document.querySelector('#dailyUnitEditor .daily-pole-entry-header'); const allowed=['foreman','gf'].includes(role());
    if(!header||!allowed){byId('dailyReportMapButton')?.remove();return;}
    if(byId('dailyReportMapButton'))return;
    const button=document.createElement('button'); button.id='dailyReportMapButton'; button.type='button'; button.className='secondary small'; button.style.marginTop='8px'; button.textContent='View Job Map'; button.title='Open the original job packet; when this work point was detected during import, jump to its source page.'; button.onclick=openMapForCurrentDailyReport; header.appendChild(button);
  }

  function syncUi(){
    const packet=openPackage(); const report=openReport(); const key=[packet?.id||'',report?.id||'',role(),byId('dailyUnitEditor')?.classList.contains('hidden')?'0':'1'].join('|');
    if(key!==lastUiKey){lastUiKey=key;void refreshPackageDocumentButton();syncDailyMapButton();}else syncDailyMapButton();
    if(pendingPacketPdf)void preservePendingPacket();
  }

  function scheduleSync(){
    if(syncScheduled)return;
    syncScheduled=true;
    requestAnimationFrame(()=>{syncScheduled=false;syncUi();installScopedObservers();});
  }

  function observeTarget(target){
    if(!target||observedTargets.has(target))return;
    observedTargets.add(target);
    const observer=new MutationObserver(scheduleSync);
    observer.observe(target,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});
  }

  function installScopedObservers(){
    observeTarget(byId('jobPackageDetailCard'));
    observeTarget(byId('dailyUnitEditor'));
    observeTarget(byId('jobsPage'));
  }

  function init(){
    installScopedObservers();
    scheduleSync();
    [250,900,2200].forEach(delay=>setTimeout(scheduleSync,delay));
    window.addEventListener('focus',scheduleSync);
    window.addEventListener('pageshow',scheduleSync);
    document.addEventListener('linecrew:pagechange',scheduleSync);
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init,{once:true});else init();
})();
