import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const manifestUrl = new URL('./approved-rpc-columns.json', import.meta.url);
const approved = JSON.parse(readFileSync(manifestUrl, 'utf8'));
const databaseUrl = process.env.LINECREW_TEST_DATABASE_URL;

if (!databaseUrl) {
  throw new Error('LINECREW_TEST_DATABASE_URL is required (test project only).');
}

const names = Object.keys(approved).map((name) => `'${name}'`).join(',');
const sql = `
select json_object_agg(grouped.function_name, grouped.signatures order by grouped.function_name)
from (
  select signature.function_name,
    json_agg(signature.result_columns order by signature.function_oid) as signatures
  from (
    select p.oid as function_oid, p.proname as function_name,
      case when pg_get_function_result(p.oid) = 'void' then '[]'::json
        else coalesce((
          select json_agg(argument.argument_name order by argument.ordinality)
          from unnest(p.proallargtypes, p.proargmodes, p.proargnames)
            with ordinality argument(argument_type, argument_mode, argument_name, ordinality)
          where argument.argument_mode in ('o', 't')
        ), '[]'::json)
      end as result_columns
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (${names})
  ) signature
  group by signature.function_name
) grouped;
`;

const raw = execFileSync('psql', [databaseUrl, '-XAt', '-c', sql], {
  encoding: 'utf8',
  stdio: ['ignore', 'pipe', 'inherit']
}).trim();
const actual = JSON.parse(raw || '{}');

for (const [functionName, approvedColumns] of Object.entries(approved)) {
  if (!(functionName in actual)) throw new Error(`Missing RPC: ${functionName}`);
  if (actual[functionName].length !== 1) {
    throw new Error(`${functionName} has ${actual[functionName].length} overloads; expected exactly one.`);
  }
  if (JSON.stringify(actual[functionName][0]) !== JSON.stringify(approvedColumns)) {
    throw new Error(`${functionName} signature mismatch\nexpected ${JSON.stringify(approvedColumns)}\nactual   ${JSON.stringify(actual[functionName][0])}`);
  }
}

console.log(`Utility RPC signatures match ${manifestUrl.pathname}.`);
