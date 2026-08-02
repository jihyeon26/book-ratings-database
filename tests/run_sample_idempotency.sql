-- End-to-end smoke test for migrations, sample ingestion, validation, and a
-- second transformation pass. Run from the repository root:
--   mysql --local-infile=1 ... < tests/run_sample_idempotency.sql
-- or from an interactive client:
--   SOURCE tests/run_sample_idempotency.sql;

DROP DATABASE IF EXISTS bookdb_sample_test;
CREATE DATABASE bookdb_sample_test
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;
USE bookdb_sample_test;

SOURCE migrations/001_operational_and_staging.sql;
SOURCE migrations/002_core_schema.sql;
SOURCE migrations/003_serving_and_workload_indexes.sql;
SOURCE migrations/004_harden_isbn10_validator.sql;
SOURCE sql/load/002_load_sample.sql;
SOURCE sql/transform/001_refresh_core.sql;

DROP PROCEDURE IF EXISTS test_assert_equal;

DELIMITER $$

CREATE PROCEDURE test_assert_equal (
    IN p_test_name VARCHAR(255),
    IN p_actual BIGINT UNSIGNED,
    IN p_expected BIGINT UNSIGNED
)
BEGIN
    DECLARE v_message VARCHAR(1000);

    IF NOT (p_actual <=> p_expected) THEN
        SET v_message = CONCAT(
            'FAILED: ', p_test_name,
            '; expected=', p_expected,
            '; actual=', COALESCE(CAST(p_actual AS CHAR), 'NULL')
        );

        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = v_message;
    END IF;
END$$

DELIMITER ;

CALL test_assert_equal('sample rating staging rows',
    (SELECT rows_loaded FROM ingestion_run WHERE source_name = 'amazon_ratings'), 13);
CALL test_assert_equal('sample Amazon book staging rows',
    (SELECT rows_loaded FROM ingestion_run WHERE source_name = 'amazon_books'), 5);
CALL test_assert_equal('sample BX book staging rows',
    (SELECT rows_loaded FROM ingestion_run WHERE source_name = 'bx_books'), 6);
CALL test_assert_equal('book count', (SELECT COUNT(*) FROM book), 4);
CALL test_assert_equal('reader count', (SELECT COUNT(*) FROM reader), 4);
CALL test_assert_equal('rating count', (SELECT COUNT(*) FROM rating), 5);
CALL test_assert_equal('book-author count', (SELECT COUNT(*) FROM book_author), 4);
CALL test_assert_equal('book-genre count', (SELECT COUNT(*) FROM book_genre), 4);

CALL test_assert_equal('latest duplicate wins', (
    SELECT CAST(r.score * 10 AS UNSIGNED)
    FROM rating AS r
    JOIN book AS b ON b.book_id = r.book_id
    JOIN reader AS rd ON rd.reader_id = r.reader_id
    WHERE b.isbn10 = '0826414346'
      AND rd.source_user_id = 'sample-user-a'
), 50);

CALL test_assert_equal('invalid helpfulness becomes null', (
    SELECT (r.helpful_yes IS NULL AND r.helpful_total IS NULL)
    FROM rating AS r
    JOIN book AS b ON b.book_id = r.book_id
    JOIN reader AS rd ON rd.reader_id = r.reader_id
    WHERE b.isbn10 = '0195153448'
      AND rd.source_user_id = 'sample-user-b'
), 1);

CALL test_assert_equal('rating reconciliation',
    (SELECT COUNT(*) FROM rating)
    + (
        SELECT COUNT(DISTINCT source_record_id)
        FROM rejected_record
        WHERE ingestion_run_id = @amazon_rating_run_id
          AND disposition = 'reject_record'
    ),
    (SELECT rows_loaded FROM ingestion_run
     WHERE ingestion_run_id = @amazon_rating_run_id));

CALL test_assert_equal('unsupported ASIN reason', (
    SELECT COUNT(DISTINCT source_record_id)
    FROM rejected_record
    WHERE ingestion_run_id = @amazon_rating_run_id
      AND reason_code = 'unsupported_asin'
      AND disposition = 'reject_record'
), 1);
CALL test_assert_equal('duplicate rating reason', (
    SELECT COUNT(DISTINCT source_record_id)
    FROM rejected_record
    WHERE ingestion_run_id = @amazon_rating_run_id
      AND reason_code = 'duplicate_user_book_rating'
), 1);
CALL test_assert_equal('missing book title reason', (
    SELECT COUNT(DISTINCT source_record_id)
    FROM rejected_record
    WHERE ingestion_run_id = @amazon_rating_run_id
      AND reason_code = 'missing_book_title'
), 1);
CALL test_assert_equal('invalid helpfulness warning', (
    SELECT COUNT(DISTINCT source_record_id)
    FROM rejected_record
    WHERE ingestion_run_id = @amazon_rating_run_id
      AND reason_code = 'invalid_helpfulness'
      AND disposition = 'null_field'
), 1);
CALL test_assert_equal('ambiguous title reason', (
    SELECT COUNT(DISTINCT source_record_id)
    FROM rejected_record
    WHERE ingestion_run_id = @amazon_book_run_id
      AND reason_code = 'ambiguous_title_mapping'
), 1);
CALL test_assert_equal('unmatched title reason', (
    SELECT COUNT(DISTINCT source_record_id)
    FROM rejected_record
    WHERE ingestion_run_id = @amazon_book_run_id
      AND reason_code = 'unmatched_title'
), 1);

