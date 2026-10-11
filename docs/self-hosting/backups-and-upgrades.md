---
sidebar_position: 7
title: "Backups and upgrades"
description: "Back up and restore the OpenCaptions database and storage, and update a running installation safely."
---

# Backups and upgrades

## What to back up

Two things hold your data: the Postgres database (accounts, projects, transcripts, styles) and the object
store (the videos, thumbnails, exports and downloaded fonts). The speech models in `models/` can be
downloaded again, and the queue holds nothing worth keeping.

## Back up and restore

In a clone of the repository, two Make targets do it:

```bash
make backup                       # writes backups/db-<time>.sql and backups/storage-<time>.tar.gz
make restore TS=20261011-143000   # restores that snapshot (asks first, and OVERWRITES what is there)
```

With only the compose file, the same thing is these commands, run in the folder that holds it:

```bash
TS=$(date +%Y%m%d-%H%M%S); mkdir -p backups

# The database
docker compose exec -T postgres pg_dump -U opencaptions opencaptions > backups/db-$TS.sql

# The storage, read through the storage container's own mounts
docker run --rm --volumes-from "$(docker compose ps -aq garage)" -v "$PWD/backups:/backups" alpine \
  sh -c "tar -czf /backups/storage-$TS.tar.gz -C /var/lib/garage ."
```

To restore, stop the storage, put the data back, and start it again:

```bash
docker compose exec -T postgres psql -U opencaptions -d postgres \
  -c 'DROP DATABASE IF EXISTS opencaptions WITH (FORCE);' -c 'CREATE DATABASE opencaptions;'
docker compose exec -T postgres psql -U opencaptions opencaptions < backups/db-$TS.sql

docker compose stop garage
docker run --rm --volumes-from "$(docker compose ps -aq garage)" -v "$PWD/backups:/backups" alpine \
  sh -c "rm -rf /var/lib/garage/* && tar -xzf /backups/storage-$TS.tar.gz -C /var/lib/garage"
docker compose start garage
```

:::warning Restoring overwrites
A restore replaces the current database and object storage. Take a backup of the present state first if there is
anything in it you want.
:::

Keep the database dump and the storage archive from the same moment together. If you changed the database
user, replace `opencaptions` in the commands.

## Upgrading

```bash
docker compose pull
docker compose up -d
```

The API brings the database schema up to date by itself when it starts, so there is no migration step to
run, and you should never run one by hand.

Before an upgrade, **make a backup**, and read the release notes on
[GitHub](https://github.com/leogaudin/opencaptions/releases) for anything that changes how the stack is
configured. Until v0.1.0, the interface, the API and the data formats may change between builds.

To stay on a version, pin it once released:

```bash
OPENCAPTIONS_VERSION=0.1.0 docker compose up -d
```

Export the variable in your shell to keep it in force. The compose file uses `edge` (the latest main
branch) until the first release.

If an upgrade goes wrong, go back to the previous version the same way, and restore the backup if the
database was changed.
