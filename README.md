# ora-jev

Ask your Oracle tables questions in plain language, from SQL.

```sql
EXEC ora_jev.set_option('api_key', '<your TypeSafe key>')

SELECT * FROM tickets
 WHERE ora_jev.jev(JSON_OBJECT(*), 'the customer threatens to cancel') = 1;

SELECT subject, ora_jev.jev_prob(JSON_OBJECT(*), 'the customer is angry') AS p
  FROM tickets ORDER BY p DESC FETCH FIRST 20 ROWS ONLY;

SELECT ora_jev.jev_choice(JSON_OBJECT(*), 'which team should handle this?',
                          '["billing","technical","security","sales"]') AS team, COUNT(*)
  FROM tickets GROUP BY ora_jev.jev_choice(JSON_OBJECT(*), 'which team should handle this?',
                                           '["billing","technical","security","sales"]');
```

Each row is judged by [TypeSafe's Jev](https://docs.typesafe.ai), a "System One" model that returns calibrated
probabilities instead of text, or by any server that speaks the same `POST /v1/systemone` API.
Rows are sent in batches of 20 per request, the size pg-jev measured as accurate.

It's the Oracle counterpart of [pg-jev](https://github.com/realZachi/pg-jev) for PostgreSQL, with the same function names.

## Functions

| Function | Returns | Purpose |
|---|---|---|
| `jev(row, condition [, threshold])` | 1 / 0 | Use in `WHERE ... = 1`. Threshold: argument, then the `threshold` setting, then 0.5 |
| `jev_prob(row, condition)` | NUMBER 0..1 | Probability the row satisfies the condition |
| `jev_choice(row, question, options_json)` | VARCHAR2 | The most likely option, e.g. `'["billing","technical"]'` |
| `jev_score(row, question, levels_json)` | NUMBER | Probability-weighted position on ordered levels, 0 .. n-1 |
| `jev_score_norm(row, question, levels_json)` | NUMBER | The same, 0..1 |
| `jev_confidence(row, question, kind, options_json)` | NUMBER | Confidence of a `choice` / `score` answer |
| `jev_eval(row, question, kind, options_json)` | VARCHAR2 (JSON) | The raw answer |
| `jev_table(cursor, question [, kind, options_json])` | rows (`id, value, prob, confidence, answer`) | **Batched**: judge every row a cursor returns, `batch_size` rows per request |
| `warm(query, question [, kind, options_json])` | NUMBER (rows judged) | **Batched** pre-scoring: caches answers so later `jev()`/`jev_prob()` calls on those rows are free |
| `jev_stats()` | VARCHAR2 (JSON) | Rows, cache hits, requests, rows sent, ms, input tokens, estimated cost for this session |
| `jev_cache_clear()`, `jev_version()` | | |
| `set_option(key, value)` | | Session settings, below |

`row` is any JSON text. `JSON_OBJECT(*)` sends the whole row; `JSON_OBJECT('subject' VALUE subject, 'body' VALUE body)`
sends only what the judgment needs, which is cheaper and shares less data.

## Settings

Session level with `ora_jev.set_option(key, value)`; defaults in table `ORA_JEV_SETTINGS`.

| Key | Default | Meaning |
|---|---|---|
| `api_key` | none | Bearer token. **Session only:** never read from a table. Required for `*.typesafe.ai` |
| `api_url` | `https://api.typesafe.ai/v1/systemone` | Any Jev-compatible endpoint (a proxy, a local server, a mock) |
| `model` | `jev-latest` | Pin a version such as `jev-1.13.0` when results feed reports |
| `threshold` | `0.5` | Cut-off for `jev()` |
| `timeout` | `30` | Seconds per request |
| `wallet` | none | `UTL_HTTP` wallet path for https, e.g. `file:/opt/oracle/wallet` |
| `max_rows_per_session` | `0` (off) | Spend guard: refuse calls that would send more than this many rows in the session |
| `batch_size` | `20` | Rows per request for `jev_table` and `warm` (1–100). pg-jev measured accuracy dropping above ~20–25 |

## Install

Requirements: Oracle Database with `UTL_HTTP` and `JSON_OBJECT_T`. Tested on **Oracle AI Database 26ai Free
(23.26.1)**. It uses no 23ai-only features, so 19c should work, but that hasn't been tested yet.

```sql
-- 1. As the schema that will own the package (SQL*Plus or SQLcl):
SQL> @sql/install.sql

-- 2. As a DBA: let that schema reach the endpoint.
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => 'api.typesafe.ai', lower_port => 443, upper_port => 443,
    ace  => xs$ace_type(privilege_list => xs$name_list('connect', 'http'),
                        principal_name => 'YOUR_SCHEMA', principal_type => xs_acl.ptype_db));
END;
/
```

For https, `UTL_HTTP` needs a wallet holding the endpoint's CA certificates
(`orapki wallet create` + `orapki wallet add -trusted_cert`), then `ora_jev.set_option('wallet', 'file:/path')`.

## Test without an API key

`test/mock_jev.py` is a deterministic stand-in for the API (standard-library Python):

```bash
python3 test/mock_jev.py 8788
```
```sql
SQL> DEFINE mock_url = 'http://<host-reachable-from-the-db>:8788/v1/systemone'
SQL> @test/test_mock.sql      -- 18 checks, including batching
```
The schema needs a network ACL for the mock's host and port.

## Batching: three ways to call it

```sql
-- 1. Row by row: simplest; one request per new row.
SELECT * FROM tickets WHERE ora_jev.jev(JSON_OBJECT(*), 'the customer is angry') = 1;

-- 2. Set-based: 20 rows per request. The cursor returns (id, row JSON).
SELECT t.*, r.prob
  FROM TABLE(ora_jev.jev_table(CURSOR(SELECT id, JSON_OBJECT(*) FROM tickets), 'the customer is angry')) r
  JOIN tickets t ON t.id = r.id
 WHERE r.value = '1';

SELECT r.value AS team, COUNT(*)
  FROM TABLE(ora_jev.jev_table(CURSOR(SELECT id, JSON_OBJECT(*) FROM tickets),
                               'which team should handle this?', 'choice', '["billing","technical","sales"]')) r
 GROUP BY r.value;

-- 3. Warm, then query normally: 20 rows per request up front, then every jev() call is a cache hit.
SELECT ora_jev.warm('SELECT JSON_OBJECT(*) FROM tickets', 'the customer is angry') FROM dual;
SELECT * FROM tickets WHERE ora_jev.jev(JSON_OBJECT(*), 'the customer is angry') = 1;
```

In the test suite, 45 rows take 3 requests with `jev_table` or `warm`, against 45 row by row.
`warm` and the later `jev()` call must send identical row JSON (same `JSON_OBJECT(...)` expression) to share the cache.

## How it works

Requests use the shape pg-jev uses: `{"model": ..., "state": {"condition": ..., "rows": [...]},
"questions": {"r0": {...}, "r1": {...}, ...}}`, one question per row, all answered in one call.
Answers are cached for the session by endpoint, model, question, options and row content, so re-running a query,
changing the threshold or sorting by `jev_prob` costs nothing extra.

## Caveats

- **Row data leaves the database** for the configured endpoint. Don't send data you may not share.
  Send only the columns needed, or point `api_url` at a server inside your network.
- Plain `jev()` in a `WHERE` clause is still one request per new row (Oracle has no read-ahead hook for it).
  Use `jev_table` or `warm` for whole tables, and filter with ordinary SQL first.
- Requests run one after another (`UTL_HTTP` is synchronous); batching cuts their number, not their latency.
- Functions are not deterministic, so they can't be used in indexes or virtual columns.
- `estimated_cost_usd` uses Jev 1.13's list price ($0.042 per million input tokens) whatever the endpoint.

## License

MIT. Not affiliated with TypeSafe or Oracle. Jev and TypeSafe are trademarks of their owners; Oracle is a trademark
of Oracle Corporation.
