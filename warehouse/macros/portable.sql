{# Small helpers so the same models run on DuckDB (local, CI) and BigQuery. #}

{# Double precision on both engines. dbt.type_float() is a 4-byte REAL on
   DuckDB but FLOAT64 on BigQuery, which would make CI compute ratios and
   p-values at lower precision than production. #}
{% macro float_type() -%}
  {%- if target.type == 'bigquery' -%}float64{%- else -%}double{%- endif -%}
{%- endmacro %}

{% macro safe_div(num, den) -%}
  case when ({{ den }}) = 0 then null else cast({{ num }} as {{ float_type() }}) / ({{ den }}) end
{%- endmacro %}

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
