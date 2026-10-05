-- ora-jev tests against test/mock_jev.py. Usage:
--   SQL> DEFINE mock_url = 'http://host.docker.internal:8788/v1/systemone'
--   SQL> @test_mock.sql
SET SERVEROUTPUT ON FEEDBACK OFF LINESIZE 200
EXEC ora_jev.set_option('api_url', '&mock_url')
SET DEFINE OFF
EXEC ora_jev.jev_cache_clear
BEGIN EXECUTE IMMEDIATE 'DROP TABLE ora_jev_test_tickets PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE ora_jev_test_tickets (id NUMBER, subject VARCHAR2(200), body VARCHAR2(400));
INSERT INTO ora_jev_test_tickets VALUES (1, 'Refund please', 'I was charged twice, refund the duplicate billing charge');
INSERT INTO ora_jev_test_tickets VALUES (2, 'App crashes', 'The technical error appears when I open the report');
INSERT INTO ora_jev_test_tickets VALUES (3, 'Thanks', 'Great service, nothing else needed');
COMMIT;
DECLARE
  passed PLS_INTEGER := 0; failed PLS_INTEGER := 0; n NUMBER; v VARCHAR2(4000);
  PROCEDURE ok(p_name VARCHAR2, p_cond BOOLEAN) IS
  BEGIN
    IF p_cond THEN passed := passed + 1; DBMS_OUTPUT.PUT_LINE('PASS ' || p_name);
    ELSE failed := failed + 1; DBMS_OUTPUT.PUT_LINE('FAIL ' || p_name); END IF;
  END;
BEGIN
  SELECT COUNT(*) INTO n FROM ora_jev_test_tickets WHERE ora_jev.jev(JSON_OBJECT(*), 'mentions a refund') = 1;
  ok('jev() in WHERE filters rows (1 of 3)', n = 1);
  SELECT ora_jev.jev_prob(JSON_OBJECT(*), 'mentions a refund') INTO n FROM ora_jev_test_tickets WHERE id = 1;
  ok('jev_prob returns the endpoint probability', n = 0.9);
  SELECT ora_jev.jev_choice(JSON_OBJECT(*), 'which team?', '["billing","technical","sales"]') INTO v FROM ora_jev_test_tickets WHERE id = 2;
  ok('jev_choice returns an option', v = 'technical');
  SELECT ora_jev.jev_score(JSON_OBJECT(*), 'how upset?', '["calm","annoyed","angry"]') INTO n FROM ora_jev_test_tickets WHERE id = 1;
  ok('jev_score returns the level position', n = 1);
  SELECT ora_jev.jev_score_norm(JSON_OBJECT(*), 'how upset?', '["calm","annoyed","angry"]') INTO n FROM ora_jev_test_tickets WHERE id = 1;
  ok('jev_score_norm is 0..1', n = 0.5);
  SELECT ora_jev.jev_confidence(JSON_OBJECT(*), 'which team?', 'choice', '["billing","technical","sales"]') INTO n FROM ora_jev_test_tickets WHERE id = 2;
  ok('jev_confidence of a choice', n = 0.8);
  ok('repeat calls hit the session cache', JSON_VALUE(ora_jev.jev_stats, '$.cache_hits' RETURNING NUMBER) >= 2);
  ok('usage tokens are counted', JSON_VALUE(ora_jev.jev_stats, '$.input_tokens' RETURNING NUMBER) > 0);
  BEGIN v := ora_jev.jev_eval('{}', 'x', 'choice', NULL); ok('choice without options is rejected', FALSE);
  EXCEPTION WHEN OTHERS THEN ok('choice without options is rejected', SQLCODE = -20100); END;
  BEGIN v := ora_jev.jev_eval('{}', 'x', 'score', 'not json'); ok('bad options JSON is rejected', FALSE);
  EXCEPTION WHEN OTHERS THEN ok('bad options JSON is rejected', SQLCODE = -20100); END;
  ora_jev.set_option('max_rows_per_session', '1');
  BEGIN v := ora_jev.jev_eval('{"x":"brand new row"}', 'mentions a refund'); ok('spend guard stops new requests', FALSE);
  EXCEPTION WHEN OTHERS THEN ok('spend guard stops new requests', SQLCODE = -20104); END;
  ora_jev.set_option('max_rows_per_session', '0');
  ora_jev.set_option('api_url', 'https://api.typesafe.ai/v1/systemone');
  BEGIN v := ora_jev.jev_eval('{"x":"y"}', 'anything'); ok('TypeSafe without a key is refused before any call', FALSE);
  EXCEPTION WHEN OTHERS THEN ok('TypeSafe without a key is refused before any call', SQLCODE = -20103); END;
  DBMS_OUTPUT.PUT_LINE(CHR(10) || passed || ' passed, ' || failed || ' failed');
  DBMS_OUTPUT.PUT_LINE('stats: ' || ora_jev.jev_stats);
END;
/
DROP TABLE ora_jev_test_tickets PURGE;
