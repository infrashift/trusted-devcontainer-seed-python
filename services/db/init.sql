-- Seeded into the companion database on its first start, from
-- services/db/Containerfile. Runs once, against POSTGRES_DB, as POSTGRES_USER.
--
-- A small schema the workspace can query straight away, so `select count(*)
-- from workspace.notes' answers on a fresh volume and the developer's first
-- psql session is not against nothing.
CREATE SCHEMA IF NOT EXISTS workspace;

CREATE TABLE IF NOT EXISTS workspace.notes (
    id         bigserial PRIMARY KEY,
    created_at timestamptz NOT NULL DEFAULT now(),
    body       text        NOT NULL
);

INSERT INTO workspace.notes (body) VALUES
    ('This database was built by the forge from services/db in this repository.'),
    ('It persists on a host volume beside the workspace; `make stop` keeps it.'),
    ('Reach it from the workspace at $DB_HOST:$DB_PORT as demouser / demopass.');
