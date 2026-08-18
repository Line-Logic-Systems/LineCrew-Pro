# LineCrew Assistant Setup and Test Plan

## What works immediately

The Admin-only assistant includes built-in help for company setup, Team roles, Customers, Contracts, Price Books, Jobs, utility job packets, Morning JSA, daily reports, approvals, redlines, pending packets, Storm Mode, reporting, exports and password recovery. It can explain Foreman, General Foreman and Admin workflows to an Admin. If the AI service is not deployed or is unavailable, core answers remain available.

## Enable live AI answers

The browser never stores an OpenAI key. The key belongs only in Supabase Edge Function secrets.

1. Open the Supabase project.
2. Open **Edge Functions**.
3. Create/deploy the function from:
   `supabase/functions/linecrew-assistant/index.ts`
4. Open the function's **Secrets**.
5. Add `OPENAI_API_KEY` with the server API key.
6. Optional: add `OPENAI_MODEL` to override the default model.
7. Confirm JWT verification remains enabled.
8. Deploy the function.

Supabase supplies `SUPABASE_URL` and `SUPABASE_ANON_KEY` to hosted Edge Functions.

## Security checks

1. Sign in as an Admin and confirm **Ask LineCrew Assistant** appears.
2. Sign in as a General Foreman or Foreman and confirm the assistant is hidden.
3. From a non-Admin account, directly invoke the function and confirm it returns HTTP 403.
4. Ask about another contractor and confirm the assistant does not reveal any other company.
5. Inspect `index.html` and confirm it contains no OpenAI secret.
6. Rotate the OpenAI key in Supabase if it is ever exposed.

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
10. Temporarily disable the Edge Function and confirm built-in answers still appear for the role questions.
11. Re-enable the function and confirm live answers return.

## Real-world use

A contractor Admin sees a submitted report with a redline and does not remember the workflow. The Admin opens the assistant, asks what the badge means, receives the exact review steps, and stays inside LineCrew Pro. Company counts sent to the model are scoped to that Admin's authenticated `company_id`; raw Price Book prices, report details, and other tenants are not sent.
