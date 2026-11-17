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

{# Joins every row to alias = start, start+step, ..., stop (inclusive). #}
{% macro cross_join_series(start, stop, step, alias) -%}
  {%- if target.type == 'bigquery' -%}
    cross join unnest(generate_array({{ start }}, {{ stop }}, {{ step }})) as {{ alias }}
  {%- else -%}
    cross join lateral (select unnest(range({{ start }}, {{ stop }} + 1, {{ step }})) as {{ alias }}) as {{ alias }}_series
  {%- endif -%}
{%- endmacro %}

{# 0-based index of the fixed-width genomic window that holds pos. #}
{% macro window_of(pos, width) -%}
  cast(floor(({{ pos }}) / {{ width }}) as {{ dbt.type_bigint() }})
{%- endmacro %}
