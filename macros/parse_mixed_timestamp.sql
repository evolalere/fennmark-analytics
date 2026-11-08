
{% macro parse_mixed_timestamp(column_name) -%}
    coalesce(
        safe.parse_timestamp('%Y-%m-%d %H:%M:%S',     {{ column_name }}),  -- '2020-11-14 09:12:33'        (UTC, ~90%)
        safe.parse_timestamp('%Y-%m-%dT%H:%M:%E*S%Ez', {{ column_name }})   -- '2020-11-14T10:12:33+01:00'  (offset, ~10%)
    )
{%- endmacro %}