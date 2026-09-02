-- Index the foreign keys on utility_packet_unit_aliases.
--
-- The table added in #399 carries three foreign keys with no index behind them:
-- contract_id, created_by and updated_by. Its existing composite index
-- (company_id, contract_id, normalized_code) serves the lookup the matcher
-- performs, but only covers company_id as a leading column, so it does nothing
-- for a scan on contract_id alone or on either actor column.
--
-- The table holds a handful of rows today, so this is not a query-speed problem yet.
-- It matters for the cascades: deleting a contract, or a user leaving and their
-- auth row being removed, forces a sequential scan per referencing row to prove
-- the constraint. The repository already treats this as standard practice --
-- see add_foreign_key_indexes, add_missing_foreign_key_indexes,
-- index_admin_time_roster_foreign_key and index_assistant_memory_foreign_keys --
-- and this table was simply missed when it was written.

create index if not exists utility_packet_unit_aliases_contract_id_idx
  on public.utility_packet_unit_aliases (contract_id);

create index if not exists utility_packet_unit_aliases_created_by_idx
  on public.utility_packet_unit_aliases (created_by);

create index if not exists utility_packet_unit_aliases_updated_by_idx
  on public.utility_packet_unit_aliases (updated_by);
