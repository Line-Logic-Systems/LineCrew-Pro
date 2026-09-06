-- Runtime parity matrix for the shared Utility Portal visibility predicate.
-- Run after applying the Utility Portal migrations to the isolated test DB.
do $test$
declare
  candidate record;
  reasons text[];
  expected_visible boolean;
  test_now timestamptz := now();
begin
  for candidate in
    select contract_active, starts_later, ended, grant_status,
           grant_expiry, company_flag, global_flag, entitlement
    from unnest(array[false, true, null::boolean]) as ca(contract_active)
    cross join unnest(array[false, true]) as sl(starts_later)
    cross join unnest(array[false, true]) as ed(ended)
    cross join unnest(array['active', 'revoked', 'expired']) as gs(grant_status)
    cross join unnest(array['none', 'past', 'exact', 'future']) as ge(grant_expiry)
    cross join unnest(array[false, true]) as cf(company_flag)
    cross join unnest(array[false, true]) as gf(global_flag)
    cross join unnest(array[false, true, null::boolean]) as en(entitlement)
  loop
    reasons := public.utility_visibility_hidden_reasons(
      candidate.contract_active,
      case when candidate.starts_later then current_date + 1 else null end,
      case when candidate.ended then current_date - 1 else null end,
      candidate.grant_status,
      case candidate.grant_expiry
        when 'past' then test_now - interval '1 second'
        when 'exact' then test_now
        when 'future' then test_now + interval '1 second'
        else null
      end,
      candidate.company_flag,
      candidate.global_flag,
      candidate.entitlement,
      test_now, current_date
    );
    expected_visible := candidate.contract_active is true
      and not candidate.starts_later
      and not candidate.ended
      and candidate.grant_status = 'active'
      and candidate.grant_expiry in ('none', 'future')
      and candidate.company_flag
      and candidate.global_flag
      and candidate.entitlement is true;
    if (cardinality(reasons) = 0) is distinct from expected_visible then
      raise exception 'Utility visibility parity failure for %', row_to_json(candidate);
    end if;
  end loop;
end;
$test$;
