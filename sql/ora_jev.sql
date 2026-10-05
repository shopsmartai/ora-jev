-- ora-jev: plain-language judgments in Oracle SQL, answered by TypeSafe's Jev
-- or any Jev-compatible endpoint (POST /v1/systemone).
--
--   EXEC ora_jev.set_option('api_key', '<your TypeSafe key>')
--   SELECT * FROM tickets WHERE ora_jev.jev(JSON_OBJECT(*), 'the customer is angry') = 1;
--
-- Row data is sent to the configured endpoint. Needs a network ACL for its host
-- and, for https, a wallet. See README.md.

BEGIN EXECUTE IMMEDIATE 'CREATE TABLE ora_jev_settings (k VARCHAR2(40) PRIMARY KEY, v VARCHAR2(1000))';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF; END;
/

-- result types for jev_table(); created once, kept on reinstall (types with dependents can't be replaced)
BEGIN EXECUTE IMMEDIATE 'CREATE TYPE ora_jev_result AS OBJECT (
  id VARCHAR2(4000), value VARCHAR2(4000), prob NUMBER, confidence NUMBER, answer VARCHAR2(4000))';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'CREATE TYPE ora_jev_results AS TABLE OF ora_jev_result';
EXCEPTION WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF; END;
/

MERGE INTO ora_jev_settings t USING (
  SELECT 'api_url' k, 'https://api.typesafe.ai/v1/systemone' v FROM dual UNION ALL
  SELECT 'model', 'jev-latest' FROM dual UNION ALL
  SELECT 'threshold', '0.5' FROM dual UNION ALL
  SELECT 'timeout', '30' FROM dual UNION ALL
  SELECT 'wallet', '' FROM dual UNION ALL
  SELECT 'max_rows_per_session', '0' FROM dual UNION ALL    -- 0 = no limit; a spend guard for shared databases
  SELECT 'batch_size', '20' FROM dual) s   -- rows per request; pg-jev measured accuracy dropping above ~20-25
ON (t.k = s.k) WHEN NOT MATCHED THEN INSERT (k, v) VALUES (s.k, s.v);
COMMIT;

