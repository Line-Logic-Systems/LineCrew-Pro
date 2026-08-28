/* LineCrew Pro - handwritten JSA signatures (SVG implementation) */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);
  const toast=(m,t='info')=>window.LineCrewUI?.toast?.(m,t)||console.log(m);
  const NS='http://www.w3.org/2000/svg';
  const cache=window.__lineCrewSignatureStrokes||(window.__lineCrewSignatureStrokes=new Map());
  let active=null;
  let suppressReleaseUntil=0;

  function addStyles(){
    if(byId('lcSigStyles'))return;
    const s=document.createElement('style');s.id='lcSigStyles';s.textContent=`
      .lc-signature-cell{display:block;min-width:0;width:100%}
      .lc-crew-row>.lc-signature-cell{grid-column:2!important}
      .lc-signature-cell>label{display:block!important;min-width:0}
      .lc-signature-wrap{border:1px solid #cfdbe5;border-radius:12px;background:#fff;overflow:hidden;margin:6px 0 12px;width:100%;touch-action:none!important;overscroll-behavior:contain}
      .lc-signature-svg{display:block;width:100%;height:120px;touch-action:none!important;overscroll-behavior:contain;background:repeating-linear-gradient(0deg,#fff,#fff 31px,#edf2f6 32px);cursor:crosshair;user-select:none;-webkit-user-select:none}
      .lc-signature-actions{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:7px 9px;background:#f7fafc;border-top:1px solid #e3eaf0;font-size:12px;color:#667788}
      .lc-signature-actions button{width:auto!important;margin:0!important;padding:6px 10px!important}
      .lc-signature-status.signed{color:#198754;font-weight:800}
      @media(max-width:720px){.lc-crew-row>.lc-signature-cell{grid-column:1!important}}
    `;document.head.appendChild(s);
  }

  function keyFor(input){
    if(input.id==='jsaPersonInChargeSignature')return 'leader';
    return `crew-${input.dataset.index||1}`;
  }

  function svgData(strokes){
    const lines=strokes.map(points=>`<polyline points="${points.map(p=>`${p[0]},${p[1]}`).join(' ')}" fill="none" stroke="#102235" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>`).join('');
    const xml=`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 200" preserveAspectRatio="none">${lines}</svg>`;
    return 'data:image/svg+xml;base64,'+btoa(unescape(encodeURIComponent(xml)));
  }

  function decodeExisting(value){
    if(!value||!value.startsWith('data:image/svg+xml;base64,'))return [];
    try{
      const xml=decodeURIComponent(escape(atob(value.split(',')[1]||'')));
      const doc=new DOMParser().parseFromString(xml,'image/svg+xml');
      return [...doc.querySelectorAll('polyline')].map(el=>(el.getAttribute('points')||'').trim().split(/\s+/).filter(Boolean).map(pair=>pair.split(',').map(Number))).filter(a=>a.length);
    }catch(_){return []}
  }

  function addStroke(svg,points){
    const line=document.createElementNS(NS,'polyline');
    line.setAttribute('points',points.map(p=>`${p[0]},${p[1]}`).join(' '));
    line.setAttribute('fill','none');line.setAttribute('stroke','#102235');line.setAttribute('stroke-width','4');line.setAttribute('stroke-linecap','round');line.setAttribute('stroke-linejoin','round');
    svg.appendChild(line);return line;
  }

  function installPad(input,label){
    if(!input||input.dataset.signaturePadInstalled==='explicit-cell')return;
    const labelEl=input.closest('label');
    if(!labelEl)return;

    const priorCell=labelEl.closest('.lc-signature-cell');
    const oldInner=priorCell?.querySelector(':scope > .lc-signature-wrap')||labelEl.querySelector(':scope > .lc-signature-wrap');
    if(oldInner)oldInner.remove();

    const key=keyFor(input);
    let strokes=cache.get(key)||decodeExisting(input.value)||[];
    cache.set(key,strokes);
    input.dataset.signaturePadInstalled='explicit-cell';input.type='hidden';

    // Make the signature label + pad one explicit grid item. This avoids the pad
    // becoming a third auto-placed child of .lc-crew-row (which lands under Printed Name).
    let cell=priorCell;
    if(!cell){
      cell=document.createElement('div');
      cell.className='lc-signature-cell';
      labelEl.parentNode.insertBefore(cell,labelEl);
      cell.appendChild(labelEl);
    }

    const wrap=document.createElement('div');wrap.className='lc-signature-wrap';
    const svg=document.createElementNS(NS,'svg');svg.classList.add('lc-signature-svg');svg.setAttribute('viewBox','0 0 1000 200');svg.setAttribute('preserveAspectRatio','none');svg.setAttribute('aria-label',label||'Signature pad');
    const actions=document.createElement('div');actions.className='lc-signature-actions';
    const status=document.createElement('span');status.className='lc-signature-status';
    const clear=document.createElement('button');clear.type='button';clear.className='secondary small';clear.textContent='Clear Signature';
    actions.append(status,clear);wrap.append(svg,actions);cell.appendChild(wrap);

    const setStatus=()=>{const signed=strokes.some(s=>s.length>1);status.textContent=signed?'Signature captured':'Sign above with finger, mouse, or stylus';status.classList.toggle('signed',signed)};
    const persist=()=>{cache.set(key,strokes);input.value=strokes.some(s=>s.length>1)?svgData(strokes):'';setStatus()};
    const point=e=>{const r=svg.getBoundingClientRect();return[Math.max(0,Math.min(1000,((e.clientX-r.left)/Math.max(1,r.width))*1000)),Math.max(0,Math.min(200,((e.clientY-r.top)/Math.max(1,r.height))*200))]};
    strokes.forEach(p=>addStroke(svg,p));persist();

    svg.addEventListener('pointerdown',e=>{
      if(e.button!==undefined&&e.button!==0)return;
      e.preventDefault();e.stopPropagation();
      const current=[point(e)];
      strokes=[...strokes,current];cache.set(key,strokes);
      const line=addStroke(svg,current);
      active={pointerId:e.pointerId,svg,input,current,line,point,persist};
      try{svg.setPointerCapture(e.pointerId)}catch(_){}
      status.textContent='Signing…';status.classList.add('signed');
    });

    clear.onclick=e=>{
      e.preventDefault();e.stopPropagation();
      strokes=[];cache.set(key,strokes);input.value='';while(svg.firstChild)svg.removeChild(svg.firstChild);setStatus();
    };
  }

  window.addEventListener('pointermove',e=>{
    if(!active||e.pointerId!==active.pointerId)return;
    e.preventDefault();e.stopImmediatePropagation();
    active.current.push(active.point(e));
    active.line.setAttribute('points',active.current.map(p=>`${p[0]},${p[1]}`).join(' '));
  },true);

  window.addEventListener('touchmove',e=>{
    if(!active)return;
    e.preventDefault();
    e.stopImmediatePropagation();
  },{capture:true,passive:false});

  function finishActive(e){
    if(!active||e.pointerId!==active.pointerId)return;
    e.preventDefault();e.stopImmediatePropagation();
    if(active.current.length===1){active.current.push([active.current[0][0]+1,active.current[0][1]+1]);active.line.setAttribute('points',active.current.map(p=>`${p[0]},${p[1]}`).join(' '))}
    const finished=active;
    finished.persist();
    try{finished.svg.releasePointerCapture(finished.pointerId)}catch(_){}
    suppressReleaseUntil=Date.now()+800;
    active=null;
  }
  window.addEventListener('pointerup',finishActive,true);
  window.addEventListener('pointercancel',finishActive,true);

  window.addEventListener('mouseup',e=>{
    if((!active&&Date.now()>suppressReleaseUntil)||!e.target?.closest?.('.lc-signature-wrap'))return;
    e.preventDefault();e.stopImmediatePropagation();
  },true);
  window.addEventListener('click',e=>{
    if(Date.now()>suppressReleaseUntil||!e.target?.closest?.('.lc-signature-wrap'))return;
    e.preventDefault();e.stopImmediatePropagation();
  },true);

  function upgrade(){
    document.querySelectorAll('.jsa-signature-input').forEach((input,i)=>installPad(input,`Crew member ${i+1} signature`));
    installPad(byId('jsaPersonInChargeSignature'),'JSA Leader / Person in Charge signature');
    const pic=byId('jsaPersonInChargeName'),leader=byId('safetyJsaLeader'),foreman=byId('safetyJsaForeman');if(pic&&!pic.value)pic.value=leader?.value||foreman?.value||'';
  }

  function validate(e){
    if(!e.target?.closest?.('#saveSafetyJsaBtn'))return;
    const firstName=document.querySelector('.jsa-printed-name-input')?.value?.trim();const firstSig=document.querySelector('.jsa-signature-input')?.value||'';
    const picName=byId('jsaPersonInChargeName')?.value?.trim();const picSig=byId('jsaPersonInChargeSignature')?.value||'';
    if(firstName&&!firstSig)toast('Crew member name entered — please add the handwritten signature.','warning');
    if(picName&&!picSig)toast('Please sign the JSA Leader / Person in Charge signature box.','warning');
  }

  function init(){addStyles();upgrade();document.addEventListener('click',validate,true);const obs=new MutationObserver(upgrade);obs.observe(document.body,{subtree:true,childList:true})}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
