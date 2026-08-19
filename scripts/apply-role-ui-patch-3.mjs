import fs from 'node:fs';
const path='index.html';
let html=fs.readFileSync(path,'utf8');
const done=[];
function r(before,after,label){ if(!html.includes(before)) throw new Error('Missing target: '+label); html=html.replace(before,after); done.push(label); }

r(`  const canViewJobPackages = ['admin', 'gf'].includes(\n    String(currentProfile.role || '').toLowerCase()\n  );`, `  const canViewJobPackages = userCanUseReporting() || userCanManageJobPackages();`, 'job package visibility');
r(`    !['admin', 'gf'].includes(String(currentProfile?.role || '').toLowerCase())`, `    !userCanManageJobs()`, 'jobs detail create visibility');
r(`  const canManage =\n    currentProfile.role === 'admin' ||\n    currentProfile.role === 'gf';`, `  const canManage = userCanManageJobs();`, 'job edit capability');

r(`  if(currentProfile.role === 'admin'){\n\n    const packageButton = document.createElement('button');\n    packageButton.className = 'small success';\n    packageButton.textContent = '+ Add Utility Package';\n    packageButton.onclick = ()=> showJobPackageForm(job);\n    actions.appendChild(packageButton);\n\n    const deleteButton =\n      document.createElement('button');\n\n    deleteButton.className =\n      'small danger';\n\n    deleteButton.textContent =\n      'Delete Job';\n\n    deleteButton.onclick =\n      ()=> deleteJob(job);\n\n    actions.appendChild(\n      deleteButton\n    );\n  }\n\n  if(['admin', 'gf'].includes(String(currentProfile.role || '').toLowerCase())){\n    renderJobPackages(job, card.querySelector(\`#job-packages-\${job.id}\`));\n  }`,
`  if(userCanManageJobPackages()){\n    const packageButton = document.createElement('button');\n    packageButton.className = 'small success';\n    packageButton.textContent = '+ Add Utility Package';\n    packageButton.onclick = ()=> showJobPackageForm(job);\n    actions.appendChild(packageButton);\n  }\n\n  if(userCanManageJobs()){\n    const deleteButton = document.createElement('button');\n    deleteButton.className = 'small danger';\n    deleteButton.textContent = 'Delete Job';\n    deleteButton.onclick = ()=> deleteJob(job);\n    actions.appendChild(deleteButton);\n  }\n\n  if(userCanUseReporting() || userCanManageJobPackages()){\n    renderJobPackages(job, card.querySelector(\`#job-packages-\${job.id}\`));\n  }`, 'split job and package controls');

r(`async function changeJobLeaderAssignment(job, memberId, assigned){\n  if(!['admin', 'gf'].includes(String(currentProfile.role || '').toLowerCase())){`, `async function changeJobLeaderAssignment(job, memberId, assigned){\n  if(!userCanManageJobs()){`, 'job leader capability');

const packageStart=html.indexOf('function renderJobPackages(job, container)');
const packageEnd=html.indexOf('/* EDIT JOB */',packageStart);
if(packageStart<0||packageEnd<0) throw new Error('Job package section not found');
let block=html.slice(packageStart,packageEnd);
block=block.replaceAll('userIsCompanyAdmin()', 'userCanManageJobPackages()');
block=block.replaceAll('const isAdmin = userCanManageJobPackages();', 'const canManagePackage = userCanManageJobPackages();');
block=block.replaceAll('!isAdmin || isClosed', '!canManagePackage || isClosed');
block=block.replaceAll('!isAdmin);', '!canManagePackage);');
block=block.replaceAll('if(!isAdmin){', 'if(!canManagePackage){');
html=html.slice(0,packageStart)+block+html.slice(packageEnd);
done.push('job package section capability');

fs.writeFileSync(path,html);
console.log('Applied:',done.join(', '));
