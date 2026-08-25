# Overnight Release Test Plan

This release adds company settings and branding, printable daily reports, private report attachments, and dashboard review alerts.

## Before testing the live site

Run these migrations in Supabase SQL Editor in this exact order:

1. `supabase/migrations/20260817_company_settings_branding.sql`
2. `supabase/migrations/20260817_daily_report_attachments.sql`

Each successful migration displays **Success. No rows returned**. Stop and save a screenshot if Supabase reports an error.

After both migrations succeed, wait about two minutes for GitHub Pages, then hard-refresh LineCrew Pro with **Ctrl+F5**.

## Test 1 — Company settings and branding (Admin)

1. Sign in as the company Admin.
2. On the Dashboard, scroll to **Admin Controls**.
3. In **Company Settings**, enter a company display name, email and phone.
4. Keep the default time zone or select the correct one.
5. Pick a brand color.
6. Leave Logo Image URL blank for the first test.
7. Click **Save Company Settings**.
8. Confirm the success message.
9. Confirm the company name changes on the Dashboard and the header color changes.
10. Refresh the browser and confirm both settings remain.

Optional logo test: enter a secure public image URL beginning with `https://`, save, then use **Print / Save PDF** on a daily report.

## Test 2 — Print or save a daily report as PDF

1. Open **Production**.
2. Expand any daily report.
3. Click **Print / Save PDF**.
4. If the browser blocks a pop-up, allow pop-ups for the LineCrew Pro site and click again.
5. Confirm the printable report includes company name, job, work date, Foreman, hours, weather/delay, unit locations, unit codes, quantities, authorization status, and notes.
6. In the browser print dialog, select **Save as PDF** to test PDF output.

Real-world use: an Admin or General Foreman can send a clean daily ticket to payroll, billing, the utility, or the customer without sharing the whole app.

## Test 3 — Private attachments

1. Expand a daily report.
2. Click **Attachments**.
3. Choose a small JPG, PNG, PDF, XLSX, or CSV under 15 MB.
4. Add an optional caption such as `Pole 18 before work`.
5. Click **Upload**.
6. Confirm the file appears in the attachment list.
7. Click **Open** and confirm the private signed link opens.
8. Sign out, sign in again, return to the same report, and confirm the file remains.
9. Test **Delete** on a disposable file.
10. Confirm a Foreman from another contractor company cannot see the report or attachment during multi-company testing.

Real-world use: a Foreman attaches field photos or utility paperwork directly to the daily report; only authenticated members of the same contractor company can open them.

## Test 4 — Review alert

1. Have a Foreman submit a draft daily report.
2. Sign in as a General Foreman or Admin.
3. Open the Dashboard.
4. Confirm **Production Needs Review** shows the number of submitted reports.
5. Click **Review Reports** and confirm Production opens.
6. Approve or return the report.
7. Return to the Dashboard and refresh.
8. Confirm the alert disappears when no submitted reports remain.

## Regression checks

- Create and edit a customer, contract, Price Book, job and daily report.
- Open a Price Book with hundreds of units and search it.
- Import a small Price Book spreadsheet in preview mode.
- Open a utility job package and confirm work-point progress.
- Use browser Back between Dashboard, Jobs and Production.
- Verify Foremen cannot access Admin Controls.
- Verify one contractor company never sees another company's customers, contracts, Price Books, jobs, reports or attachments.

## Expected limitations

- Logo upload is not included yet; this release accepts a secure public logo URL.
- Email/SMS notifications are not included; the review alert is in-app.
- Print output uses the browser print dialog, which supports paper or Save as PDF.
- Billing/subscriptions are intentionally not activated in this release.
