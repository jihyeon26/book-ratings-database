-- Expected-failure tests for core relational constraints.
-- Prerequisite: tests/run_sample_idempotency.sql has created and populated
-- bookdb_sample_test. The test fixtures below are rolled back.

USE bookdb_sample_test;

DROP PROCEDURE IF EXISTS test_expect_mysql_error;
DROP PROCEDURE IF EXISTS test_assert_constraint_count;

DELIMITER $$

CREATE PROCEDURE test_expect_mysql_error (
    IN p_test_name VARCHAR(255),
    IN p_statement TEXT,
    IN p_expected_errno INT
)
BEGIN
    DECLARE v_error_caught BOOLEAN DEFAULT FALSE;
    DECLARE v_actual_errno INT DEFAULT NULL;
    DECLARE v_sqlstate CHAR(5) DEFAULT NULL;
    DECLARE v_error_message TEXT DEFAULT NULL;
    DECLARE v_failure_message VARCHAR(128);

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_actual_errno = MYSQL_ERRNO,
                v_sqlstate = RETURNED_SQLSTATE,
                v_error_message = MESSAGE_TEXT;
            SET v_error_caught = TRUE;
        END;

        SET @constraint_test_statement = p_statement;
        PREPARE constraint_test_statement FROM @constraint_test_statement;
        EXECUTE constraint_test_statement;
        DEALLOCATE PREPARE constraint_test_statement;
    END;

    IF NOT v_error_caught THEN
        SET v_failure_message = LEFT(
            CONCAT('FAILED: ', p_test_name, '; statement unexpectedly succeeded'),
            128
        );
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = v_failure_message;
    ELSEIF v_actual_errno <> p_expected_errno THEN
        SET v_failure_message = LEFT(
            CONCAT(
                'FAILED: ', p_test_name,
                '; expected errno=', p_expected_errno,
                '; actual errno=', v_actual_errno
            ),
            128
        );
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = v_failure_message;
    END IF;

    INSERT INTO constraint_test_result (
        test_name,
        expected_errno,
        actual_errno,
        sqlstate_code,
        error_message
    )
    VALUES (
        p_test_name,
        p_expected_errno,
        v_actual_errno,
        v_sqlstate,
        v_error_message
    );
END$$

CREATE PROCEDURE test_assert_constraint_count (IN p_expected_count INT)
BEGIN
    DECLARE v_actual_count INT;

    SET v_actual_count = (SELECT COUNT(*) FROM constraint_test_result);

    IF v_actual_count <> p_expected_count THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'FAILED: unexpected constraint-test count';
    END IF;
END$$

DELIMITER ;

CREATE TEMPORARY TABLE constraint_test_result (
    test_name VARCHAR(255) NOT NULL,
    expected_errno INT NOT NULL,
    actual_errno INT NOT NULL,
    sqlstate_code CHAR(5) NOT NULL,
    error_message TEXT NOT NULL,
    PRIMARY KEY (test_name)
);

START TRANSACTION;

-- Create valid supporting records so each failing statement reaches the
-- intended constraint instead of being rejected by an unrelated dependency.
INSERT INTO ingestion_run (
    source_name,
    source_file,
    status,
    rows_loaded,
    finished_at
)
VALUES (
    'constraint_test',
    'synthetic/constraint_test',
    'loaded',
    4,
    CURRENT_TIMESTAMP(6)
);
SET @constraint_ingestion_run_id = LAST_INSERT_ID();

INSERT INTO stg_amazon_rating (ingestion_run_id)
VALUES (@constraint_ingestion_run_id);
SET @constraint_staging_id_1 = LAST_INSERT_ID();

INSERT INTO stg_amazon_rating (ingestion_run_id)
VALUES (@constraint_ingestion_run_id);
SET @constraint_staging_id_2 = LAST_INSERT_ID();

INSERT INTO book (isbn10, title, metadata_source)
VALUES ('0306406152', 'Constraint Test Book', 'ratings');
SET @constraint_book_id = LAST_INSERT_ID();

INSERT INTO reader (source_user_id)
VALUES ('constraint-test-reader');
SET @constraint_reader_id = LAST_INSERT_ID();

INSERT INTO reader (source_user_id)
VALUES ('constraint-test-unused-reader');
SET @constraint_unused_reader_id = LAST_INSERT_ID();

