# LineCrew Pro Weekend Pilot Test

Use this checklist only against the disposable LineCrew Pro Test environment. Never use it against production. Record every failure with the role, screen, action, device and exact error text.

## Before testers arrive

- Start the app from a non-production hostname or local test build and confirm it loads on desktop and mobile.
- Confirm the browser connects only to the Test Supabase project `yvuxrqrdprquxypiffpa`.
- Stop immediately if the browser connects to production project `ldgkyxuozbozgkvwzadg` or if the hostname is `app.linecrewpro.com`.
- Use a fresh company/test dataset if the test is intended to simulate first-time onboarding.
- Have separate test email accounts available for Owner, Admin, Superintendent, General Foreman and at least two Foremen.
- Test at least one iPhone/Android-class phone and one desktop browser.

## 1. Company onboarding and Owner

1. Create/join the test company through the normal onboarding flow.
2. Confirm the first new team member begins as Foreman unless the company-owner claim path is intentionally used.
3. Claim/assign Owner using the supported Team flow.
4. Sign out and back in after the role change.
5. Confirm Owner can see company controls, Team, customers/contracts, Price Books, jobs, production review/reporting, safety records, storm controls and assistant.
6. Confirm Owner/Admin can promote a lower-role active member to Admin.
7. Confirm only Owner can modify an existing Admin and transfer ownership to another active Admin.

Expected: no role escalation is possible outside the Team controls/RPCs.

## 2. Team and role hierarchy

Create one user for each role and verify:

- Owner can manage existing Admin, Superintendent, GF and Foreman roles.
- Admin can promote an active Foreman, GF or Superintendent to Admin.
- Admin cannot modify Owner or an existing Admin and cannot assign Owner.
- With zero Owners, one active Admin can claim the initial Owner role; after that, a second claim fails.
- Owner transfer changes the chosen active Admin to Owner and the prior Owner to Admin in one step, leaving exactly one Owner.
- Superintendent can only manage GF/Foreman when `role_management` is enabled.
- Superintendent cannot modify/suspend Owner, Admin or another Superintendent.
- GF cannot manage company roles.
- Foreman cannot manage company roles.
- Suspended users cannot continue using privileged controls after refresh/sign-in.

## 3. Superintendent permission switches

For the Superintendent, test each permission both ON and OFF where practical:

- company settings
- team management
- role management
- customers/contracts
- Price Books
- jobs
- job packages
- production review
- reporting/exports
- storm mode
- safety records
- actual pricing

Expected: turning a capability off removes both the UI path and the server-authorized action where applicable. Re-enable it and verify access returns.

## 4. Customer, contract and Price Book

As Owner/Admin:

1. Create a customer/utility.
2. Create a contract.
3. Create a Price Book tied to that contract.
4. Add at least three units manually.
5. Import a small CSV/XLSX with at least one new unit and one matching unit update.
6. Verify install/remove prices and descriptions.
7. Verify Foreman sees only permitted field/adjusted pricing.
8. Verify Owner/Admin/GF and a permitted Superintendent see actual pricing as intended.
9. Duplicate a Price Book as a new version and confirm history remains intact.

## 5. Jobs and job package

1. Create a job tied to the correct contract.
2. Add/create work points.
3. Assign a Foreman/GF leader if that feature is being used.
4. Import a utility job package with multiple work points and units.
5. Confirm authorized quantities/value and progress totals.
6. Confirm a Foreman can only work in the jobs intended for field use.

## 6. Foreman production before packet

Before loading a packet on a second test job:

1. Foreman creates a daily report.
2. Enter one pole/work point, add all of its units, then choose Save Pole & Add Next.
3. Repeat for several pole/work-point locations.
4. Verify saved entries show Pending Packet rather than failing.
5. Later import the matching job package.
6. Confirm existing production reconciles automatically.
7. Confirm correct entries become Authorized and mismatches become Redline.

## 7. Daily report lifecycle

