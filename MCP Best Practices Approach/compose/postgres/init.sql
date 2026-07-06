-- Runs once on first Postgres init (mounted into /docker-entrypoint-initdb.d).
-- One database per backing service so a chaos-induced slow query in one service
-- does not muddy another's metrics (architecture.md §10 "Shared Postgres cross-talk").
--
-- Services that back onto Postgres: order, customer, invoice, store, inventory
-- (inventory falls back to Postgres on a Redis cache miss). payment and
-- notification have no database.
--
-- Each service owns its schema/tables and seed data via CREATE TABLE IF NOT
-- EXISTS on startup, so the table DDL lives with the service that uses it.

CREATE DATABASE orderdb;
CREATE DATABASE customerdb;
CREATE DATABASE invoicedb;
CREATE DATABASE storedb;
CREATE DATABASE inventorydb;