INSERT INTO rating (
    book_id,
    reader_id,
    score,
    source_staging_rating_id
)
VALUES (
    @constraint_book_id,
    @constraint_reader_id,
    4.0,
    @constraint_staging_id_1
);

CALL test_expect_mysql_error(
    'mandatory reader identifier rejects NULL',
    'INSERT INTO reader (source_user_id) VALUES (NULL)',
    1048
);

CALL test_expect_mysql_error(
    'mandatory book title rejects NULL',
    'INSERT INTO book (isbn10, title, metadata_source) VALUES (''123456789X'', NULL, ''ratings'')',
    1048
);

CALL test_expect_mysql_error(
    'duplicate ISBN-10 is rejected',
    'INSERT INTO book (isbn10, title, metadata_source) VALUES (''0306406152'', ''Duplicate'', ''ratings'')',
    1062
);

CALL test_expect_mysql_error(
    'published year below domain is rejected',
    'INSERT INTO book (isbn10, title, published_year, metadata_source) VALUES (''123456789X'', ''Old Year'', 1400, ''ratings'')',
    3819
);

CALL test_expect_mysql_error(
    'rating below domain is rejected',
    CONCAT(
        'INSERT INTO rating (book_id, reader_id, score, source_staging_rating_id) VALUES (',
        @constraint_book_id, ', ', @constraint_unused_reader_id, ', 0.5, ',
        @constraint_staging_id_2, ')'
    ),
    3819
);

CALL test_expect_mysql_error(
    'rating above domain is rejected',
    CONCAT(
        'INSERT INTO rating (book_id, reader_id, score, source_staging_rating_id) VALUES (',
        @constraint_book_id, ', ', @constraint_unused_reader_id, ', 5.5, ',
        @constraint_staging_id_2, ')'
    ),
    3819
);

CALL test_expect_mysql_error(
    'invalid helpfulness is rejected',
    CONCAT(
        'INSERT INTO rating (book_id, reader_id, score, helpful_yes, helpful_total, source_staging_rating_id) VALUES (',
        @constraint_book_id, ', ', @constraint_unused_reader_id,
        ', 4.0, 2, 1, ', @constraint_staging_id_2, ')'
    ),
    3819
);

CALL test_expect_mysql_error(
    'duplicate reader-book rating is rejected',
    CONCAT(
        'INSERT INTO rating (book_id, reader_id, score, source_staging_rating_id) VALUES (',
        @constraint_book_id, ', ', @constraint_reader_id, ', 4.5, ',
        @constraint_staging_id_2, ')'
    ),
    1062
);

CALL test_expect_mysql_error(
    'rating cannot reference a missing book',
    CONCAT(
        'INSERT INTO rating (book_id, reader_id, score, source_staging_rating_id) VALUES (',
        '18446744073709551615, ', @constraint_reader_id, ', 4.0, ',
        @constraint_staging_id_2, ')'
    ),
    1452
);

CALL test_expect_mysql_error(
    'rating cannot reference a missing reader',
    CONCAT(
        'INSERT INTO rating (book_id, reader_id, score, source_staging_rating_id) VALUES (',
        @constraint_book_id, ', 18446744073709551615, 4.0, ',
        @constraint_staging_id_2, ')'
    ),
    1452
);

CALL test_expect_mysql_error(
    'book-author cannot reference a missing author',
    CONCAT(
        'INSERT INTO book_author (book_id, author_id) VALUES (',
        @constraint_book_id, ', 18446744073709551615)'
    ),
    1452
);

CALL test_expect_mysql_error(
    'book-genre cannot reference a missing genre',
    CONCAT(
        'INSERT INTO book_genre (book_id, genre_id) VALUES (',
        @constraint_book_id, ', 18446744073709551615)'
    ),
    1452
);

CALL test_assert_constraint_count(12);

SELECT
    test_name,
    expected_errno,
    actual_errno,
    sqlstate_code,
    expected_errno = actual_errno AS passed
FROM constraint_test_result
ORDER BY test_name;

ROLLBACK;

SELECT 'PASS: 12 invalid writes were rejected by the intended constraints'
    AS test_result;

DROP PROCEDURE test_expect_mysql_error;
DROP PROCEDURE test_assert_constraint_count;
