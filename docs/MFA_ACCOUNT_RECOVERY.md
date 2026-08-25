# Privileged MFA Account Recovery

This is an internal break-glass procedure for a LineCrew Pro Owner, Admin or platform-support user who has lost every verified authenticator. Do not publish this document and do not use it merely for convenience.

## Normal prevention

- Keep the primary TOTP factor in a password manager or authenticator with encrypted backup.
- Enroll a second TOTP factor on a different protected device when the app supports factor management.
- Never disable the server-side AAL2 requirement to recover one user.

## Required approvals

1. Open a support incident and record the requester, company, email, time and reason.
2. Verify the request through two independent channels already on file. At minimum, confirm the company support email and support phone; do not accept new contact information supplied only in the recovery request.
3. Require approval from the LineCrew Pro platform owner. The requester cannot approve their own reset.
4. Confirm the target Supabase project before acting. Production is `ldgkyxuozbozgkvwzadg`; Test is `yvuxrqrdprquxypiffpa`.

## Reset procedure

1. In Supabase Auth, locate the user by their exact saved email and copy the immutable user UUID.
2. List the user's MFA factors and copy the exact verified factor ID being removed.
3. Use the Supabase Auth Admin `deleteFactor` operation with that user UUID and factor ID. This is a server-side administrative action and must never be performed with a browser publishable key.
4. Record an `mfa_factor_reset` event in `platform_owner_audit_events`. Include the incident number and factor ID in `before_state`; never store a TOTP secret or one-time code.
5. Tell the user that all active sessions were revoked. Have them sign in with their existing password, enroll a new authenticator, verify the six-digit code and confirm the session reaches AAL2.
6. Confirm the user can open the app and, if applicable, Company Billing. Close the support incident only after successful re-enrollment.

Supabase documents that deleting a verified factor logs the user out of active sessions. A normal user can unenroll a verified factor only while already authenticated at AAL2, which is why this administrative path is reserved for true device loss.

## Safety stops

- Stop if the email, company or user UUID does not match the saved account records.
- Stop if the target project is unclear.
- Stop if identity cannot be verified through two existing channels.
- Never delete every factor for more than one user in a single operation.
- Never share, request or record a TOTP seed, QR code or six-digit code.

## Post-incident review

- Confirm exactly one audit event exists for the reset.
- Review Auth logs for unusual sign-ins before and after the request.
- If compromise is suspected, reset the password, revoke sessions and review role/company changes in addition to replacing MFA.
