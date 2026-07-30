-- Validate three completed staging runs and rebuild the normalized core.
--
-- Policy highlights:
--   * the public scope is ISBN-10; Amazon ASIN values beginning with B0 are
--     quarantined instead of being inserted and later cascade-deleted;
--   * repeated user-book ratings keep the latest review_time, then the latest
--     staging row as a deterministic tie-breaker;
--   * title-based Amazon metadata is accepted only when a title maps to one
--     valid ISBN-10 in the selected ratings run;
--   * metadata precedence is explicit, never chosen with an unexplained MAX().

DROP PROCEDURE IF EXISTS sp_refresh_core;

DELIMITER $$

CREATE PROCEDURE sp_refresh_core (
    IN p_amazon_rating_run_id BIGINT UNSIGNED,
    IN p_amazon_book_run_id BIGINT UNSIGNED,
    IN p_bx_book_run_id BIGINT UNSIGNED
)
BEGIN
    DECLARE v_transformation_run_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_books_loaded BIGINT UNSIGNED DEFAULT 0;
    DECLARE v_ratings_loaded BIGINT UNSIGNED DEFAULT 0;
    DECLARE v_error_message TEXT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_message = MESSAGE_TEXT;
        ROLLBACK;

        IF v_transformation_run_id IS NOT NULL THEN
            UPDATE transformation_run
            SET
                status = 'failed',
                finished_at = CURRENT_TIMESTAMP(6),
                error_message = LEFT(v_error_message, 1000)
            WHERE transformation_run_id = v_transformation_run_id;
        END IF;

        RESIGNAL;
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM ingestion_run
        WHERE ingestion_run_id = p_amazon_rating_run_id
          AND source_name = 'amazon_ratings'
          AND status = 'loaded'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A loaded amazon_ratings run is required';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM ingestion_run
        WHERE ingestion_run_id = p_amazon_book_run_id
          AND source_name = 'amazon_books'
          AND status = 'loaded'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A loaded amazon_books run is required';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM ingestion_run
        WHERE ingestion_run_id = p_bx_book_run_id
          AND source_name = 'bx_books'
          AND status = 'loaded'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A loaded bx_books run is required';
    END IF;

    INSERT INTO transformation_run (
        amazon_rating_run_id,
        amazon_book_run_id,
        bx_book_run_id
    )
    VALUES (
        p_amazon_rating_run_id,
        p_amazon_book_run_id,
        p_bx_book_run_id
    );
    SET v_transformation_run_id = LAST_INSERT_ID();

    START TRANSACTION;

    DELETE FROM rejected_record
    WHERE ingestion_run_id IN (
        p_amazon_rating_run_id,
        p_amazon_book_run_id,
        p_bx_book_run_id
    );

    -- Amazon rating validation.
    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        reason_detail
    )
    SELECT
        p_amazon_rating_run_id,
        'stg_amazon_rating',
        staging_rating_id,
        'missing_identifier',
        'Book identifier is null or blank'
    FROM stg_amazon_rating
    WHERE ingestion_run_id = p_amazon_rating_run_id
      AND NULLIF(TRIM(identifier_raw), '') IS NULL;

    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        reason_detail
    )
    SELECT
        p_amazon_rating_run_id,
        'stg_amazon_rating',
        staging_rating_id,
        'unsupported_asin',
        'Identifier begins with B0; this ISBN-10 scoped model does not mix ASIN and ISBN'
    FROM stg_amazon_rating
    WHERE ingestion_run_id = p_amazon_rating_run_id
      AND UPPER(TRIM(identifier_raw)) LIKE 'B0%';

    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        reason_detail
    )
    SELECT
        p_amazon_rating_run_id,
        'stg_amazon_rating',
        staging_rating_id,
        'invalid_isbn10',
        'Identifier does not pass ISBN-10 format and checksum validation'
    FROM stg_amazon_rating
    WHERE ingestion_run_id = p_amazon_rating_run_id
      AND NULLIF(TRIM(identifier_raw), '') IS NOT NULL
      AND UPPER(TRIM(identifier_raw)) NOT LIKE 'B0%'
      AND fn_is_valid_isbn10(identifier_raw) = 0;

    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        reason_detail
    )
    SELECT
        p_amazon_rating_run_id,
        'stg_amazon_rating',
        staging_rating_id,
        'invalid_user_id',
        'User identifier is blank or longer than the core limit of 50 characters'
    FROM stg_amazon_rating
    WHERE ingestion_run_id = p_amazon_rating_run_id
      AND (
          NULLIF(TRIM(user_id_raw), '') IS NULL
          OR CHAR_LENGTH(TRIM(user_id_raw)) > 50
      );

    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        reason_detail
    )
    SELECT
        p_amazon_rating_run_id,
        'stg_amazon_rating',
        staging_rating_id,
        'invalid_score',
        'Explicit score must be numeric and between 1.0 and 5.0'
    FROM stg_amazon_rating
    WHERE ingestion_run_id = p_amazon_rating_run_id
      AND (
          CASE
              WHEN TRIM(score_raw) REGEXP '^[0-9]+([.][0-9]+)?$'
                  THEN CAST(TRIM(score_raw) AS DECIMAL(4, 2)) NOT BETWEEN 1.0 AND 5.0
              ELSE TRUE
          END
      );

    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        reason_detail
    )
    SELECT
        p_amazon_rating_run_id,
        'stg_amazon_rating',
        staging_rating_id,
        'invalid_review_date',
        'Nonblank review date is not a valid YYYY-MM-DD value'
    FROM stg_amazon_rating
    WHERE ingestion_run_id = p_amazon_rating_run_id
      AND NULLIF(TRIM(review_time_raw), '') IS NOT NULL
      AND (
          review_time_raw NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
          OR STR_TO_DATE(review_time_raw, '%Y-%m-%d') IS NULL
      );

    -- Invalid optional helpfulness fields are nulled, not grounds for dropping
    -- an otherwise valid rating.
    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        disposition,
        reason_detail
    )
    SELECT
        p_amazon_rating_run_id,
        'stg_amazon_rating',
        staging_rating_id,
        'invalid_helpfulness',
        'null_field',
        'Helpfulness values must be nonnegative integers with yes <= total'
    FROM stg_amazon_rating
    WHERE ingestion_run_id = p_amazon_rating_run_id
      AND (
          (NULLIF(TRIM(helpful_yes_raw), '') IS NOT NULL
              AND helpful_yes_raw NOT REGEXP '^[0-9]+$')
          OR (NULLIF(TRIM(helpful_total_raw), '') IS NOT NULL
              AND helpful_total_raw NOT REGEXP '^[0-9]+$')
          OR (
              helpful_yes_raw REGEXP '^[0-9]+$'
              AND helpful_total_raw REGEXP '^[0-9]+$'
              AND CAST(helpful_yes_raw AS UNSIGNED) > CAST(helpful_total_raw AS UNSIGNED)
          )
      );

    -- BX identifier and field validation.
    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        reason_detail
    )
    SELECT
        p_bx_book_run_id,
        'stg_bx_book',
        staging_bx_book_id,
        CASE
            WHEN NULLIF(TRIM(identifier_raw), '') IS NULL THEN 'missing_identifier'
            WHEN UPPER(TRIM(identifier_raw)) LIKE 'B0%' THEN 'unsupported_asin'
            ELSE 'invalid_isbn10'
        END,
        'BX metadata requires a valid ISBN-10 in the current project scope'
    FROM stg_bx_book
    WHERE ingestion_run_id = p_bx_book_run_id
      AND (
          NULLIF(TRIM(identifier_raw), '') IS NULL
          OR fn_is_valid_isbn10(identifier_raw) = 0
      );

    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        disposition,
        reason_detail
    )
    SELECT
        p_bx_book_run_id,
        'stg_bx_book',
        staging_bx_book_id,
        'invalid_published_year',
        'null_field',
        'Published year is not a plausible four-digit year and will be set to null'
    FROM stg_bx_book
    WHERE ingestion_run_id = p_bx_book_run_id
      AND NULLIF(TRIM(published_year_raw), '') IS NOT NULL
      AND CASE
          WHEN published_year_raw REGEXP '^[0-9]{4}([.]0+)?$'
              THEN CAST(published_year_raw AS DECIMAL(8, 2))
                  NOT BETWEEN 1450 AND YEAR(CURRENT_DATE) + 1
          ELSE TRUE
      END;

    -- Amazon metadata has no identifier, so title-to-identifier resolution is
    -- evaluated explicitly rather than hidden inside a CREATE TABLE AS SELECT.
    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        reason_detail
    )
    SELECT
        p_amazon_book_run_id,
        'stg_amazon_book',
        staging_amazon_book_id,
        'missing_title',
        'Amazon metadata cannot be resolved without a title'
    FROM stg_amazon_book
    WHERE ingestion_run_id = p_amazon_book_run_id
      AND NULLIF(TRIM(title_raw), '') IS NULL;

    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        disposition,
        reason_detail
    )
    SELECT
        p_amazon_book_run_id,
        'stg_amazon_book',
        staging_amazon_book_id,
        'invalid_published_year',
        'null_field',
        'Published year is not plausible and will be set to null'
    FROM stg_amazon_book
    WHERE ingestion_run_id = p_amazon_book_run_id
      AND NULLIF(TRIM(published_year_raw), '') IS NOT NULL
      AND CASE
          WHEN published_year_raw REGEXP '^[0-9]{4}$'
              THEN CAST(published_year_raw AS UNSIGNED)
                  NOT BETWEEN 1450 AND YEAR(CURRENT_DATE) + 1
          ELSE TRUE
      END;

    DROP TEMPORARY TABLE IF EXISTS tmp_title_identifier_map;
    CREATE TEMPORARY TABLE tmp_title_identifier_map AS
    SELECT
        TRIM(title_raw) AS title_key,
        MIN(UPPER(TRIM(identifier_raw))) AS isbn10,
        COUNT(DISTINCT UPPER(TRIM(identifier_raw))) AS identifier_count
    FROM stg_amazon_rating
    WHERE ingestion_run_id = p_amazon_rating_run_id
      AND fn_is_valid_isbn10(identifier_raw) = 1
      AND NULLIF(TRIM(title_raw), '') IS NOT NULL
    GROUP BY TRIM(title_raw);

    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        reason_detail
    )
    SELECT
        p_amazon_book_run_id,
        'stg_amazon_book',
        ab.staging_amazon_book_id,
        CASE
            WHEN tim.title_key IS NULL THEN 'unmatched_title'
            ELSE 'ambiguous_title_mapping'
        END,
        CASE
            WHEN tim.title_key IS NULL
                THEN 'No valid ISBN-10 in the ratings run has this exact title'
            ELSE 'The title maps to more than one valid ISBN-10'
        END
    FROM stg_amazon_book AS ab
    LEFT JOIN tmp_title_identifier_map AS tim
        ON tim.title_key = TRIM(ab.title_raw)
    WHERE ab.ingestion_run_id = p_amazon_book_run_id
      AND NULLIF(TRIM(ab.title_raw), '') IS NOT NULL
      AND (tim.title_key IS NULL OR tim.identifier_count <> 1);

    DROP TEMPORARY TABLE IF EXISTS tmp_valid_rating_ranked;
    CREATE TEMPORARY TABLE tmp_valid_rating_ranked AS
    SELECT
        sr.staging_rating_id,
        UPPER(TRIM(sr.identifier_raw)) AS isbn10,
        NULLIF(TRIM(sr.title_raw), '') AS title,
        TRIM(sr.user_id_raw) AS source_user_id,
        CAST(TRIM(sr.score_raw) AS DECIMAL(2, 1)) AS score,
        CASE
            WHEN NULLIF(TRIM(sr.review_time_raw), '') IS NULL THEN NULL
            ELSE STR_TO_DATE(sr.review_time_raw, '%Y-%m-%d')
        END AS review_time,
        NULLIF(TRIM(sr.review_summary_raw), '') AS review_summary,
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM rejected_record AS rr
                WHERE rr.ingestion_run_id = p_amazon_rating_run_id
                  AND rr.source_table = 'stg_amazon_rating'
                  AND rr.source_record_id = sr.staging_rating_id
                  AND rr.reason_code = 'invalid_helpfulness'
            ) THEN NULL
            WHEN sr.helpful_yes_raw REGEXP '^[0-9]+$'
                THEN CAST(sr.helpful_yes_raw AS UNSIGNED)
            ELSE NULL
        END AS helpful_yes,
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM rejected_record AS rr
                WHERE rr.ingestion_run_id = p_amazon_rating_run_id
                  AND rr.source_table = 'stg_amazon_rating'
                  AND rr.source_record_id = sr.staging_rating_id
                  AND rr.reason_code = 'invalid_helpfulness'
            ) THEN NULL
            WHEN sr.helpful_total_raw REGEXP '^[0-9]+$'
                THEN CAST(sr.helpful_total_raw AS UNSIGNED)
            ELSE NULL
        END AS helpful_total,
        ROW_NUMBER() OVER (
            PARTITION BY
                UPPER(TRIM(sr.identifier_raw)),
                TRIM(sr.user_id_raw)
            ORDER BY
                STR_TO_DATE(NULLIF(TRIM(sr.review_time_raw), ''), '%Y-%m-%d') DESC,
                sr.staging_rating_id DESC
        ) AS duplicate_rank
    FROM stg_amazon_rating AS sr
    WHERE sr.ingestion_run_id = p_amazon_rating_run_id
      AND NOT EXISTS (
          SELECT 1
          FROM rejected_record AS rr
          WHERE rr.ingestion_run_id = p_amazon_rating_run_id
            AND rr.source_table = 'stg_amazon_rating'
            AND rr.source_record_id = sr.staging_rating_id
            AND rr.disposition = 'reject_record'
      );

    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        reason_detail
    )
    SELECT
        p_amazon_rating_run_id,
        'stg_amazon_rating',
        staging_rating_id,
        'duplicate_user_book_rating',
        'A later review_time, then later staging row, wins deterministically'
    FROM tmp_valid_rating_ranked
    WHERE duplicate_rank > 1;

    DROP TEMPORARY TABLE IF EXISTS tmp_valid_rating;
    CREATE TEMPORARY TABLE tmp_valid_rating AS
    SELECT *
    FROM tmp_valid_rating_ranked
    WHERE duplicate_rank = 1;

    DROP TEMPORARY TABLE IF EXISTS tmp_rating_title;
    CREATE TEMPORARY TABLE tmp_rating_title AS
    SELECT isbn10, title
    FROM (
        SELECT
            isbn10,
            title,
            ROW_NUMBER() OVER (
                PARTITION BY isbn10
                ORDER BY COUNT(*) DESC, title ASC
            ) AS title_rank
        FROM tmp_valid_rating
        WHERE title IS NOT NULL
        GROUP BY isbn10, title
    ) AS ranked_title
    WHERE title_rank = 1;

    DROP TEMPORARY TABLE IF EXISTS tmp_bx_book;
    CREATE TEMPORARY TABLE tmp_bx_book AS
    SELECT *
    FROM (
        SELECT
            sb.staging_bx_book_id,
            UPPER(TRIM(sb.identifier_raw)) AS isbn10,
            NULLIF(TRIM(sb.title_raw), '') AS title,
            NULLIF(TRIM(sb.author_raw), '') AS author_text,
            NULLIF(TRIM(sb.publisher_raw), '') AS publisher_name,
            NULLIF(TRIM(sb.genre_raw), '') AS genre_text,
            CASE
                WHEN sb.published_year_raw REGEXP '^[0-9]{4}([.]0+)?$'
                 AND CAST(sb.published_year_raw AS DECIMAL(8, 2))
                     BETWEEN 1450 AND YEAR(CURRENT_DATE) + 1
                    THEN CAST(
                        CAST(sb.published_year_raw AS DECIMAL(8, 2))
                        AS UNSIGNED
                    )
                ELSE NULL
            END AS published_year,
            NULLIF(LOWER(TRIM(sb.language_raw)), '') AS language_code,
            ROW_NUMBER() OVER (
                PARTITION BY UPPER(TRIM(sb.identifier_raw))
                ORDER BY
                    (
                        (NULLIF(TRIM(sb.title_raw), '') IS NOT NULL)
                        + (NULLIF(TRIM(sb.author_raw), '') IS NOT NULL)
                        + (NULLIF(TRIM(sb.publisher_raw), '') IS NOT NULL)
                        + (NULLIF(TRIM(sb.genre_raw), '') IS NOT NULL)
                    ) DESC,
                    sb.staging_bx_book_id DESC
            ) AS metadata_rank
        FROM stg_bx_book AS sb
        WHERE sb.ingestion_run_id = p_bx_book_run_id
          AND NOT EXISTS (
              SELECT 1
              FROM rejected_record AS rr
              WHERE rr.ingestion_run_id = p_bx_book_run_id
                AND rr.source_table = 'stg_bx_book'
                AND rr.source_record_id = sb.staging_bx_book_id
                AND rr.disposition = 'reject_record'
          )
    ) AS ranked_bx
    WHERE metadata_rank = 1;

    DROP TEMPORARY TABLE IF EXISTS tmp_amazon_book;
    CREATE TEMPORARY TABLE tmp_amazon_book AS
    SELECT *
    FROM (
        SELECT
            ab.staging_amazon_book_id,
            tim.isbn10,
            NULLIF(TRIM(ab.title_raw), '') AS title,
            NULLIF(TRIM(ab.description_raw), '') AS description,
            NULLIF(TRIM(ab.author_raw), '') AS author_text,
            NULLIF(TRIM(ab.publisher_raw), '') AS publisher_name,
            NULLIF(TRIM(ab.genre_raw), '') AS genre_text,
            CASE
                WHEN ab.published_year_raw REGEXP '^[0-9]{4}$'
                 AND CAST(ab.published_year_raw AS UNSIGNED)
                     BETWEEN 1450 AND YEAR(CURRENT_DATE) + 1
                    THEN CAST(ab.published_year_raw AS UNSIGNED)
                ELSE NULL
            END AS published_year,
            ROW_NUMBER() OVER (
                PARTITION BY tim.isbn10
                ORDER BY
                    (
                        (NULLIF(TRIM(ab.description_raw), '') IS NOT NULL)
                        + (NULLIF(TRIM(ab.author_raw), '') IS NOT NULL)
                        + (NULLIF(TRIM(ab.publisher_raw), '') IS NOT NULL)
                        + (NULLIF(TRIM(ab.genre_raw), '') IS NOT NULL)
                    ) DESC,
                    ab.staging_amazon_book_id DESC
            ) AS metadata_rank
        FROM stg_amazon_book AS ab
        JOIN tmp_title_identifier_map AS tim
            ON tim.title_key = TRIM(ab.title_raw)
           AND tim.identifier_count = 1
        WHERE ab.ingestion_run_id = p_amazon_book_run_id
          AND NOT EXISTS (
              SELECT 1
              FROM rejected_record AS rr
              WHERE rr.ingestion_run_id = p_amazon_book_run_id
                AND rr.source_table = 'stg_amazon_book'
                AND rr.source_record_id = ab.staging_amazon_book_id
                AND rr.disposition = 'reject_record'
          )
    ) AS ranked_amazon
    WHERE metadata_rank = 1;

    DROP TEMPORARY TABLE IF EXISTS tmp_book_resolved;
    CREATE TEMPORARY TABLE tmp_book_resolved AS
    SELECT
        vr.isbn10,
        COALESCE(rt.title, ab.title, bx.title) AS title,
        ab.description,
        COALESCE(ab.author_text, bx.author_text) AS author_text,
        COALESCE(ab.publisher_name, bx.publisher_name) AS publisher_name,
        COALESCE(bx.genre_text, ab.genre_text) AS genre_text,
        COALESCE(bx.published_year, ab.published_year) AS published_year,
        bx.language_code,
        CASE
            WHEN ab.isbn10 IS NOT NULL AND bx.isbn10 IS NOT NULL THEN 'combined'
            WHEN ab.isbn10 IS NOT NULL THEN 'amazon_metadata'
            WHEN bx.isbn10 IS NOT NULL THEN 'bx_metadata'
            ELSE 'ratings'
        END AS metadata_source
    FROM (SELECT DISTINCT isbn10 FROM tmp_valid_rating) AS vr
    LEFT JOIN tmp_rating_title AS rt
        ON rt.isbn10 = vr.isbn10
    LEFT JOIN tmp_amazon_book AS ab
        ON ab.isbn10 = vr.isbn10
    LEFT JOIN tmp_bx_book AS bx
        ON bx.isbn10 = vr.isbn10;

    -- A missing or unreasonably long title rejects ratings for that book while
    -- preserving the staged source rows and a machine-readable explanation.
    INSERT INTO rejected_record (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code,
        reason_detail
    )
    SELECT
        p_amazon_rating_run_id,
        'stg_amazon_rating',
        vr.staging_rating_id,
        CASE
            WHEN NULLIF(TRIM(br.title), '') IS NULL THEN 'missing_book_title'
            ELSE 'title_too_long'
        END,
        CASE
            WHEN NULLIF(TRIM(br.title), '') IS NULL
                THEN 'No selected source supplied a nonblank title'
            ELSE 'Resolved title exceeds the 500-character core limit'
        END
    FROM tmp_valid_rating AS vr
    JOIN tmp_book_resolved AS br
        ON br.isbn10 = vr.isbn10
    WHERE NULLIF(TRIM(br.title), '') IS NULL
       OR CHAR_LENGTH(br.title) > 500;

    DROP TEMPORARY TABLE IF EXISTS tmp_eligible_book;
    CREATE TEMPORARY TABLE tmp_eligible_book AS
    SELECT *
    FROM tmp_book_resolved
    WHERE NULLIF(TRIM(title), '') IS NOT NULL
      AND CHAR_LENGTH(title) <= 500;

    DROP TEMPORARY TABLE IF EXISTS tmp_author_token;
    CREATE TEMPORARY TABLE tmp_author_token AS
    SELECT DISTINCT
        eb.isbn10,
        REGEXP_REPLACE(TRIM(j.author_name), '[[:space:]]+', ' ') AS author_name,
        LOWER(REGEXP_REPLACE(TRIM(j.author_name), '[[:space:]]+', ' ')) AS author_key
    FROM tmp_eligible_book AS eb
    JOIN JSON_TABLE(
        CASE
            WHEN eb.author_text IS NULL THEN JSON_ARRAY()
            ELSE CONCAT(
                '[',
                REPLACE(JSON_QUOTE(eb.author_text), ',', '","'),
                ']'
            )
        END,
        '$[*]' COLUMNS (
            author_name VARCHAR(1000) PATH '$'
        )
    ) AS j
    WHERE NULLIF(TRIM(j.author_name), '') IS NOT NULL
      AND CHAR_LENGTH(REGEXP_REPLACE(TRIM(j.author_name), '[[:space:]]+', ' ')) <= 500;

    DROP TEMPORARY TABLE IF EXISTS tmp_genre_token;
    CREATE TEMPORARY TABLE tmp_genre_token AS
    SELECT DISTINCT
        eb.isbn10,
        LOWER(REGEXP_REPLACE(TRIM(j.genre_name), '[[:space:]]+', ' ')) AS genre_name
    FROM tmp_eligible_book AS eb
    JOIN JSON_TABLE(
        CASE
            WHEN eb.genre_text IS NULL THEN JSON_ARRAY()
            ELSE CONCAT(
                '[',
                REPLACE(JSON_QUOTE(eb.genre_text), ',', '","'),
                ']'
            )
        END,
        '$[*]' COLUMNS (
            genre_name VARCHAR(1000) PATH '$'
        )
    ) AS j
    WHERE NULLIF(TRIM(j.genre_name), '') IS NOT NULL
      AND CHAR_LENGTH(REGEXP_REPLACE(TRIM(j.genre_name), '[[:space:]]+', ' ')) <= 255;

    -- Full refresh is intentional for these static public snapshots. Repeating
    -- the transformation cannot multiply core rows.
    DELETE FROM book_genre;
    DELETE FROM book_author;
    DELETE FROM rating;
    DELETE FROM book;
    DELETE FROM reader;
    DELETE FROM genre;
    DELETE FROM author;
    DELETE FROM publisher;

    INSERT INTO publisher (publisher_name, publisher_key)
    SELECT DISTINCT
        REGEXP_REPLACE(TRIM(publisher_name), '[[:space:]]+', ' '),
        LOWER(REGEXP_REPLACE(TRIM(publisher_name), '[[:space:]]+', ' '))
    FROM tmp_eligible_book
    WHERE NULLIF(TRIM(publisher_name), '') IS NOT NULL
      AND CHAR_LENGTH(REGEXP_REPLACE(TRIM(publisher_name), '[[:space:]]+', ' ')) <= 500;

    INSERT INTO book (
        isbn10,
        publisher_id,
        title,
        description,
        published_year,
        language_code,
        metadata_source
    )
    SELECT
        eb.isbn10,
        p.publisher_id,
        eb.title,
        eb.description,
        eb.published_year,
        LEFT(eb.language_code, 10),
        eb.metadata_source
    FROM tmp_eligible_book AS eb
    LEFT JOIN publisher AS p
        ON p.publisher_key =
            LOWER(REGEXP_REPLACE(TRIM(eb.publisher_name), '[[:space:]]+', ' '));

    INSERT INTO reader (source_user_id)
    SELECT DISTINCT vr.source_user_id
    FROM tmp_valid_rating AS vr
    JOIN tmp_eligible_book AS eb
        ON eb.isbn10 = vr.isbn10;

    INSERT INTO rating (
        book_id,
        reader_id,
        score,
        review_time,
        review_summary,
        helpful_yes,
        helpful_total,
        source_staging_rating_id
    )
    SELECT
        b.book_id,
        rd.reader_id,
        vr.score,
        vr.review_time,
        vr.review_summary,
        vr.helpful_yes,
        vr.helpful_total,
        vr.staging_rating_id
    FROM tmp_valid_rating AS vr
    JOIN book AS b
        ON b.isbn10 = vr.isbn10
    JOIN reader AS rd
        ON rd.source_user_id = vr.source_user_id;

    INSERT INTO author (author_name, author_key)
    SELECT
        MIN(author_name) AS author_name,
        author_key
    FROM tmp_author_token
    GROUP BY author_key;

    INSERT INTO book_author (book_id, author_id)
    SELECT DISTINCT b.book_id, a.author_id
    FROM tmp_author_token AS at
    JOIN book AS b
        ON b.isbn10 = at.isbn10
    JOIN author AS a
        ON a.author_key = at.author_key;

    INSERT INTO genre (genre_name, canonical_genre)
    SELECT
        gt.genre_name,
        CASE
            WHEN gt.genre_name LIKE '%science fiction%'
              OR gt.genre_name LIKE '%sci-fi%'
              OR gt.genre_name LIKE '%scifi%' THEN 'sci-fi'
            WHEN gt.genre_name LIKE '%juvenile fiction%'
              OR gt.genre_name LIKE '%children%'
              OR gt.genre_name LIKE '%picture book%' THEN 'children'
            WHEN gt.genre_name LIKE '%young adult%'
              OR gt.genre_name LIKE '%teen%' THEN 'young-adult'
            WHEN gt.genre_name LIKE '%romance%' THEN 'romance'
            WHEN gt.genre_name LIKE '%fantasy%' THEN 'fantasy'
            WHEN gt.genre_name LIKE '%mystery%'
              OR gt.genre_name LIKE '%detective%' THEN 'mystery'
            WHEN gt.genre_name LIKE '%thriller%'
              OR gt.genre_name LIKE '%suspense%' THEN 'thriller'
            WHEN gt.genre_name LIKE '%horror%' THEN 'horror'
            WHEN gt.genre_name LIKE '%biograph%'
              OR gt.genre_name LIKE '%memoir%' THEN 'biography'
            WHEN gt.genre_name LIKE '%histor%' THEN 'history'
            WHEN gt.genre_name LIKE '%business%'
              OR gt.genre_name LIKE '%econom%'
              OR gt.genre_name LIKE '%finance%' THEN 'business-economics'
            WHEN gt.genre_name LIKE '%health%'
              OR gt.genre_name LIKE '%fitness%'
              OR gt.genre_name LIKE '%nutrition%' THEN 'health-fitness'
            WHEN gt.genre_name LIKE '%medical%'
              OR gt.genre_name LIKE '%medicine%' THEN 'medical'
            WHEN gt.genre_name LIKE '%psychology%' THEN 'psychology'
            WHEN gt.genre_name LIKE '%self-help%'
              OR gt.genre_name LIKE '%self help%' THEN 'self-help'
            WHEN gt.genre_name LIKE '%religion%'
              OR gt.genre_name LIKE '%spiritual%'
              OR gt.genre_name LIKE '%christian%' THEN 'religion-spirituality'
            WHEN gt.genre_name LIKE '%computer%'
              OR gt.genre_name LIKE '%programming%'
              OR gt.genre_name LIKE '%software%'
              OR gt.genre_name LIKE '%technology%' THEN 'technology-computers'
            WHEN gt.genre_name LIKE '%science%' THEN 'science'
            WHEN gt.genre_name LIKE '%fiction%' THEN 'fiction'
            ELSE 'other'
        END AS canonical_genre
    FROM (SELECT DISTINCT genre_name FROM tmp_genre_token) AS gt;

    INSERT INTO book_genre (book_id, genre_id)
    SELECT DISTINCT b.book_id, g.genre_id
    FROM tmp_genre_token AS gt
    JOIN book AS b
        ON b.isbn10 = gt.isbn10
    JOIN genre AS g
        ON g.genre_name = gt.genre_name;

    SELECT COUNT(*) INTO v_books_loaded FROM book;
    SELECT COUNT(*) INTO v_ratings_loaded FROM rating;

    UPDATE ingestion_run AS ir
    SET rows_rejected = (
        SELECT COUNT(DISTINCT rr.source_record_id)
        FROM rejected_record AS rr
        WHERE rr.ingestion_run_id = ir.ingestion_run_id
          AND rr.disposition = 'reject_record'
    )
    WHERE ir.ingestion_run_id IN (
        p_amazon_rating_run_id,
        p_amazon_book_run_id,
        p_bx_book_run_id
    );

    COMMIT;

    UPDATE transformation_run
    SET
        status = 'succeeded',
        finished_at = CURRENT_TIMESTAMP(6),
        books_loaded = v_books_loaded,
        ratings_loaded = v_ratings_loaded
    WHERE transformation_run_id = v_transformation_run_id;
END$$

DELIMITER ;

-- Use the latest completed run for each required source. The procedure checks
-- the source name and state again before changing core data.
SET @amazon_rating_run_id = (
    SELECT MAX(ingestion_run_id)
    FROM ingestion_run
    WHERE source_name = 'amazon_ratings' AND status = 'loaded'
);
SET @amazon_book_run_id = (
    SELECT MAX(ingestion_run_id)
    FROM ingestion_run
    WHERE source_name = 'amazon_books' AND status = 'loaded'
);
SET @bx_book_run_id = (
    SELECT MAX(ingestion_run_id)
    FROM ingestion_run
    WHERE source_name = 'bx_books' AND status = 'loaded'
);

CALL sp_refresh_core(
    @amazon_rating_run_id,
    @amazon_book_run_id,
    @bx_book_run_id
);
