-- Representative analytical workload, not a validated recommender.
-- Replace the ISBN below with a valid value from the loaded core.
SET @seed_isbn10 = '0826414346';
SET @positive_score = 4.0;
SET @minimum_shared_readers = 5;

WITH seed_book AS (
    SELECT book_id
    FROM book
    WHERE isbn10 = @seed_isbn10
),
positive_seed_readers AS (
    SELECT r.reader_id
    FROM rating AS r
    JOIN seed_book AS sb
        ON sb.book_id = r.book_id
    WHERE r.score >= @positive_score
),
candidate_scores AS (
    SELECT
        r.book_id,
        COUNT(DISTINCT r.reader_id) AS shared_positive_readers,
        ROUND(AVG(r.score), 2) AS average_candidate_score
    FROM positive_seed_readers AS psr
    JOIN rating AS r
        ON r.reader_id = psr.reader_id
       AND r.score >= @positive_score
    WHERE NOT EXISTS (
        SELECT 1
        FROM seed_book AS sb
        WHERE sb.book_id = r.book_id
    )
    GROUP BY r.book_id
    HAVING COUNT(DISTINCT r.reader_id) >= @minimum_shared_readers
)
SELECT
    b.isbn10,
    b.title,
    cs.shared_positive_readers,
    cs.average_candidate_score,
    GROUP_CONCAT(
        DISTINCT vbg.canonical_genre
        ORDER BY vbg.canonical_genre
        SEPARATOR ', '
    ) AS canonical_genres
FROM candidate_scores AS cs
JOIN book AS b
    ON b.book_id = cs.book_id
LEFT JOIN v_book_genre_canonical AS vbg
    ON vbg.book_id = b.book_id
GROUP BY
    b.book_id,
    b.isbn10,
    b.title,
    cs.shared_positive_readers,
    cs.average_candidate_score
ORDER BY
    cs.shared_positive_readers DESC,
    cs.average_candidate_score DESC,
    b.isbn10
LIMIT 10;