CREATE OR REPLACE PACKAGE ora_jev AUTHID DEFINER AS
  c_version CONSTANT VARCHAR2(10) := '0.2.0';

  FUNCTION jev       (p_row IN VARCHAR2, p_condition IN VARCHAR2, p_threshold IN NUMBER DEFAULT NULL) RETURN NUMBER;
  FUNCTION jev_prob  (p_row IN VARCHAR2, p_condition IN VARCHAR2) RETURN NUMBER;
  FUNCTION jev_choice(p_row IN VARCHAR2, p_question IN VARCHAR2, p_options IN VARCHAR2) RETURN VARCHAR2;
  FUNCTION jev_score (p_row IN VARCHAR2, p_question IN VARCHAR2, p_levels IN VARCHAR2) RETURN NUMBER;
  FUNCTION jev_score_norm(p_row IN VARCHAR2, p_question IN VARCHAR2, p_levels IN VARCHAR2) RETURN NUMBER;
  FUNCTION jev_confidence(p_row IN VARCHAR2, p_question IN VARCHAR2, p_kind IN VARCHAR2, p_options IN VARCHAR2) RETURN NUMBER;
  FUNCTION jev_eval  (p_row IN VARCHAR2, p_question IN VARCHAR2, p_kind IN VARCHAR2 DEFAULT 'noul',
                      p_options IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2;
  FUNCTION jev_stats RETURN VARCHAR2;
  PROCEDURE jev_cache_clear;
  FUNCTION jev_version RETURN VARCHAR2;
  -- Batched, set-based: judge every row a cursor returns, batch_size rows per request.
  -- The cursor must return two columns: an id and the row as JSON text.
  --   SELECT * FROM TABLE(ora_jev.jev_table(CURSOR(SELECT id, JSON_OBJECT(*) FROM t), 'condition'))
  FUNCTION jev_table(p_rows IN SYS_REFCURSOR, p_question IN VARCHAR2, p_kind IN VARCHAR2 DEFAULT 'noul',
                     p_options IN VARCHAR2 DEFAULT NULL) RETURN ora_jev_results PIPELINED;
  -- Batched pre-scoring: run a query returning one column (the row as JSON) and cache every answer,
  -- so ordinary jev()/jev_prob() calls on those rows are then free. Returns rows judged.
  FUNCTION warm(p_query IN VARCHAR2, p_question IN VARCHAR2, p_kind IN VARCHAR2 DEFAULT 'noul',
                p_options IN VARCHAR2 DEFAULT NULL) RETURN NUMBER;

  -- session-level settings: api_key, api_url, model, threshold, timeout, wallet, max_rows_per_session, batch_size
  PROCEDURE set_option(p_key IN VARCHAR2, p_value IN VARCHAR2);
END ora_jev;
/

CREATE OR REPLACE PACKAGE BODY ora_jev AS
  TYPE t_cache IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(64);
  TYPE t_opts  IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(40);
  TYPE t_strs  IS TABLE OF VARCHAR2(4000) INDEX BY PLS_INTEGER;
  g_cache t_cache;
  g_opts  t_opts;
  g_requests NUMBER := 0; g_cache_hits NUMBER := 0; g_rows NUMBER := 0; g_http_ms NUMBER := 0;
  g_tokens NUMBER := 0; g_errors NUMBER := 0; g_api_rows NUMBER := 0;

  FUNCTION opt(p_key IN VARCHAR2) RETURN VARCHAR2 IS v VARCHAR2(1000);
  BEGIN
    IF g_opts.EXISTS(p_key) THEN RETURN g_opts(p_key); END IF;
    IF p_key = 'api_key' THEN RETURN NULL; END IF;     -- keys are never read from a table
    SELECT v INTO v FROM ora_jev_settings WHERE k = p_key;
    RETURN v;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL;
  END;

  FUNCTION num(p_key IN VARCHAR2) RETURN NUMBER IS BEGIN RETURN TO_NUMBER(opt(p_key), '999999990.99999'); END;

  PROCEDURE set_option(p_key IN VARCHAR2, p_value IN VARCHAR2) IS
  BEGIN
    IF p_key NOT IN ('api_key', 'api_url', 'model', 'threshold', 'timeout', 'wallet', 'max_rows_per_session', 'batch_size') THEN
      RAISE_APPLICATION_ERROR(-20100, 'ora_jev: unknown option ' || p_key);
    END IF;
    g_opts(p_key) := p_value;
  END;

  FUNCTION opts_array(p_options IN VARCHAR2) RETURN JSON_ARRAY_T IS
  BEGIN
    RETURN JSON_ARRAY_T.parse(p_options);
  EXCEPTION WHEN OTHERS THEN
    RAISE_APPLICATION_ERROR(-20100, 'ora_jev: options must be a JSON array of strings, e.g. ''["low","high"]''');
  END;

  -- One request in the shape TypeSafe's Jev API (and pg-jev) uses: all rows in one state,
  -- one question per row (r0 .. rN), answered in parallel by the model.
  FUNCTION http_batch(p_rows IN t_strs, p_question IN VARCHAR2, p_kind IN VARCHAR2, p_options IN VARCHAR2) RETURN t_strs IS
    body JSON_OBJECT_T := JSON_OBJECT_T(); state JSON_OBJECT_T := JSON_OBJECT_T(); rows_a JSON_ARRAY_T := JSON_ARRAY_T();
    qs JSON_OBJECT_T := JSON_OBJECT_T(); q JSON_OBJECT_T; crit JSON_OBJECT_T; opts JSON_ARRAY_T; ref VARCHAR2(20);
    req UTL_HTTP.REQ; resp UTL_HTTP.RESP; payload CLOB; answer CLOB; buf VARCHAR2(32767); t0 NUMBER := DBMS_UTILITY.GET_TIME;
    out JSON_OBJECT_T; usage JSON_OBJECT_T; err JSON_OBJECT_T; answers JSON_OBJECT_T; msg VARCHAR2(1500); res t_strs;
  BEGIN
    IF opt('api_key') IS NULL AND opt('api_url') LIKE '%typesafe.ai%' THEN
      RAISE_APPLICATION_ERROR(-20103, 'ora_jev: no API key. Run EXEC ora_jev.set_option(''api_key'', ''...'') in this session.');
    END IF;
    IF p_kind <> 'noul' THEN opts := opts_array(p_options); END IF;
    FOR i IN 0 .. p_rows.COUNT - 1 LOOP
      BEGIN rows_a.append(JSON_OBJECT_T.parse(p_rows(i))); EXCEPTION WHEN OTHERS THEN rows_a.append(p_rows(i)); END;
      ref := 'rows[' || i || ']'; q := JSON_OBJECT_T();
      IF p_kind = 'noul' THEN
        q.put('type', 'noul'); q.put('instructions', 'Does the record `' || ref || '` satisfy the condition stated in `condition`?');
      ELSIF p_kind = 'score' THEN
        q.put('type', 'score'); q.put('instructions', 'Rate the record `' || ref || '`: ' || p_question); q.put('criteria', opts);
      ELSE
        crit := JSON_OBJECT_T();
        FOR j IN 0 .. opts.get_size - 1 LOOP crit.put_null(opts.get_string(j)); END LOOP;
        q.put('type', 'choice'); q.put('instructions', 'For the record `' || ref || '`: ' || p_question); q.put('criteria', crit);
      END IF;
      qs.put('r' || i, q);
    END LOOP;
    IF p_kind = 'noul' THEN state.put('condition', p_question); END IF;
    state.put('rows', rows_a);
    body.put('model', opt('model')); body.put('state', state); body.put('questions', qs);
    payload := body.to_clob;

    IF opt('wallet') IS NOT NULL THEN UTL_HTTP.SET_WALLET(opt('wallet')); END IF;
    UTL_HTTP.SET_TRANSFER_TIMEOUT(num('timeout'));
    req := UTL_HTTP.BEGIN_REQUEST(opt('api_url'), 'POST', 'HTTP/1.1');
    UTL_HTTP.SET_HEADER(req, 'Content-Type', 'application/json');
    UTL_HTTP.SET_HEADER(req, 'Content-Length', DBMS_LOB.GETLENGTH(payload));
    IF opt('api_key') IS NOT NULL THEN UTL_HTTP.SET_HEADER(req, 'Authorization', 'Bearer ' || opt('api_key')); END IF;
    UTL_HTTP.WRITE_TEXT(req, payload);
    resp := UTL_HTTP.GET_RESPONSE(req);
    DBMS_LOB.CREATETEMPORARY(answer, TRUE);
    BEGIN
      LOOP UTL_HTTP.READ_TEXT(resp, buf, 32767); DBMS_LOB.WRITEAPPEND(answer, LENGTH(buf), buf); END LOOP;
    EXCEPTION WHEN UTL_HTTP.END_OF_BODY THEN UTL_HTTP.END_RESPONSE(resp);
    END;
    g_requests := g_requests + 1; g_api_rows := g_api_rows + p_rows.COUNT;
    g_http_ms := g_http_ms + (DBMS_UTILITY.GET_TIME - t0) * 10;
    IF resp.status_code <> 200 THEN
      g_errors := g_errors + 1;
      BEGIN
        out := JSON_OBJECT_T.parse(answer); err := out.get_object('error');
        msg := CASE WHEN err IS NOT NULL THEN err.get_string('message') END;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
      RAISE_APPLICATION_ERROR(-20102, 'ora_jev: ' || opt('api_url') || ' returned HTTP ' || resp.status_code || ': ' ||
        SUBSTR(NVL(msg, DBMS_LOB.SUBSTR(answer, 300)), 1, 1500));
    END IF;
    out := JSON_OBJECT_T.parse(answer);
    usage := out.get_object('usage');
    IF usage IS NOT NULL THEN g_tokens := g_tokens + NVL(usage.get_number('input_tokens'), 0); END IF;
    answers := out.get_object('answers');
    FOR i IN 0 .. p_rows.COUNT - 1 LOOP
      IF answers IS NULL OR answers.get_object('r' || i) IS NULL THEN
        g_errors := g_errors + 1;
        RAISE_APPLICATION_ERROR(-20105, 'ora_jev: the response is missing the answer for row ' || i);
      END IF;
      res(i) := answers.get_object('r' || i).to_string;
    END LOOP;
    RETURN res;
  END;

  FUNCTION ckey(p_row IN VARCHAR2, p_question IN VARCHAR2, p_kind IN VARCHAR2, p_options IN VARCHAR2) RETURN VARCHAR2 IS
    k VARCHAR2(64); url VARCHAR2(1000) := opt('api_url'); model VARCHAR2(100) := opt('model');
  BEGIN
    SELECT RAWTOHEX(STANDARD_HASH(url || '|' || model || '|' || p_kind || '|' || p_question || '|' || p_options || '|' || p_row,
                                  'SHA256')) INTO k FROM dual;
    RETURN k;
  END;

  -- Answer many rows: cached rows are free, the rest go out batch_size rows per request.
  FUNCTION eval_many(p_rows IN t_strs, p_question IN VARCHAR2, p_kind IN VARCHAR2, p_options IN VARCHAR2) RETURN t_strs IS
    keys t_strs; res t_strs; miss_idx t_strs; batch t_strs; got t_strs; n_miss PLS_INTEGER := 0; bs PLS_INTEGER;
    start_i PLS_INTEGER; n PLS_INTEGER;
  BEGIN
    IF p_kind NOT IN ('noul', 'choice', 'score') THEN
      RAISE_APPLICATION_ERROR(-20100, 'ora_jev: kind must be noul, choice or score');
    END IF;
    IF p_kind <> 'noul' AND p_options IS NULL THEN
      RAISE_APPLICATION_ERROR(-20100, 'ora_jev: ' || p_kind || ' needs a JSON array of options');
    END IF;
    bs := GREATEST(1, LEAST(NVL(num('batch_size'), 20), 100));
    FOR i IN 0 .. p_rows.COUNT - 1 LOOP
      g_rows := g_rows + 1;
      keys(i) := ckey(p_rows(i), p_question, p_kind, p_options);
      IF g_cache.EXISTS(keys(i)) THEN
        g_cache_hits := g_cache_hits + 1; res(i) := g_cache(keys(i));
      ELSE
        miss_idx(n_miss) := TO_CHAR(i); n_miss := n_miss + 1;
      END IF;
    END LOOP;
    IF n_miss > 0 AND num('max_rows_per_session') > 0 AND g_api_rows + n_miss > num('max_rows_per_session') THEN
      RAISE_APPLICATION_ERROR(-20104, 'ora_jev: this would send ' || (g_api_rows + n_miss) || ' rows, over max_rows_per_session (' ||
        opt('max_rows_per_session') || '). Raise it with set_option or narrow the query with ordinary SQL first.');
    END IF;
    start_i := 0;
    WHILE start_i < n_miss LOOP
      batch.DELETE; n := LEAST(bs, n_miss - start_i);
      FOR j IN 0 .. n - 1 LOOP batch(j) := p_rows(TO_NUMBER(miss_idx(start_i + j))); END LOOP;
      got := http_batch(batch, p_question, p_kind, p_options);
      FOR j IN 0 .. n - 1 LOOP
        res(TO_NUMBER(miss_idx(start_i + j))) := got(j);
        g_cache(keys(TO_NUMBER(miss_idx(start_i + j)))) := got(j);
      END LOOP;
      start_i := start_i + n;
    END LOOP;
    RETURN res;
  END;

  FUNCTION jev_eval(p_row IN VARCHAR2, p_question IN VARCHAR2, p_kind IN VARCHAR2 DEFAULT 'noul',
                    p_options IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    one t_strs; res t_strs;
  BEGIN
    one(0) := p_row;
    res := eval_many(one, p_question, p_kind, p_options);
    RETURN res(0);
  END;

  FUNCTION jev_table(p_rows IN SYS_REFCURSOR, p_question IN VARCHAR2, p_kind IN VARCHAR2 DEFAULT 'noul',
                     p_options IN VARCHAR2 DEFAULT NULL) RETURN ora_jev_results PIPELINED IS
    TYPE t_tab IS TABLE OF VARCHAR2(4000);
    ids t_tab; rws t_tab; chunk t_strs; got t_strs; a JSON_OBJECT_T; v VARCHAR2(4000); p NUMBER;
    thr NUMBER := COALESCE(num('threshold'), 0.5);
  BEGIN
    LOOP
      FETCH p_rows BULK COLLECT INTO ids, rws LIMIT 200;
      EXIT WHEN ids.COUNT = 0;
      chunk.DELETE;
      FOR i IN 1 .. rws.COUNT LOOP chunk(i - 1) := rws(i); END LOOP;
      got := eval_many(chunk, p_question, p_kind, p_options);
      FOR i IN 1 .. ids.COUNT LOOP
        a := JSON_OBJECT_T.parse(got(i - 1));
        IF p_kind = 'noul' THEN
          p := a.get_number('noul'); v := CASE WHEN p >= thr THEN '1' ELSE '0' END;
          PIPE ROW (ora_jev_result(ids(i), v, p, NULL, got(i - 1)));
        ELSIF p_kind = 'choice' THEN
          PIPE ROW (ora_jev_result(ids(i), a.get_string('choice'), a.get_number('confidence'), a.get_number('confidence'), got(i - 1)));
        ELSE
          PIPE ROW (ora_jev_result(ids(i), TO_CHAR(a.get_number('score')), NULL, a.get_number('confidence'), got(i - 1)));
        END IF;
      END LOOP;
      EXIT WHEN ids.COUNT < 200;
    END LOOP;
    CLOSE p_rows;
    RETURN;
  END;

  FUNCTION warm(p_query IN VARCHAR2, p_question IN VARCHAR2, p_kind IN VARCHAR2 DEFAULT 'noul',
                p_options IN VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
    TYPE t_tab IS TABLE OF VARCHAR2(4000);
    c SYS_REFCURSOR; rws t_tab; chunk t_strs; got t_strs; total NUMBER := 0;
  BEGIN
    OPEN c FOR p_query;
    LOOP
      FETCH c BULK COLLECT INTO rws LIMIT 200;
      EXIT WHEN rws.COUNT = 0;
      chunk.DELETE;
      FOR i IN 1 .. rws.COUNT LOOP chunk(i - 1) := rws(i); END LOOP;
      got := eval_many(chunk, p_question, p_kind, p_options);
      total := total + rws.COUNT;
      EXIT WHEN rws.COUNT < 200;
    END LOOP;
    CLOSE c;
    RETURN total;
  END;

  FUNCTION jev_prob(p_row IN VARCHAR2, p_condition IN VARCHAR2) RETURN NUMBER IS
  BEGIN RETURN JSON_OBJECT_T.parse(jev_eval(p_row, p_condition, 'noul')).get_number('noul'); END;

  FUNCTION jev(p_row IN VARCHAR2, p_condition IN VARCHAR2, p_threshold IN NUMBER DEFAULT NULL) RETURN NUMBER IS
  BEGIN RETURN CASE WHEN jev_prob(p_row, p_condition) >= COALESCE(p_threshold, num('threshold'), 0.5) THEN 1 ELSE 0 END; END;

  FUNCTION jev_choice(p_row IN VARCHAR2, p_question IN VARCHAR2, p_options IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN RETURN JSON_OBJECT_T.parse(jev_eval(p_row, p_question, 'choice', p_options)).get_string('choice'); END;

  FUNCTION jev_score(p_row IN VARCHAR2, p_question IN VARCHAR2, p_levels IN VARCHAR2) RETURN NUMBER IS
  BEGIN RETURN JSON_OBJECT_T.parse(jev_eval(p_row, p_question, 'score', p_levels)).get_number('score'); END;

  FUNCTION jev_score_norm(p_row IN VARCHAR2, p_question IN VARCHAR2, p_levels IN VARCHAR2) RETURN NUMBER IS
  BEGIN RETURN jev_score(p_row, p_question, p_levels) / GREATEST(opts_array(p_levels).get_size - 1, 1); END;

  FUNCTION jev_confidence(p_row IN VARCHAR2, p_question IN VARCHAR2, p_kind IN VARCHAR2, p_options IN VARCHAR2) RETURN NUMBER IS
  BEGIN RETURN JSON_OBJECT_T.parse(jev_eval(p_row, p_question, p_kind, p_options)).get_number('confidence'); END;

  FUNCTION jev_stats RETURN VARCHAR2 IS
    o JSON_OBJECT_T := JSON_OBJECT_T();
  BEGIN
    o.put('api_url', opt('api_url')); o.put('rows_evaluated', g_rows); o.put('cache_hits', g_cache_hits);
    o.put('cached_answers', g_cache.COUNT); o.put('requests', g_requests); o.put('rows_sent', g_api_rows);
    o.put('http_ms', g_http_ms);
    o.put('input_tokens', g_tokens); o.put('errors', g_errors);
    o.put('estimated_cost_usd', ROUND(g_tokens * 0.042 / 1000000, 6));   -- jev-1.13 list price, input tokens only
    RETURN o.to_string;
  END;

  PROCEDURE jev_cache_clear IS BEGIN g_cache.DELETE; END;
  FUNCTION jev_version RETURN VARCHAR2 IS BEGIN RETURN c_version; END;
END ora_jev;
/
