-- Serving views and indexes justified by the representative co-occurrence
-- workload. The primary keys already cover book-first equality lookups.

CREATE INDEX idx_rating_reader_score_book
    ON rating (reader_id, score, book_id);

CREATE INDEX idx_rating_book_score_reader
    ON rating (book_id, score, reader_id);

CREATE OR REPLACE VIEW v_book_genre_canonical AS
SELECT DISTINCT
    b.book_id,
    b.isbn10,
    b.title,
    g.canonical_genre
FROM book AS b
JOIN book_genre AS bg
    ON bg.book_id = b.book_id
JOIN genre AS g
    ON g.genre_id = bg.genre_id;

CREATE OR REPLACE VIEW v_book_rating_stats AS
SELECT
    b.book_id,
    b.isbn10,
    b.title,
    COUNT(r.reader_id) AS rating_count,
    ROUND(AVG(r.score), 2) AS average_score
FROM book AS b
LEFT JOIN rating AS r
    ON r.book_id = b.book_id
GROUP BY
    b.book_id,
    b.isbn10,
    b.title;
