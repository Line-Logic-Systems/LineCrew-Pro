begin;

create index assistant_memories_created_by_idx
  on public.assistant_memories (created_by);
create index assistant_memories_completed_by_idx
  on public.assistant_memories (completed_by)
  where completed_by is not null;
create index assistant_memories_removed_by_idx
  on public.assistant_memories (removed_by)
  where removed_by is not null;

commit;
