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

MERGE INTO ora_jev_settings t USING (
  SELECT 'api_url' k, 'https://api.typesafe.ai/v1/systemone' v FROM dual UNION ALL
  SELECT 'model', 'jev-latest' FROM dual UNION ALL
  SELECT 'threshold', '0.5' FROM dual UNION ALL
  SELECT 'timeout', '30' FROM dual UNION ALL
  SELECT 'wallet', '' FROM dual UNION ALL
  SELECT 'max_rows_per_session', '0' FROM dual) s     -- 0 = no limit; a spend guard for shared databases
ON (t.k = s.k) WHEN NOT MATCHED THEN INSERT (k, v) VALUES (s.k, s.v);
COMMIT;

CREATE OR REPLACE PACKAGE ora_jev AUTHID DEFINER AS
  c_version CONSTANT VARCHAR2(10) := '0.1.0';

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
  -- session-level settings: api_key, api_url, model, threshold, timeout, wallet, max_rows_per_session
  PROCEDURE set_option(p_key IN VARCHAR2, p_value IN VARCHAR2);
END ora_jev;
/

CREATE OR REPLACE PACKAGE BODY ora_jev AS
  TYPE t_cache IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(64);
  TYPE t_opts  IS TABLE OF VARCHAR2(4000) INDEX BY VARCHAR2(40);
  g_cache t_cache;
  g_opts  t_opts;
  g_requests NUMBER := 0; g_cache_hits NUMBER := 0; g_rows NUMBER := 0; g_http_ms NUMBER := 0;
  g_tokens NUMBER := 0; g_errors NUMBER := 0;

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
    IF p_key NOT IN ('api_key', 'api_url', 'model', 'threshold', 'timeout', 'wallet', 'max_rows_per_session') THEN
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

  -- One request in the shape TypeSafe's Jev API (and pg-jev) uses, for one row.
  FUNCTION http_eval(p_row IN VARCHAR2, p_question IN VARCHAR2, p_kind IN VARCHAR2, p_options IN VARCHAR2) RETURN VARCHAR2 IS
    body JSON_OBJECT_T := JSON_OBJECT_T(); state JSON_OBJECT_T := JSON_OBJECT_T(); rows_a JSON_ARRAY_T := JSON_ARRAY_T();
    qs JSON_OBJECT_T := JSON_OBJECT_T(); q JSON_OBJECT_T := JSON_OBJECT_T(); crit JSON_OBJECT_T; opts JSON_ARRAY_T;
    req UTL_HTTP.REQ; resp UTL_HTTP.RESP; payload CLOB; answer CLOB; buf VARCHAR2(32767); t0 NUMBER := DBMS_UTILITY.GET_TIME;
    out JSON_OBJECT_T; usage JSON_OBJECT_T; err JSON_OBJECT_T; msg VARCHAR2(1500);
  BEGIN
    IF opt('api_key') IS NULL AND opt('api_url') LIKE '%typesafe.ai%' THEN
      RAISE_APPLICATION_ERROR(-20103, 'ora_jev: no API key. Run EXEC ora_jev.set_option(''api_key'', ''...'') in this session.');
    END IF;
    BEGIN rows_a.append(JSON_OBJECT_T.parse(p_row)); EXCEPTION WHEN OTHERS THEN rows_a.append(p_row); END;
    IF p_kind = 'noul' THEN
      state.put('condition', p_question);
      q.put('type', 'noul'); q.put('instructions', 'Does the record `rows[0]` satisfy the condition stated in `condition`?');
    ELSIF p_kind = 'score' THEN
      q.put('type', 'score'); q.put('instructions', 'Rate the record `rows[0]`: ' || p_question);
      q.put('criteria', opts_array(p_options));
    ELSE
      opts := opts_array(p_options); crit := JSON_OBJECT_T();
      FOR i IN 0 .. opts.get_size - 1 LOOP crit.put_null(opts.get_string(i)); END LOOP;
      q.put('type', 'choice'); q.put('instructions', 'For the record `rows[0]`: ' || p_question); q.put('criteria', crit);
    END IF;
    state.put('rows', rows_a); qs.put('r0', q);
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
    g_requests := g_requests + 1; g_http_ms := g_http_ms + (DBMS_UTILITY.GET_TIME - t0) * 10;
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
    RETURN out.get_object('answers').get_object('r0').to_string;
  END;

  FUNCTION jev_eval(p_row IN VARCHAR2, p_question IN VARCHAR2, p_kind IN VARCHAR2 DEFAULT 'noul',
                    p_options IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    k VARCHAR2(64); a VARCHAR2(4000); url VARCHAR2(1000) := opt('api_url'); model VARCHAR2(100) := opt('model');
  BEGIN
    IF p_kind NOT IN ('noul', 'choice', 'score') THEN
      RAISE_APPLICATION_ERROR(-20100, 'ora_jev: kind must be noul, choice or score');
    END IF;
    IF p_kind <> 'noul' AND p_options IS NULL THEN
      RAISE_APPLICATION_ERROR(-20100, 'ora_jev: ' || p_kind || ' needs a JSON array of options');
    END IF;
    SELECT RAWTOHEX(STANDARD_HASH(url || '|' || model || '|' || p_kind || '|' || p_question || '|' || p_options || '|' || p_row,
                                  'SHA256')) INTO k FROM dual;
    g_rows := g_rows + 1;
    IF g_cache.EXISTS(k) THEN g_cache_hits := g_cache_hits + 1; RETURN g_cache(k); END IF;
    IF num('max_rows_per_session') > 0 AND g_requests >= num('max_rows_per_session') THEN
      RAISE_APPLICATION_ERROR(-20104, 'ora_jev: max_rows_per_session (' || opt('max_rows_per_session') ||
        ') reached; raise it with set_option or narrow the query with ordinary SQL first.');
    END IF;
    a := http_eval(p_row, p_question, p_kind, p_options);
    g_cache(k) := a;
    RETURN a;
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
    o.put('cached_answers', g_cache.COUNT); o.put('requests', g_requests); o.put('http_ms', g_http_ms);
    o.put('input_tokens', g_tokens); o.put('errors', g_errors);
    o.put('estimated_cost_usd', ROUND(g_tokens * 0.042 / 1000000, 6));   -- jev-1.13 list price, input tokens only
    RETURN o.to_string;
  END;

  PROCEDURE jev_cache_clear IS BEGIN g_cache.DELETE; END;
  FUNCTION jev_version RETURN VARCHAR2 IS BEGIN RETURN c_version; END;
END ora_jev;
/
