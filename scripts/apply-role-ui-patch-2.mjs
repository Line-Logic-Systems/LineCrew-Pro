import fs from 'node:fs';

const path = 'index.html';
let html = fs.readFileSync(path, 'utf8');
const changed = [];

function replaceExact(before, after, label){
  if(!html.includes(before)) throw new Error('Patch target not found: ' + label);
  html = html.replace(before, after);
  changed.push(label);
}

replaceExact(
`function userCanUseAssistant(){ return userHasCapability('ai_assistant'); }\nfunction userCanSeeActualContractPrices(){`,
`function userCanUseAssistant(){ return userHasCapability('ai_assistant'); }\nfunction userCanManageCompanySettings(){ return userHasCapability('company_settings'); }\nfunction userCanManageCustomersContracts(){ return userHasCapability('customers_contracts'); }\nfunction userCanManagePriceBooks(){ return userHasCapability('price_books'); }\nfunction userCanManageJobPackages(){ return userHasCapability('job_packages'); }\nfunction userCanExport(){ return userHasCapability('exports') || currentUserRole() === 'gf'; }\nfunction userCanSeeSafetyRecords(){ return userHasCapability('safety_records') || ['gf','foreman'].includes(currentUserRole()); }\nfunction userCanSeeActualContractPrices(){`,
'capability helpers');

replaceExact(
`async function loadCompanyOnboarding(){\n  const card = $('companyOnboarding');\n  if(!userIsCompanyAdmin()){`,
`async function loadCompanyOnboarding(){\n  const card = $('companyOnboarding');\n  if(!userHasAnyCompanyControls()){`,
'onboarding leadership access');

replaceExact(
`$('saveCompanySettings').onclick = async () => {\n  if(!userIsCompanyAdmin()) return;`,
`$('saveCompanySettings').onclick = async () => {\n  if(!userCanManageCompanySettings()) return;`,
'company settings capability');

replaceExact(
`$('saveRedlineApprovalSetting').onclick = async () => {\n  if(!userIsCompanyAdmin()) return;`,
`$('saveRedlineApprovalSetting').onclick = async () => {\n  if(!userCanReviewProduction()) return;`,
'redline policy capability');

replaceExact(
`$('saveStormModeSetting').onclick = async () => {\n  if(!userIsCompanyAdmin()) return;`,
`$('saveStormModeSetting').onclick = async () => {\n  if(!userCanManageStormMode()) return;`,
'storm mode capability');

// Scope Customer / Contract management to its explicit Superintendent capability.
const customerStart = html.indexOf('/* CUSTOMER / UTILITY FORM */');
const customerEnd = html.indexOf('/* PRICE BOOK FORM */', customerStart);
if(customerStart < 0 || customerEnd < 0) throw new Error('Customer/Contract section not found');
let customerBlock = html.slice(customerStart, customerEnd);
customerBlock = customerBlock.replaceAll('userIsCompanyAdmin()', 'userCanManageCustomersContracts()');
customerBlock = customerBlock.replaceAll('Only company admins can manage customers and utilities.', 'You do not have permission to manage customers and utilities.');
customerBlock = customerBlock.replaceAll('Only company admins can manage contracts.', 'You do not have permission to manage contracts.');
html = html.slice(0, customerStart) + customerBlock + html.slice(customerEnd);
changed.push('customer and contract capability');

// The Price Book controls already centralize most edit visibility through this helper.
replaceExact(
`function userCanManagePriceBooks(){\n  return userIsCompanyAdmin();\n}`,
`function userCanManagePriceBooks(){\n  return userHasCapability('price_books');\n}`,
'price book capability');

// Exports honor the explicit export capability where these company catalogs are downloaded.
html = html.replace(
`$('exportCustomersBtn').onclick = () => {\n  if(!userCanManageCustomersContracts()) return;`,
`$('exportCustomersBtn').onclick = () => {\n  if(!userCanManageCustomersContracts() || !userCanExport()) return;`
);
html = html.replace(
`$('exportContractsBtn').onclick = () => {\n  if(!userCanManageCustomersContracts()) return;`,
`$('exportContractsBtn').onclick = () => {\n  if(!userCanManageCustomersContracts() || !userCanExport()) return;`
);

fs.writeFileSync(path, html);
console.log('Applied:', changed.join(', '));
