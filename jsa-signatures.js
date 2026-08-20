/* LineCrew Pro - handwritten JSA signatures */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);
  const toast=(m,t='info')=>window.LineCrewUI?.toast?.(m,t)||console.log(m);

  function addStyles(){if(byId('lcSigStyles'))return;const s=document.createElement('style');s.id='lcSigStyles';s.textContent=`
    .lc-signature-wrap{border:1px solid #cfdbe5;border-radius:12px;background:#fff;overflow:hidden;margin-top:5px}
    .lc-signature-pad{display:block;width:100%;height:120px;touch-action:none;background:linear-gradient(#fff,#fff),repeating-linear-gradient(0deg,transparent,transparent 31px,#edf2f6 32px)}
    .lc-signature-actions{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:7px 9px;background:#f7fafc;border-top:1px solid #e3eaf0;font-size:12px;color:#667788}
    .lc-signature-actions button{width:auto!important;margin:0!important;padding:6px 10px!important}
    .lc-signature-status.signed{color:#198754;font-weight:800}
  `;document.head.appendChild(s)}

  function installPad(input,labelText){
    if(!input || input.dataset.signaturePadInstalled==='1')return;
    input.dataset.signaturePadInstalled='1';input.type='hidden';
    const wrap=document.createElement('div');wrap.className='lc-signature-wrap';
    const canvas=document.createElement('canvas');canvas.className='lc-signature-pad';canvas.setAttribute('aria-label',labelText||'Signature pad');
    const actions=document.createElement('div');actions.className='lc-signature-actions';
    const status=document.createElement('span');status.className='lc-signature-status';status.textContent='Sign above with finger, mouse, or stylus';
    const clear=document.createElement('button');clear.type='button';clear.className='secondary small';clear.textContent='Clear Signature';
    actions.append(status,clear);wrap.append(canvas,actions);input.insertAdjacentElement('afterend',wrap);
    let drawing=false,last=null,signed=false;
    const ctx=canvas.getContext('2d');
    function resize(){const r=canvas.getBoundingClientRect();const ratio=Math.max(1,window.devicePixelRatio||1);const prev=input.value;canvas.width=Math.round(r.width*ratio);canvas.height=Math.round(120*ratio);ctx.setTransform(ratio,0,0,ratio,0,0);ctx.lineWidth=2.4;ctx.lineCap='round';ctx.lineJoin='round';ctx.strokeStyle='#102235';if(prev&&prev.startsWith('data:image/')){const img=new Image();img.onload=()=>ctx.drawImage(img,0,0,r.width,120);img.src=prev;}}
    function pos(e){const r=canvas.getBoundingClientRect();const p=e.touches?.[0]||e.changedTouches?.[0]||e;return{x:p.clientX-r.left,y:p.clientY-r.top}}
    function start(e){e.preventDefault();drawing=true;last=pos(e);canvas.setPointerCapture?.(e.pointerId)}
    function move(e){if(!drawing)return;e.preventDefault();const p=pos(e);ctx.beginPath();ctx.moveTo(last.x,last.y);ctx.lineTo(p.x,p.y);ctx.stroke();last=p;signed=true;status.textContent='Signature captured';status.classList.add('signed');}
    function end(e){if(!drawing)return;e?.preventDefault?.();drawing=false;if(signed){input.value=canvas.toDataURL('image/png');input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));}}
    canvas.addEventListener('pointerdown',start);canvas.addEventListener('pointermove',move);canvas.addEventListener('pointerup',end);canvas.addEventListener('pointercancel',end);
    canvas.addEventListener('touchstart',start,{passive:false});canvas.addEventListener('touchmove',move,{passive:false});canvas.addEventListener('touchend',end,{passive:false});
    clear.onclick=()=>{ctx.clearRect(0,0,canvas.width,canvas.height);signed=false;input.value='';status.textContent='Sign above with finger, mouse, or stylus';status.classList.remove('signed');input.dispatchEvent(new Event('change',{bubbles:true}));};
    requestAnimationFrame(resize);window.addEventListener('resize',()=>setTimeout(resize,120));
  }

  function upgrade(){
    document.querySelectorAll('.jsa-signature-input').forEach((input,i)=>installPad(input,`Crew member ${i+1} signature`));
    installPad(byId('jsaPersonInChargeSignature'),'JSA Leader / Person in Charge signature');
    const pic=byId('jsaPersonInChargeName');const leader=byId('safetyJsaLeader');const foreman=byId('safetyJsaForeman');
    if(pic && !pic.value)pic.value=leader?.value||foreman?.value||'';
  }

  function validateBeforeSave(e){
    const btn=e.target?.closest?.('#saveSafetyJsaBtn');if(!btn)return;
    const firstName=document.querySelector('.jsa-printed-name-input')?.value?.trim();const firstSig=document.querySelector('.jsa-signature-input')?.value||'';
    const picName=byId('jsaPersonInChargeName')?.value?.trim();const picSig=byId('jsaPersonInChargeSignature')?.value||'';
    if(firstName && !firstSig)toast('Crew member name entered — please add the handwritten signature.','warning');
    if(picName && !picSig)toast('Please sign the JSA Leader / Person in Charge signature box.','warning');
  }

  function init(){addStyles();upgrade();document.addEventListener('click',validateBeforeSave,true);const obs=new MutationObserver(upgrade);obs.observe(document.body,{subtree:true,childList:true});}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();