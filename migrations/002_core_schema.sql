-- Normalized core schema.

DROP FUNCTION IF EXISTS fn_is_valid_isbn10;

DELIMITER $$

CREATE FUNCTION fn_is_valid_isbn10 (p_identifier VARCHAR(64))
RETURNS TINYINT
DETERMINISTIC
NO SQL
BEGIN
    DECLARE v_isbn CHAR(10);
    DECLARE v_checksum INT;

    SET v_isbn = UPPER(TRIM(p_identifier));

    IF v_isbn IS NULL OR v_isbn NOT REGEXP '^[0-9]{9}[0-9X]$' THEN
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

CREATE TABLE publisher (
    publisher_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    publisher_name VARCHAR(500) NOT NULL,
    publisher_key VARCHAR(500) NOT NULL,
    PRIMARY KEY (publisher_id),
    UNIQUE KEY uq_publisher_key (publisher_key)
) ENGINE = InnoDB;

CREATE TABLE author (
    author_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    author_name VARCHAR(500) NOT NULL,
    author_key VARCHAR(500) NOT NULL,
    PRIMARY KEY (author_id),
    UNIQUE KEY uq_author_key (author_key)
) ENGINE = InnoDB;

CREATE TABLE genre (
    genre_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    genre_name VARCHAR(255) NOT NULL,
    canonical_genre VARCHAR(100) NOT NULL,
    PRIMARY KEY (genre_id),
    UNIQUE KEY uq_genre_name (genre_name)
) ENGINE = InnoDB;

CREATE TABLE book (
    book_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    isbn10 CHAR(10) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    publisher_id BIGINT UNSIGNED NULL,
    title VARCHAR(500) NOT NULL,
    description MEDIUMTEXT NULL,
    published_year SMALLINT UNSIGNED NULL,
    language_code VARCHAR(10) NULL,
    metadata_source ENUM (
        'ratings',
        'amazon_metadata',
        'bx_metadata',
        'combined'
    ) NOT NULL,
    PRIMARY KEY (book_id),
    UNIQUE KEY uq_book_isbn10 (isbn10),
    CONSTRAINT fk_book_publisher
        FOREIGN KEY (publisher_id)
        REFERENCES publisher (publisher_id)
        ON DELETE SET NULL,
    CONSTRAINT chk_book_isbn10_length
        CHECK (CHAR_LENGTH(isbn10) = 10),
    CONSTRAINT chk_book_published_year
        CHECK (published_year IS NULL OR published_year BETWEEN 1450 AND 2200)
) ENGINE = InnoDB;

CREATE TABLE reader (
    reader_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    source_user_id VARCHAR(50) NOT NULL,
    PRIMARY KEY (reader_id),
    UNIQUE KEY uq_reader_source_user_id (source_user_id)
) ENGINE = InnoDB;

CREATE TABLE rating (
    book_id BIGINT UNSIGNED NOT NULL,
    reader_id BIGINT UNSIGNED NOT NULL,
    score DECIMAL(2, 1) NOT NULL,
    review_time DATE NULL,
    review_summary TEXT NULL,
    helpful_yes INT UNSIGNED NULL,
    helpful_total INT UNSIGNED NULL,
    source_staging_rating_id BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (book_id, reader_id),
    UNIQUE KEY uq_rating_source_record (source_staging_rating_id),
    CONSTRAINT fk_rating_book
        FOREIGN KEY (book_id)
        REFERENCES book (book_id),
    CONSTRAINT fk_rating_reader
        FOREIGN KEY (reader_id)
        REFERENCES reader (reader_id),
    CONSTRAINT fk_rating_source_record
        FOREIGN KEY (source_staging_rating_id)
        REFERENCES stg_amazon_rating (staging_rating_id),
    CONSTRAINT chk_rating_score
        CHECK (score BETWEEN 1.0 AND 5.0),
    CONSTRAINT chk_rating_helpfulness
        CHECK (
            helpful_yes IS NULL
            OR helpful_total IS NULL
            OR helpful_yes <= helpful_total
        )
) ENGINE = InnoDB;

CREATE TABLE book_author (
    book_id BIGINT UNSIGNED NOT NULL,
    author_id BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (book_id, author_id),
    KEY idx_book_author_author (author_id, book_id),
    CONSTRAINT fk_book_author_book
        FOREIGN KEY (book_id)
        REFERENCES book (book_id),
    CONSTRAINT fk_book_author_author
        FOREIGN KEY (author_id)
        REFERENCES author (author_id)
) ENGINE = InnoDB;

CREATE TABLE book_genre (
    book_id BIGINT UNSIGNED NOT NULL,
    genre_id BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (book_id, genre_id),
    KEY idx_book_genre_genre (genre_id, book_id),
    CONSTRAINT fk_book_genre_book
        FOREIGN KEY (book_id)
        REFERENCES book (book_id),
    CONSTRAINT fk_book_genre_genre
        FOREIGN KEY (genre_id)
        REFERENCES genre (genre_id)
) ENGINE = InnoDB;
