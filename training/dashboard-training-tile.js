// Injects a Training tile into the LineCrew Pro dashboard without adding management tracking.
(() => {
  function addTrainingTile(){
    const dashboard = document.getElementById('dashboardPage');
    if(!dashboard || document.getElementById('trainingTile')) return;
    const grid = dashboard.querySelector('.grid');
    if(!grid) return;
    const tile = document.createElement('div');
    tile.className = 'metric';
    tile.id = 'trainingTile';
    tile.setAttribute('role','link');
    tile.setAttribute('tabindex','0');
    tile.innerHTML = '<strong>Training</strong><span class="muted">How-to videos for your LineCrew Pro role</span>';
    const open = () => { window.location.href = '/training/'; };
    tile.addEventListener('click', open);
    tile.addEventListener('keydown', e => { if(e.key === 'Enter' || e.key === ' '){ e.preventDefault(); open(); } });
    grid.appendChild(tile);
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', addTrainingTile);
  else addTrainingTile();
})();