# ADR-006: Looker Studio over Metabase or Superset for BI

**Status:** Accepted

## Context

genome-vault includes a BI layer for non-engineer users to explore variant data — population frequencies, regional variant density, sample-level summaries. The BI tool needs to connect to BigQuery, allow filtering by dimension columns, support scheduled refreshes, and let dashboards be shared with anyone who has a link.

## Decision

Use **Looker Studio** (formerly Google Data Studio) for all dashboards.

## Alternatives considered

**Metabase**

- Open-source, self-hostable, friendly UI
- Requires a running container, a Postgres backing database, and someone to maintain both
- Excellent if/when the team's BI usage justifies the operational overhead
- For a single dashboard backed by BigQuery, the overhead is not justified

**Apache Superset**

- Open-source, more powerful than Metabase, very flexible
- Operationally the heaviest of the three (Celery workers, Redis, Postgres metadata)
- Best when you have many concurrent BI users and complex dashboard layouts

**Tableau / Power BI**

- Commercial, polished, common in enterprise environments
- Per-user licensing makes them expensive for portfolio-scale work
- Reasonable for a corporate deployment with existing licenses

**Custom React + Recharts dashboard**

- Maximum flexibility, no third-party dependency
- A substantial development effort for what's effectively a solved problem
- Not the right place to spend project time

## Consequences

**Positive**

- Zero operational cost — no servers to run, no backups to manage, no software to update
- Native BigQuery connector with query caching and partition awareness
- Dashboards are shareable by URL with anyone (including non-Google-account users with public mode)
- Free for any reasonable amount of usage on this project's scale

**Negative**

- Customisation ceiling is real — beyond a certain point, you can't achieve the exact visual layout you want without custom code
- Looker Studio is a Google product, so portability away from GCP requires rebuilding dashboards elsewhere
- The visual editor is sometimes finicky for complex calculations (workaround: do calculation in a BigQuery view, present the result in Looker)
- Free tier shares Google's compute pool, so dashboard load times can vary

## Future revisit triggers

This decision is worth re-examining if any of these become true:

- The BI use case grows to need fine-grained access controls, embedded dashboards in another application, or pixel-perfect designs (Metabase or Superset become more attractive)
- The platform standardises on a different BI tool across multiple data products
- Looker Studio's free tier limitations bite (rate limits, query timeouts, etc.) on a real workload
