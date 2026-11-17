{# Small helpers so the same models run on DuckDB (local, CI) and BigQuery. #}

{% macro safe_div(num, den) -%}
  case when ({{ den }}) = 0 then null else cast({{ num }} as {{ dbt.type_float() }}) / ({{ den }}) end
{%- endmacro %}

{% macro float_type() -%}{{ dbt.type_float() }}{%- endmacro %}

{# Integers 0..n as a one-column relation named k. #}
{% macro int_series(n) -%}
  {%- if target.type == 'bigquery' -%}
    (select k from unnest(generate_array(0, {{ n }})) as k)
  {%- else -%}
    (select range as k from range(0, {{ n }} + 1))
  {%- endif -%}
{%- endmacro %}

{# Joins every row to h = start, start+2, ..., stop (a column named h). #}
{% macro cross_join_step2(start, stop) -%}
  {%- if target.type == 'bigquery' -%}
    cross join unnest(generate_array({{ start }}, {{ stop }}, 2)) as h
  {%- else -%}
    cross join lateral (select unnest(range({{ start }}, {{ stop }} + 1, 2)) as h) as h_series
  {%- endif -%}
{%- endmacro %}
