# LineCrew Assistant Setup and Test Plan

## What works immediately

The Owner/Admin-only assistant is an operations coach for the full LineCrew Pro role model. Knowledge release `2026-08-30-live-context-v5` understands Owner, Admin, Superintendent, General Foreman and Foreman responsibilities; role handoffs; company setup and logo upload; Team and GF crew scope; Customers; Contracts; Price Books; Jobs; utility job packets; complete/offline JSA behavior; Daily Reports; Remaining Units; clock-time entry and weekly overtime; equipment; leadership My Time; payroll approval/locking/history; GF review badges and full crew-time review; approvals; redlines; pending packets; billing batches; job closeout; Storm Mode; reporting; company subscription billing; exports; training and password recovery. It also receives a limited snapshot of the current app screen, independently rechecks referenced records through the signed-in Owner/Admin's RLS permissions, and loads relevant read-only company data for jobs, reports, team access, timekeeping, billing and Price Books. If the AI service is not deployed or is unavailable, the matching built-in help remains available.

The live assistant receives the authenticated caller's role, current app page, an allowlisted screen snapshot, company-scoped aggregate counts and only the read-only records relevant to the question. The Edge Function queries those records with the caller's Supabase session, explicit `company_id` filters and existing RLS. It never uses a service-role key, never accepts arbitrary table/query instructions from the browser and never sends attachments, passwords, secrets, free-form company notes or another contractor's context. Company and employee names are treated as untrusted data rather than instructions.

## Enable live AI answers

The browser never stores an OpenAI key. The key belongs only in Supabase Edge Function secrets.

1. Open the Supabase project.
2. Open **Edge Functions**.
3. Create/deploy the function from:
   `supabase/functions/linecrew-assistant/index.ts`
4. Open the function's **Secrets**.
5. Add `OPENAI_API_KEY` with the server API key.
6. Optional: add `OPENAI_MODEL_FAST` for ordinary how-to questions. If omitted, the existing `OPENAI_MODEL` value is used, then `gpt-5-mini`.
7. Optional: add `OPENAI_MODEL_REASONING` for complex diagnosis. The default is `gpt-5.6-terra` with medium reasoning. If that model is unavailable to the API project, the request safely retries the fast model.
8. Optional: add `CORS_ALLOWED_ORIGINS` as a comma-separated list of exact development app origins. Production `https://app.linecrewpro.com` is always allowed. Do not add the public marketing site or wildcard origins.
9. Confirm platform JWT verification is disabled. The handler requires the
   caller's `Authorization` header and validates it with `auth.getUser()` so it
   supports Supabase's asymmetric JWT signing-key rotation without trusting an
   unverified caller.
10. Deploy the function with `assistant-logic.mjs` and the shared API-key helper.

Supabase supplies `SUPABASE_URL` and the named `SUPABASE_PUBLISHABLE_KEYS` JSON object to hosted Edge Functions. The assistant reads the `default` publishable key and does not depend on the legacy `anon` key.

## Security checks

1. Sign in as an Admin and confirm **Ask LineCrew Assistant** appears.
2. Sign in as a General Foreman or Foreman and confirm the assistant is hidden.
3. From a non-Admin account, directly invoke the function and confirm it returns HTTP 403.
4. Ask about another contractor and confirm the assistant does not reveal any other company.
5. Inspect `index.html` and confirm it contains no OpenAI secret.
6. Rotate the OpenAI key in Supabase if it is ever exposed.
7. Send a browser request from an unapproved origin and confirm the function returns HTTP 403 without contacting the AI provider.

## Functional checks

1. As Admin, open the assistant.
2. Use each quick question and confirm a useful answer appears.
3. Ask: “How do I import a Price Book?”
4. Ask: “Why would a report show Pending Packet?”
5. Ask: “What should I check before approving a redline?”
6. Ask: “How do I promote a Foreman to General Foreman?”
7. Ask: “How can I add another Admin?”
8. Ask: “How does a Foreman complete the Morning JSA?”
9. Ask: “How do I assign only some crews to Storm Mode?”
10. Ask: “Who handles each step from a Foreman’s Daily Report through job closeout?”
11. Ask: “What can a Superintendent do if Price Books permission is disabled?”
12. Ask: “What is the difference between a production Billing Batch and our LineCrew Pro Stripe subscription?”
13. Ask: “How do I review time before payroll export?” Confirm the answer requires company/payroll verification and does not invent wage rules.
14. Ask: “Can a Foreman save a JSA with no service?” Confirm it explains the JSA-only offline queue and does not claim Daily Reports queue offline.
15. Ask: “What does the number on the GF Production tile mean?” Confirm it describes the in-app review count and does not promise background phone push notifications.
16. Ask: “How does a Foreman check Remaining Units?” Confirm it says to search by Work Point and does not expose contract pricing.
17. Ask: “How do weekly overtime and the company workweek work?” Confirm it explains Start/Stop/Lunch calculation without inventing payroll law.
18. Ask: “How do I add equipment and make it fill Crew Time?” Confirm it limits roster/default assignment management to Owner/Admin.
19. Ask an ambiguous question such as “Why is this stuck?” Confirm it asks one focused question or offers the two most likely paths rather than inventing a record status.
20. Open a specific Job and ask “What am I looking at?” Confirm the answer names only the selected, server-verified job.
21. On Production, ask “Which reports are waiting for approval?” Confirm the returned report names/statuses match the signed-in company and no other company.
22. Ask “Why can't this Foreman see the selected job?” Confirm the answer checks active status and saved assignments using live data and does not offer to broaden access.
23. Ask “Is this job ready for final billing?” Confirm it uses the reasoning route, checks the available job/report/billing snapshot and clearly identifies anything it cannot verify.
24. Temporarily disable the Edge Function and confirm built-in answers still appear for the role questions.
25. Re-enable the function and confirm live answers return.

## Keeping knowledge current

Any release that changes a role, permission, screen label, workflow, offline behavior, notification behavior, training availability or payroll/billing behavior must update both `supabase/functions/linecrew-assistant/index.ts` and `assistantBuiltInHelp` in `index.html`. Increment `KNOWLEDGE_VERSION` and add or update a role scenario in `scripts/validate-assistant-knowledge.mjs`. Production readiness CI runs that validator so stale or contradictory help blocks the release.

## Real-world use

A contractor Admin sees a submitted report and asks why it is still waiting. The app supplies only the visible screen and selected record IDs. The Edge Function re-reads that report, its job and the relevant review status through the Admin's authenticated RLS session, then routes the diagnostic question to the balanced reasoning model. The assistant explains the live condition and exact next checks but cannot approve, return or edit the report.
