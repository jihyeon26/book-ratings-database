-- Operational metadata and lossless staging tables.
-- Target: MySQL 8.4 / InnoDB / utf8mb4.

CREATE TABLE ingestion_run (
    ingestion_run_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    source_name VARCHAR(64) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    source_sha256 CHAR(64) NULL,
    started_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    finished_at DATETIME(6) NULL,
    status ENUM ('loading', 'loaded', 'failed') NOT NULL DEFAULT 'loading',
    rows_loaded BIGINT UNSIGNED NOT NULL DEFAULT 0,
    rows_rejected BIGINT UNSIGNED NOT NULL DEFAULT 0,
    error_message VARCHAR(1000) NULL,
    PRIMARY KEY (ingestion_run_id),
    KEY idx_ingestion_run_source_status (source_name, status, ingestion_run_id),
    CONSTRAINT chk_ingestion_run_sha256
        CHECK (source_sha256 IS NULL OR source_sha256 REGEXP '^[0-9a-fA-F]{64}$')
) ENGINE = InnoDB;

CREATE TABLE rejected_record (
    rejected_record_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    ingestion_run_id BIGINT UNSIGNED NOT NULL,
    source_table VARCHAR(64) NOT NULL,
    source_record_id BIGINT UNSIGNED NOT NULL,
    reason_code VARCHAR(64) NOT NULL,
    disposition ENUM ('reject_record', 'null_field') NOT NULL DEFAULT 'reject_record',
    reason_detail VARCHAR(1000) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (rejected_record_id),
    UNIQUE KEY uq_rejected_record_rule (
        ingestion_run_id,
        source_table,
        source_record_id,
        reason_code
    ),
    KEY idx_rejected_record_run_disposition (ingestion_run_id, disposition),
    CONSTRAINT fk_rejected_record_ingestion_run
        FOREIGN KEY (ingestion_run_id)
        REFERENCES ingestion_run (ingestion_run_id)
) ENGINE = InnoDB;

CREATE TABLE transformation_run (
    transformation_run_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    amazon_rating_run_id BIGINT UNSIGNED NOT NULL,
    amazon_book_run_id BIGINT UNSIGNED NOT NULL,
    bx_book_run_id BIGINT UNSIGNED NOT NULL,
    started_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    finished_at DATETIME(6) NULL,
    status ENUM ('running', 'succeeded', 'failed') NOT NULL DEFAULT 'running',
    books_loaded BIGINT UNSIGNED NOT NULL DEFAULT 0,
    ratings_loaded BIGINT UNSIGNED NOT NULL DEFAULT 0,
    error_message VARCHAR(1000) NULL,
    PRIMARY KEY (transformation_run_id),
    KEY idx_transformation_run_status (status, transformation_run_id),
    CONSTRAINT fk_transformation_amazon_rating_run
        FOREIGN KEY (amazon_rating_run_id)
        REFERENCES ingestion_run (ingestion_run_id),
    CONSTRAINT fk_transformation_amazon_book_run
        FOREIGN KEY (amazon_book_run_id)
        REFERENCES ingestion_run (ingestion_run_id),
    CONSTRAINT fk_transformation_bx_book_run
        FOREIGN KEY (bx_book_run_id)
        REFERENCES ingestion_run (ingestion_run_id)
) ENGINE = InnoDB;

-- Values remain strings in staging so malformed source values are observable
-- and do not abort bulk loading before validation can classify them.
CREATE TABLE stg_amazon_rating (
    staging_rating_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    ingestion_run_id BIGINT UNSIGNED NOT NULL,
    identifier_raw VARCHAR(64) NULL,
    title_raw TEXT NULL,
    user_id_raw VARCHAR(255) NULL,
    score_raw VARCHAR(32) NULL,
    review_time_raw VARCHAR(64) NULL,
    review_summary_raw TEXT NULL,
    helpful_yes_raw VARCHAR(32) NULL,
    helpful_total_raw VARCHAR(32) NULL,
    PRIMARY KEY (staging_rating_id),
    KEY idx_stg_amazon_rating_run_identifier (
        ingestion_run_id,
        identifier_raw
    ),
    KEY idx_stg_amazon_rating_run_user (
        ingestion_run_id,
        user_id_raw
    ),
    CONSTRAINT fk_stg_amazon_rating_run
        FOREIGN KEY (ingestion_run_id)
        REFERENCES ingestion_run (ingestion_run_id)
) ENGINE = InnoDB;

CREATE TABLE stg_amazon_book (
    staging_amazon_book_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    ingestion_run_id BIGINT UNSIGNED NOT NULL,
    title_raw TEXT NULL,
    description_raw LONGTEXT NULL,
    author_raw TEXT NULL,
    publisher_raw VARCHAR(1000) NULL,
    genre_raw TEXT NULL,
    published_year_raw VARCHAR(64) NULL,
    PRIMARY KEY (staging_amazon_book_id),
    KEY idx_stg_amazon_book_run (ingestion_run_id),
    CONSTRAINT fk_stg_amazon_book_run
        FOREIGN KEY (ingestion_run_id)
        REFERENCES ingestion_run (ingestion_run_id)
) ENGINE = InnoDB;

CREATE TABLE stg_bx_book (
    staging_bx_book_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    ingestion_run_id BIGINT UNSIGNED NOT NULL,
    identifier_raw VARCHAR(64) NULL,
    title_raw TEXT NULL,
    author_raw TEXT NULL,
    published_year_raw VARCHAR(64) NULL,
    publisher_raw VARCHAR(1000) NULL,
    language_raw VARCHAR(64) NULL,
    genre_raw TEXT NULL,
    PRIMARY KEY (staging_bx_book_id),
    KEY idx_stg_bx_book_run_identifier (
        ingestion_run_id,
        identifier_raw
    ),
    CONSTRAINT fk_stg_bx_book_run
        FOREIGN KEY (ingestion_run_id)
        REFERENCES ingestion_run (ingestion_run_id)
) ENGINE = InnoDB;
