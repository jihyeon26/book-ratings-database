# Synthetic sample data

These CSV files are original synthetic fixtures for local tests and CI. They
do not reproduce rows from the full source snapshots.

The sample intentionally includes:

- valid ISBN-10 ratings and metadata;
- an unsupported Amazon ASIN;
- an invalid ISBN-10 checksum and an ISBN-13 value;
- a repeated reader-book rating with a deterministic winner;
- invalid score, date, user ID, helpfulness, and publication year values;
- unmatched and ambiguous title-based metadata;
- a valid rating whose book title cannot be resolved.

Expected core results after transformation:

| Object | Rows |
| --- | ---: |
| `book` | 4 |
| `reader` | 4 |
| `rating` | 5 |
| `book_author` | 4 |
| `book_genre` | 4 |

Run the complete two-pass test from the repository root with a MySQL client
that has `LOCAL INFILE` enabled:

```sql
SOURCE tests/run_sample_idempotency.sql;
```

The runner uses and recreates only the database named `bookdb_sample_test`.
