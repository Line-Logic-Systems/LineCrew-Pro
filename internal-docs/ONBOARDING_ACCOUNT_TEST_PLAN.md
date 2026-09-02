# Onboarding and Account Recovery Test Plan

## Required migration

Run `supabase/migrations/archive/20260817_profile_self_service.sql` in Supabase SQL Editor before testing profile editing.

Expected result: **Success. No rows returned.**

## Admin Controls layout

1. Sign in as Admin.
2. Confirm **Admin Controls** is collapsed on the Dashboard.
3. Open it and confirm Company Settings and Redline Approval are present.
4. Confirm the Brand Color field appears as a color picker instead of a thin line.
5. Close Admin Controls and confirm the Dashboard remains compact.

## Company setup checklist

1. Sign in as Admin.
2. Confirm **Company Setup Progress** lists six steps.
3. In a new company, confirm incomplete steps have navigation buttons.
4. Add a team member, customer, contract, Price Book, job and daily report.
5. Return to Dashboard after each step and confirm progress changes.
6. Confirm Foremen and General Foremen do not see the Admin setup checklist.

## Edit My Profile

1. On Dashboard, click **Edit My Profile**.
2. Change the display name and save.
3. Confirm the name updates immediately.
4. Refresh and confirm it remains changed.
5. Create a new daily report and confirm the Foreman name auto-populates with the updated name.
6. Confirm a user cannot change another member's name through this function.

## Forgot password

1. Sign out.
2. Enter the account email on the Sign In card.
3. Click **Forgot Password**.
4. Confirm Supabase sends a recovery email.
5. Open the recovery link.
6. Confirm LineCrew Pro shows **Choose a New Password**.
7. Enter matching passwords with at least eight characters.
8. Save and confirm the user is signed in.
9. Sign out and sign in again with the new password.

## Real-world use

A contractor can onboard itself without support calls. The Admin sees what must be configured before field production begins. Employees can correct their own displayed names, and forgotten passwords no longer require the software owner to intervene.
