-- Harden the ISBN-10 validator for malformed and longer source identifiers.
-- The original implementation assigned input to CHAR(10) before validating
-- its length, which raised ERROR 1406 in strict mode instead of returning 0.

DROP FUNCTION IF EXISTS fn_is_valid_isbn10;

DELIMITER $$

CREATE FUNCTION fn_is_valid_isbn10 (p_identifier VARCHAR(64))
RETURNS TINYINT
DETERMINISTIC
NO SQL
BEGIN
    DECLARE v_isbn VARCHAR(64);
    DECLARE v_checksum INT;

    SET v_isbn = UPPER(TRIM(p_identifier));

    IF v_isbn IS NULL
       OR CHAR_LENGTH(v_isbn) <> 10
       OR v_isbn NOT REGEXP '^[0-9]{9}[0-9X]$' THEN
        RETURN 0;
    END IF;

    SET v_checksum =
          CAST(SUBSTRING(v_isbn, 1, 1) AS UNSIGNED) * 10
        + CAST(SUBSTRING(v_isbn, 2, 1) AS UNSIGNED) * 9
        + CAST(SUBSTRING(v_isbn, 3, 1) AS UNSIGNED) * 8
        + CAST(SUBSTRING(v_isbn, 4, 1) AS UNSIGNED) * 7
        + CAST(SUBSTRING(v_isbn, 5, 1) AS UNSIGNED) * 6
        + CAST(SUBSTRING(v_isbn, 6, 1) AS UNSIGNED) * 5
        + CAST(SUBSTRING(v_isbn, 7, 1) AS UNSIGNED) * 4
        + CAST(SUBSTRING(v_isbn, 8, 1) AS UNSIGNED) * 3
        + CAST(SUBSTRING(v_isbn, 9, 1) AS UNSIGNED) * 2
        + CASE SUBSTRING(v_isbn, 10, 1)
              WHEN 'X' THEN 10
              ELSE CAST(SUBSTRING(v_isbn, 10, 1) AS UNSIGNED)
          END;

    RETURN MOD(v_checksum, 11) = 0;
END$$

DELIMITER ;