As Foreman:

1. Create report.
2. Enter crew/hours/weather/notes.
3. Add more than 10 unit lines to one pole to force Add 5 Unit Lines.
4. Choose Save Pole & Add Next, then add multiple work points/poles.
5. Expand the compact saved-pole cards and verify each pole's units.
6. Add/edit/remove a draft unit.
7. Attach a supporting file/photo if available.
8. Choose Done Adding Units.
9. Submit Report.

As GF/authorized management:

10. Open review queue.
11. Review hours, units, attachments and exception badges.
12. Return one report with a note.
13. Foreman corrects and resubmits.
13. Approve it.
14. Verify approved history/audit information and printable/PDF record.

Expected: submitted/approved records cannot be casually edited as drafts.

## 8. Redline approval

1. Enter a deliberately unauthorized/excess unit.
2. Confirm Redline appears.
3. With GF-redline approval required, verify Foreman cannot self-clear it.
4. Verify GF/authorized leader can review the exception.
5. If an override path is used, verify a reason is required and history is retained.

## 9. JSA - internal form

As Foreman:

1. Open Safety / Morning JSA.
2. Complete a digital/internal JSA.
3. Add crew acknowledgments/signatures.
4. Save it.
5. Confirm appropriate management roles can view it.
6. Confirm unauthorized roles do not gain broader company safety visibility than intended.

## 10. JSA - uploaded paper/company form

1. Use Upload Company JSA.
2. On mobile, use the camera button to photograph two pages.
3. Save/upload both pages.
4. Open the saved JSA inside the app.
5. Confirm both pages appear in order and can be viewed/zoomed on mobile and desktop.
6. Upload a PDF and confirm it opens inside the viewer when supported.
7. Verify JSA remains optional; the app must not globally block work/reporting merely because no JSA exists.

## 11. Storm Mode

1. Owner/Admin/permitted Superintendent activates a storm event.
2. Select only some crews.
3. Create reports from one storm crew and one normal crew.
4. Confirm only selected crews receive storm tagging/banner/context.
5. Filter/report by storm context.
6. Deactivate storm event and confirm normal flow resumes.

## 12. Assistant

- Owner: assistant available.
- Admin: assistant available.
- Owner/Admin: AI assistant available.
- Superintendent/GF/Foreman: AI assistant unavailable by design.
- GF: unavailable.
- Foreman: unavailable.

Ask the assistant how to promote a Foreman, create a job, upload a Price Book, handle a redline and upload a company JSA. Confirm its steps match current screen labels.

## 13. Tenant isolation

This is a release blocker if it fails.

1. Create/use two separate test companies.
2. Company A creates jobs, reports, JSAs, Price Books and attachments.
3. Company B signs in separately.
4. Confirm Company B cannot see, query, open, export, approve, modify or delete Company A data.
5. Repeat for direct-object flows such as attachment/JSA file viewing where possible.

## 14. Mobile usability

On phone, verify:

- no horizontal page overflow on core screens
- buttons are easy to tap
- keyboard does not hide required save/submit controls
- camera capture returns to the app correctly
- JSA multi-page viewer closes cleanly
- Daily Report unit entry works without accidental page resets
- browser back/navigation does not strand the user
- rotation/refresh does not lose already-saved data

## 15. What to record for every bug

Capture:

- role
- user/email alias
- company
- device/browser
- exact screen
- exact action
- expected result
- actual result
- exact error message
- screenshot
- whether refresh/re-login changes it

Do not work around security/tenant-isolation bugs. Stop and record them.

## Release blockers

Treat these as blockers before wider pilot use:

- cross-company data exposure
- unauthorized role promotion/suspension
- Owner governance bypass
- actual contract pricing exposed to Foreman
- submitted/approved report history can be silently changed/deleted
- JSA/attachment files can be opened by another company
- production records disappear or duplicate after packet reconciliation
- backup workflow stops succeeding
- app cannot reliably save/submit from a phone
