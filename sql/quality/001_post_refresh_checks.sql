-- Post-refresh checks. Every result should be zero unless the comment states
-- otherwise. Run after sql/transform/001_refresh_core.sql.

-- 1. Orphaned foreign keys (constraints also enforce these).
SELECT 'rating_without_book' AS check_name, COUNT(*) AS violation_count
FROM rating AS r
LEFT JOIN book AS b ON b.book_id = r.book_id
WHERE b.book_id IS NULL
UNION ALL
SELECT 'rating_without_reader', COUNT(*)
FROM rating AS r
LEFT JOIN reader AS rd ON rd.reader_id = r.reader_id
WHERE rd.reader_id IS NULL
UNION ALL
SELECT 'book_author_without_book', COUNT(*)
FROM book_author AS ba
LEFT JOIN book AS b ON b.book_id = ba.book_id
WHERE b.book_id IS NULL
UNION ALL
SELECT 'book_author_without_author', COUNT(*)
FROM book_author AS ba
LEFT JOIN author AS a ON a.author_id = ba.author_id
WHERE a.author_id IS NULL
UNION ALL
SELECT 'book_genre_without_book', COUNT(*)
FROM book_genre AS bg
LEFT JOIN book AS b ON b.book_id = bg.book_id
WHERE b.book_id IS NULL
UNION ALL
SELECT 'book_genre_without_genre', COUNT(*)
FROM book_genre AS bg
LEFT JOIN genre AS g ON g.genre_id = bg.genre_id
WHERE g.genre_id IS NULL;

-- 2. Core domain rules.
SELECT 'invalid_isbn10' AS check_name, COUNT(*) AS violation_count
FROM book
WHERE fn_is_valid_isbn10(isbn10) = 0
UNION ALL
SELECT 'missing_or_long_title', COUNT(*)
FROM book
WHERE NULLIF(TRIM(title), '') IS NULL OR CHAR_LENGTH(title) > 500
UNION ALL
SELECT 'invalid_rating_score', COUNT(*)
FROM rating
WHERE score NOT BETWEEN 1.0 AND 5.0
UNION ALL
SELECT 'invalid_helpfulness', COUNT(*)
FROM rating
WHERE helpful_yes IS NOT NULL
  AND helpful_total IS NOT NULL
  AND helpful_yes > helpful_total
UNION ALL
SELECT 'duplicate_user_book_rating', COUNT(*)
FROM (
    SELECT book_id, reader_id
    FROM rating
    GROUP BY book_id, reader_id
    HAVING COUNT(*) > 1
) AS duplicates;

-- 3. Latest-source reconciliation. accepted + rejected must equal staged for
-- ratings. A single source row can have multiple reasons, hence DISTINCT.
SET @amazon_rating_run_id = (
    SELECT MAX(ingestion_run_id)
    FROM ingestion_run
    WHERE source_name = 'amazon_ratings' AND status = 'loaded'
);

SELECT
    ir.ingestion_run_id,
    ir.rows_loaded AS staged_rows,
    (
        SELECT COUNT(*)
        FROM rating AS r
        JOIN stg_amazon_rating AS sr
            ON sr.staging_rating_id = r.source_staging_rating_id
        WHERE sr.ingestion_run_id = ir.ingestion_run_id
    ) AS accepted_rows,
    (
        SELECT COUNT(DISTINCT rr.source_record_id)
        FROM rejected_record AS rr
        WHERE rr.ingestion_run_id = ir.ingestion_run_id
          AND rr.source_table = 'stg_amazon_rating'
          AND rr.disposition = 'reject_record'
    ) AS rejected_rows,
    ir.rows_loaded
        - (
            SELECT COUNT(*)
            FROM rating AS r
            JOIN stg_amazon_rating AS sr
                ON sr.staging_rating_id = r.source_staging_rating_id
            WHERE sr.ingestion_run_id = ir.ingestion_run_id
        )
        - (
            SELECT COUNT(DISTINCT rr.source_record_id)
            FROM rejected_record AS rr
            WHERE rr.ingestion_run_id = ir.ingestion_run_id
              AND rr.source_table = 'stg_amazon_rating'
              AND rr.disposition = 'reject_record'
        ) AS unexplained_rows
FROM ingestion_run AS ir
WHERE ir.ingestion_run_id = @amazon_rating_run_id;

-- 4. Rejection profile: an auditable replacement for cascading ad-hoc deletes.
SET @latest_transformation_run_id = (
    SELECT MAX(transformation_run_id)
    FROM transformation_run
    WHERE status = 'succeeded'
);

SELECT
    ir.source_name,
    rr.disposition,
    rr.reason_code,
    COUNT(DISTINCT rr.source_record_id) AS affected_records
FROM rejected_record AS rr
JOIN ingestion_run AS ir
    ON ir.ingestion_run_id = rr.ingestion_run_id
WHERE rr.ingestion_run_id IN (
    SELECT amazon_rating_run_id
    FROM transformation_run
    WHERE transformation_run_id = @latest_transformation_run_id
    UNION ALL
    SELECT amazon_book_run_id
    FROM transformation_run
    WHERE transformation_run_id = @latest_transformation_run_id
    UNION ALL
    SELECT bx_book_run_id
    FROM transformation_run
    WHERE transformation_run_id = @latest_transformation_run_id
)
GROUP BY ir.source_name, rr.disposition, rr.reason_code
ORDER BY ir.source_name, rr.disposition, affected_records DESC;

-- 5. Coverage metrics are descriptive, not failures.
SELECT
    COUNT(*) AS total_books,
    SUM(publisher_id IS NULL) AS books_without_publisher,
    SUM(description IS NULL) AS books_without_description,
    SUM(published_year IS NULL) AS books_without_year,
    SUM(language_code IS NULL) AS books_without_language
FROM book;

SELECT
    COUNT(*) AS total_books,
    SUM(ba.book_id IS NULL) AS books_without_author,
    SUM(bg.book_id IS NULL) AS books_without_genre
FROM book AS b
LEFT JOIN (SELECT DISTINCT book_id FROM book_author) AS ba
    ON ba.book_id = b.book_id
LEFT JOIN (SELECT DISTINCT book_id FROM book_genre) AS bg
    ON bg.book_id = b.book_id;
