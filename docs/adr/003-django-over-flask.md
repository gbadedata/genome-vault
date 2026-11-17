# ADR-003: Django + DRF over Flask for the API

**Status:** Superseded by [ADR-015](015-read-only-api-on-cloud-run.md) (November 2026)

> Django was dropped in the November 2026 rebuild. The API is a small read-only FastAPI service on Cloud Run; see ADR-015.

## Context

genome-vault exposes a REST API that lets users query variants, samples, and pre-computed rollups. The API needs to handle authenticated requests, paginate large result sets, validate inputs, generate OpenAPI documentation, and return predictable JSON shapes.

Three obvious candidates in the Python ecosystem: **Flask** (microframework, hand-assembled stack), **FastAPI** (async-first, Pydantic-native), and **Django + Django REST Framework** (batteries-included, ORM-driven).

## Decision

Use **Django 5 with Django REST Framework** for the API layer, deployed on **Cloud Run**.

## Alternatives considered

**Flask**

- Lightweight, well-understood, the right call for many small APIs
- Hand-assembled stack — separate libraries for auth, ORM (if needed), serialisation, admin
- Less batteries-included means more setup per project
- Used in the sister project (ClinTrial-Stream) — deliberately choosing differently here to demonstrate breadth across the portfolio

**FastAPI**

- Async-first, automatic OpenAPI generation, Pydantic-native validation
- Excellent for high-concurrency I/O-bound APIs
- Lacks the admin interface, the migrations framework, and the ORM that Django includes by default — these are useful even for an analytical-platform-style API
- Smaller installed base in regulated biotech estates than Django

**Django without DRF**

- Possible but means hand-rolling JSON serialisation and view-set conventions
- DRF is a thin enough layer that the conventions help without locking us in

## Consequences

**Positive**

- Batteries-included means less integration glue: admin interface for ops, migrations framework for schema evolution, ORM for the API's own metadata tables, sessions for any future browser-facing surface
- DRF's ViewSet + Router pattern reduces boilerplate for resource-oriented APIs
- Strong ecosystem of plug-ins — django-environ for config, drf-spectacular for OpenAPI, django-filter for query parameters

**Negative**

- Synchronous by default — under heavy concurrent load, throughput depends on gunicorn worker count rather than native async. For the analytical-query workload this platform targets (slow BigQuery queries, not high-RPS short transactions), this is fine
- More moving parts to learn for engineers who've only seen microframeworks
- The admin interface, while genuinely useful, comes with a security surface area that has to be locked down properly (CSRF, allowed hosts, deployed behind auth)

## Why both Django here and Flask in the sister project

The two projects deliberately use different Python web frameworks. ClinTrial-Stream uses Flask (microframework, hand-assembled, async-suitable workload); genome-vault uses Django + DRF (batteries-included, ORM-driven, complex resource model). This gives the portfolio breadth — being able to defend both stack choices on their merits is more valuable than picking one and using it everywhere.

## Future revisit triggers

This decision is worth re-examining if any of these become true:

- The API needs WebSocket or server-sent-events support (Django Channels or FastAPI become more attractive)
- Per-request latency under high concurrent load becomes a bottleneck (async wins)
- The team standardises on FastAPI across multiple services and the operational cost of two frameworks outweighs the benefits of each
