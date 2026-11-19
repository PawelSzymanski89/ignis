-- Owner (migrations) + runtime role (serving nodes) for Ignis — SECURITY.md, "Runtime database role".
-- Run as a superuser, once; replace the names and passwords. Serving nodes then run with
-- IGNIS_DB_USER=ignis_rt IGNIS_SCHEMA=validate IGNIS_REQUIRE_RUNTIME_ROLE=1; the migrating node with
-- IGNIS_DB_USER=ignis_owner IGNIS_SCHEMA=update (without IGNIS_REQUIRE_RUNTIME_ROLE).
CREATE ROLE ignis_owner LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD 'change-me-owner';
CREATE ROLE ignis_rt    LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD 'change-me-runtime';
CREATE DATABASE ignis OWNER ignis_owner;
\c ignis
-- PostgreSQL <= 14: public is owned by the bootstrap superuser and every role may create objects there;
-- the REVOKE below is then required, and the owner needs CREATE on the schema:
--   GRANT CREATE ON SCHEMA public TO ignis_owner;   (or ALTER SCHEMA public OWNER TO ignis_owner;)
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO ignis_rt;
-- tables created by the owner from now on (every migration):
ALTER DEFAULT PRIVILEGES FOR ROLE ignis_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ignis_rt;
ALTER DEFAULT PRIVILEGES FOR ROLE ignis_owner IN SCHEMA public
  GRANT USAGE ON SEQUENCES TO ignis_rt;
-- tables that already exist (an install that ran as one role so far; also fine to repeat):
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ignis_rt;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO ignis_rt;
