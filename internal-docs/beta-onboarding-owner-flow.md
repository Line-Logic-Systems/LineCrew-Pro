# Platform Owner Beta review flow

New Beta/Pilot website applications appear in the Platform Owner console with company, contact, crew count and submitted time.

- **Approve**: creates the Pilot company, preserves the $0 subscription model, applies a finite Pilot end date, records an audit event and sends the applicant an Admin account invitation.
- **Decline**: marks the application declined and records an audit event. It does not create a company.
- **Browser alerts**: optional owner-side browser notifications can be enabled; the console also shows a pending count badge and refreshes while open.

The application table itself is not available to contractor users or anonymous website visitors.
