-- Reverse order: 182620, 134013, 071452, 070834, 064624, 064002, 060001, 055947, 055940.
drop trigger if exists linecrew_referenced_contract_company_move_block on public.contracts;
drop function if exists public.linecrew_block_referenced_contract_company_move();
drop trigger if exists linecrew_job_contract_company_match on public.jobs;
drop function if exists public.linecrew_enforce_job_contract_company_match();