CREATE TEMPORARY TABLE test_snapshot_before AS
SELECT 'book_count' AS metric, COUNT(*) AS metric_value FROM book
UNION ALL SELECT 'reader_count', COUNT(*) FROM reader
UNION ALL SELECT 'rating_count', COUNT(*) FROM rating
UNION ALL SELECT 'book_author_count', COUNT(*) FROM book_author
UNION ALL SELECT 'book_genre_count', COUNT(*) FROM book_genre
UNION ALL
SELECT 'book_signature', BIT_XOR(CRC32(CONCAT_WS(
    CHAR(31), isbn10, title,
    COALESCE(CAST(published_year AS CHAR), '<null>'),
    COALESCE(language_code, '<null>'), metadata_source
))) FROM book
UNION ALL
SELECT 'rating_signature', BIT_XOR(CRC32(CONCAT_WS(
    CHAR(31), b.isbn10, rd.source_user_id, CAST(r.score AS CHAR),
    COALESCE(CAST(r.review_time AS CHAR), '<null>'),
    COALESCE(CAST(r.helpful_yes AS CHAR), '<null>'),
    COALESCE(CAST(r.helpful_total AS CHAR), '<null>')
)))
FROM rating AS r
JOIN book AS b ON b.book_id = r.book_id
JOIN reader AS rd ON rd.reader_id = r.reader_id
UNION ALL
SELECT 'book_author_signature', BIT_XOR(CRC32(CONCAT_WS(
    CHAR(31), b.isbn10, a.author_key
)))
FROM book_author AS ba
JOIN book AS b ON b.book_id = ba.book_id
JOIN author AS a ON a.author_id = ba.author_id
UNION ALL
SELECT 'book_genre_signature', BIT_XOR(CRC32(CONCAT_WS(
    CHAR(31), b.isbn10, g.genre_name
)))
FROM book_genre AS bg
JOIN book AS b ON b.book_id = bg.book_id
JOIN genre AS g ON g.genre_id = bg.genre_id;

SET @snapshot_metric_count = (SELECT COUNT(*) FROM test_snapshot_before);

CALL sp_refresh_core(
    @amazon_rating_run_id,
    @amazon_book_run_id,
    @bx_book_run_id
);

CREATE TEMPORARY TABLE test_snapshot_after AS
SELECT 'book_count' AS metric, COUNT(*) AS metric_value FROM book
UNION ALL SELECT 'reader_count', COUNT(*) FROM reader
UNION ALL SELECT 'rating_count', COUNT(*) FROM rating
UNION ALL SELECT 'book_author_count', COUNT(*) FROM book_author
UNION ALL SELECT 'book_genre_count', COUNT(*) FROM book_genre
UNION ALL
SELECT 'book_signature', BIT_XOR(CRC32(CONCAT_WS(
    CHAR(31), isbn10, title,
    COALESCE(CAST(published_year AS CHAR), '<null>'),
    COALESCE(language_code, '<null>'), metadata_source
))) FROM book
UNION ALL
SELECT 'rating_signature', BIT_XOR(CRC32(CONCAT_WS(
    CHAR(31), b.isbn10, rd.source_user_id, CAST(r.score AS CHAR),
    COALESCE(CAST(r.review_time AS CHAR), '<null>'),
    COALESCE(CAST(r.helpful_yes AS CHAR), '<null>'),
    COALESCE(CAST(r.helpful_total AS CHAR), '<null>')
)))
FROM rating AS r
JOIN book AS b ON b.book_id = r.book_id
JOIN reader AS rd ON rd.reader_id = r.reader_id
UNION ALL
SELECT 'book_author_signature', BIT_XOR(CRC32(CONCAT_WS(
    CHAR(31), b.isbn10, a.author_key
)))
FROM book_author AS ba
JOIN book AS b ON b.book_id = ba.book_id
JOIN author AS a ON a.author_id = ba.author_id
UNION ALL
SELECT 'book_genre_signature', BIT_XOR(CRC32(CONCAT_WS(
    CHAR(31), b.isbn10, g.genre_name
)))
FROM book_genre AS bg
JOIN book AS b ON b.book_id = bg.book_id
JOIN genre AS g ON g.genre_id = bg.genre_id;

CALL test_assert_equal('two successful transformations', (
    SELECT COUNT(*) FROM transformation_run WHERE status = 'succeeded'
), 2);

CALL test_assert_equal('idempotent metric count', (
    SELECT COUNT(*)
    FROM test_snapshot_before AS b
    JOIN test_snapshot_after AS a ON a.metric = b.metric
    WHERE a.metric_value = b.metric_value
), @snapshot_metric_count);

SELECT
    b.metric,
    b.metric_value AS first_run,
    a.metric_value AS second_run,
    b.metric_value = a.metric_value AS matches
FROM test_snapshot_before AS b
JOIN test_snapshot_after AS a ON a.metric = b.metric
ORDER BY b.metric;

SELECT 'PASS: sample transformation is repeatable' AS test_result;

DROP PROCEDURE test_assert_equal;
