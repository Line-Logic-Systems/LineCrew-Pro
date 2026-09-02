-- Let a reviewer return an already-approved Daily Report.
--
-- return_daily_report only matched status = 'submitted', and no other function
-- moves a report out of 'approved'. So once a report was approved, a mistake
-- found afterwards had no route back: the report was stuck forward, and the
-- only remedy was editing the row directly.
--
-- Returning now accepts 'approved' as well as 'submitted'. The report goes to
-- 'draft', where the existing content-edit guards (which require draft) already
-- let the Foreman correct it and resubmit through the normal path.
--
-- Two related gaps are closed at the same time:
--
--   reviewed_by was never set. reviewed_at and review_notes were written but
--   the actor was not, so a returned report recorded when and why but not who.
--
--   approved_by and approved_at survived the return, leaving a report sitting
--   in draft while still naming an approver. Those are cleared so the row does
--   not claim an approval that has been withdrawn.
--
-- The audit trail needs no change: record_daily_report_audit_event already
-- records any status change to 'draft' as a 'returned' event carrying the
-- actor, their role and the review notes, so approved -> draft is captured
-- exactly like submitted -> draft.
--
-- Billing is deliberately not consulted. A report that has already been pulled
-- into a billing batch can still be returned; correcting the field record is
-- treated as more important than protecting a batch, and the withdrawal is
-- visible in the report's audit history.

create or replace function public.return_daily_report(
  p_report_id uuid,
  p_review_notes text
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not public.can_review_daily_reports() then
    raise exception 'You do not have permission to return reports';
  end if;

  if nullif(trim(p_review_notes), '') is null then
    raise exception 'Review notes are required when returning a report';
  end if;

  update public.daily_reports
  set status = 'draft',
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      review_notes = trim(p_review_notes),
      approved_by = null,
      approved_at = null,
      updated_at = now()
  where id = p_report_id
    and company_id = public.my_company_id()
    and status in ('submitted', 'approved');

  if not found then
    raise exception 'Report not found or cannot be returned';
  end if;
end;
$function$;

revoke all on function public.return_daily_report(uuid, text)
  from public, anon;
grant execute on function public.return_daily_report(uuid, text)
  to authenticated;

comment on function public.return_daily_report(uuid, text) is
  'Returns a submitted or approved Daily Report to draft for correction, recording the reviewer and clearing any withdrawn approval. The audit trigger records a returned event with the actor and notes.';

notify pgrst, 'reload schema';
