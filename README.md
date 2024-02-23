# Reputation Tracker

1. [About](#about)
1. [Setup](#setup)
1. [Block processing](#block-processing)
1. [Tests](#tests)

## About

Reputation Tracker app is used to calculate reputation for Hive account by increment of block or time.

## Setup

Like all HAF apps, Reputation Tracker must be installed on a HAF server.
The easiest and recommended way to setup and maintain a HAF server and apps is using the scripts in this repo: https://gitlab.syncad.com/hive/haf_api_node/ - reputation_tracker is not yet supported.

For manual instalation of Reputation Tracker on HAF server you need to:

install reputation_tracker on the database:

```bash
./scripts/install_app.sh
```

You can use `./scripts/install_app.sh --help` to see available options.

If you want to uninstall reputation_tracker and remove its data from the database:

```bash
./scripts/uninstall_app.sh
```

As before, use `./scripts/uninstall_app.sh --help` to see available options.

## Block processing

Before it can be used, reputation_tracker needs to process blocks available in HAF database.

```bash
./scripts/process_blocks.sh
```

Again, you can use `./scripts/process_blocks.sh --help` to see available options.

## Test

Run account reputation verifying test by running the following commands:

```
cd tests/

./account_dump_test.sh 

```
You can see all test options using command `./tests/account_dump_test.sh --help`

After the tests are completed, a report will be generated at `tests/account_dump_test.log`
