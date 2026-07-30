# Local source files

The full source snapshots are intentionally not stored in Git. Before running
the loader, place these files under `data/raw/`:

| File | Expected header |
| --- | --- |
| `amazon_books_ratings_clean_2.csv` | `isbn,title,user_id,score,review_time,review_summary,helpful_yes,helpful_total` |
| `amazon_books_data_clean.csv` | `title,description,author,publisher,genre,published_year` |
| `bx_preprocessed_clean.csv` | `isbn,title,author,published_year,publisher,language,genre` |

The historical local snapshots were approximately 312 MB, 111 MB, and 30 MB.
They are not copied by the reconstruction process.

The `isbn` heading in the ratings snapshot is historically misleading: it
contains both ISBN-like values and Amazon ASIN values. The transformation
validates ISBN-10 format and checksum and records `B0%` values as
`unsupported_asin`.

## CSV assumptions

- UTF-8-compatible text
- comma-separated fields
- double-quoted fields where needed
- one header row
- either LF or CRLF line endings

The loader stages risky numeric and date fields as strings. Validation and type
conversion happen in the transformation script, so malformed values can be
audited instead of aborting the entire file load.

## Redistribution

Do not commit the full snapshots until each upstream source, license, and
redistribution condition has been documented. A small synthetic or
redistributable sample should eventually be added for CI.
