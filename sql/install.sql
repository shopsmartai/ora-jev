-- ora-jev installer. In SQL*Plus or SQLcl, as the schema that will own the package:
--   SQL> @install.sql
SET SERVEROUTPUT ON FEEDBACK OFF DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE
@@ora_jev.sql
DECLARE n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM user_errors WHERE name = 'ORA_JEV';
  IF n > 0 THEN RAISE_APPLICATION_ERROR(-20000, 'ora_jev did not compile; see USER_ERRORS'); END IF;
  DBMS_OUTPUT.PUT_LINE('ora-jev ' || ora_jev.jev_version || ' installed');
END;
/
