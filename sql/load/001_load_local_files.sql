-- Run from the repository root with LOCAL INFILE enabled:
-- mysql --local-infile=1 ... < sql/load/001_load_local_files.sql
--
-- Raw files are intentionally gitignored. Keep the three expected filenames
-- under data/raw/, or edit only the paths below for your local environment.

INSERT INTO ingestion_run (source_name, source_file)
VALUES ('amazon_ratings', 'data/raw/amazon_books_ratings_clean_2.csv');
SET @amazon_rating_run_id = LAST_INSERT_ID();

LOAD DATA LOCAL INFILE 'data/raw/amazon_books_ratings_clean_2.csv'
INTO TABLE stg_amazon_rating
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
ESCAPED BY '\\'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES
(
    identifier_raw,
    title_raw,
    user_id_raw,
    score_raw,
    review_time_raw,
    review_summary_raw,
    helpful_yes_raw,
    @helpful_total_raw
)
SET
    ingestion_run_id = @amazon_rating_run_id,
    helpful_total_raw = NULLIF(TRIM(TRAILING '\r' FROM @helpful_total_raw), '');

SET @amazon_rating_rows = ROW_COUNT();
UPDATE ingestion_run
SET
    status = 'loaded',
    rows_loaded = @amazon_rating_rows,
    finished_at = CURRENT_TIMESTAMP(6)
WHERE ingestion_run_id = @amazon_rating_run_id;

INSERT INTO ingestion_run (source_name, source_file)
VALUES ('amazon_books', 'data/raw/amazon_books_data_clean.csv');
SET @amazon_book_run_id = LAST_INSERT_ID();

LOAD DATA LOCAL INFILE 'data/raw/amazon_books_data_clean.csv'
INTO TABLE stg_amazon_book
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
ESCAPED BY '\\'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES
(
    title_raw,
    description_raw,
    author_raw,
    publisher_raw,
    genre_raw,
    @published_year_raw
)
SET
    ingestion_run_id = @amazon_book_run_id,
    published_year_raw = NULLIF(TRIM(TRAILING '\r' FROM @published_year_raw), '');

SET @amazon_book_rows = ROW_COUNT();
UPDATE ingestion_run
SET
    status = 'loaded',
    rows_loaded = @amazon_book_rows,
    finished_at = CURRENT_TIMESTAMP(6)
WHERE ingestion_run_id = @amazon_book_run_id;

INSERT INTO ingestion_run (source_name, source_file)
VALUES ('bx_books', 'data/raw/bx_preprocessed_clean.csv');
SET @bx_book_run_id = LAST_INSERT_ID();

LOAD DATA LOCAL INFILE 'data/raw/bx_preprocessed_clean.csv'
INTO TABLE stg_bx_book
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
ESCAPED BY '\\'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES
(
    identifier_raw,
    title_raw,
    author_raw,
    published_year_raw,
    publisher_raw,
    language_raw,
    @genre_raw
)
SET
    ingestion_run_id = @bx_book_run_id,
    genre_raw = NULLIF(TRIM(TRAILING '\r' FROM @genre_raw), '');

SET @bx_book_rows = ROW_COUNT();
UPDATE ingestion_run
SET
    status = 'loaded',
    rows_loaded = @bx_book_rows,
    finished_at = CURRENT_TIMESTAMP(6)
WHERE ingestion_run_id = @bx_book_run_id;
