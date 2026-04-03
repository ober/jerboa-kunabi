# jerboa-kunabi

A CloudTrail log analyzer built in Jerboa Scheme (Chez Scheme). Downloads AWS CloudTrail logs from S3, stores them in LevelDB with multi-index support, and provides querying, security detection, and billing impact analysis.

This is a port of [kunabi](https://github.com/ober/kunabi) from Gerbil Scheme to Jerboa.

## Features

- **S3 Loader**: Download CloudTrail logs from S3 with parallel workers
- **Multi-Index Storage**: LevelDB with indices on user, event, date, region, error
- **Security Detection**: 65+ rules for suspicious activity (persistence, covering tracks, exfiltration)
- **Billing Analysis**: 100+ rules for cost-impacting operations
- **Query Engine**: Fast index-based lookups with date range filtering
- **Full-Text Search**: Search across all stored events
- **Static Binary**: Self-contained ELF binary with embedded boot files

## Building

### Option 1: Docker Build (Recommended)

Build a fully static musl binary with no runtime dependencies:

```bash
make kunabi-musl
```

This creates `kunabi-musl` - a single-file static binary that runs on any Linux system.

### Option 2: Dynamic Binary

Build a binary that links against system libraries:

```bash
# Install dependencies (Ubuntu/Debian)
sudo apt install libleveldb-dev libssl-dev zlib1g-dev liblz4-dev libncurses-dev uuid-dev

# Build
make binary
```

Run:
```bash
./kunabi help
```

### Option 3: Development Mode

```bash
make ffi compile
make run ARGS="help"
```

## Prerequisites (Dynamic Build Only)

### System Libraries

| Library | Purpose |
|---------|---------|
| `libleveldb` | Key-value database storage |
| `libstdc++` | Required by LevelDB |
| `libssl`, `libcrypto` | TLS/SSL for S3 access |
| `libz` | Gzip decompression of CloudTrail logs |
| `libyaml` | YAML config parsing |

### Chez Scheme

Requires [Chez Scheme](https://cisco.github.io/ChezScheme/) 10.x.

### Required Libraries

- [jerboa](https://github.com/ober/jerboa) — Jerboa Scheme runtime
- [gherkin](https://github.com/ober/gherkin) — Gherkin Scheme runtime
- [jerboa-aws](https://github.com/ober/jerboa-aws) — AWS client (S3, credentials)
- [chez-leveldb](https://github.com/ober/chez-leveldb) — LevelDB bindings
- [chez-yaml](https://github.com/ober/chez-yaml) — YAML parsing
- [chez-zlib](https://github.com/ober/chez-zlib) — Gzip decompression
- [chez-ssl](https://github.com/ober/chez-ssl) — SSL/TLS bindings
- [chez-https](https://github.com/ober/chez-https) — HTTPS client

### AWS Credentials

S3 access uses the standard AWS credential chain via `jerboa-aws`. Configure credentials through:

- `~/.aws/credentials` file
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variables
- IAM instance roles (EC2/ECS)

## Usage

```bash
# Show help
./kunabi help

# Load CloudTrail logs from S3
./kunabi load --bucket my-cloudtrail-bucket --prefix AWSLogs/123456789012/CloudTrail
./kunabi load --workers 32 --verbose  # More parallelism, show progress

# Query events
./kunabi report --user admin --start 2024-01-01 --end 2024-01-31
./kunabi report --event RunInstances --summary
./kunabi report --error AccessDenied --summary --warnings

# Security detection
./kunabi detect                           # All rules
./kunabi detect --severity CRITICAL       # Critical only
./kunabi detect --category "Persistence/Backdoor"
./kunabi detect --summary                 # Summary view

# Billing analysis
./kunabi billing                          # All billing events
./kunabi billing --service EC2            # EC2 only
./kunabi billing --impact "Cost Increase" # New costs only
./kunabi billing --summary

# List unique values
./kunabi list users
./kunabi list events
./kunabi list dates
./kunabi list regions

# Full-text search
./kunabi search "AccessDenied" --limit 100
./kunabi search "i-0123456789abcdef" --case-insensitive

# Get single event
./kunabi get <event-id>

# Maintenance
./kunabi purge 2023-01-01 --dry-run       # Preview deletion
./kunabi purge 2023-01-01                  # Delete old events
./kunabi compact                           # Strip response elements
./kunabi leveldb-compact                   # Trigger DB compaction
./kunabi reindex                           # Build composite indices
```

## Configuration

Create `~/.kunabi.yaml`:

```yaml
bucket: my-cloudtrail-bucket
prefix: AWSLogs/123456789012/CloudTrail
db: ./cloudtrail.db
regions:
  - us-east-1
  - us-west-2
duration: 7  # days
omit:
  events:
    - DescribeInstances  # Noisy events to skip
  filters:
    - { user: "monitoring-user" }  # Skip monitoring account
```

## Project Structure

```
jerboa-kunabi/
  README.md
  Makefile
  Dockerfile              # Docker build for static binary
  build-kunabi.ss         # Dynamic binary build script
  build-kunabi-musl.ss    # Static musl binary build script
  build-kunabi-musl.sh    # Shell wrapper for musl build
  kunabi.ss               # CLI entry point
  kunabi-main.c           # C entry point for dynamic binary
  lib/
    kunabi/
      config.sls          # Configuration loader
      parser.sls          # CloudTrail JSON parser
      storage.sls         # LevelDB storage engine
      loader.sls          # S3 download with worker pool
      query.sls           # Query engine
      detection.sls       # Security detection rules
      billing.sls         # Billing impact rules
```

## Differences from Gerbil Version

- Uses Jerboa's `(jerboa prelude)` for core macros and runtime
- Uses `jerboa-aws` for S3 client (pure Jerboa/Chez implementation)
- Uses `chez-yaml` instead of `gerbil-libyaml` (pure Scheme YAML parser)
- Uses Chez threads (`fork-thread`) instead of Gerbil's `spawn`
- Uses Jerboa's `Result` type for error handling where appropriate
- Uses Jerboa's iterator macros (`for`, `for/collect`, `for/fold`)

## License

ISC
