
{% macro ga4_event_param(key, type='string') -%}
    {#- Lifts one event_params key to a scalar with a correlated subquery, so the calling
        select keeps one row per event (a cross-join UNNEST would multiply rows).
        any_value() guards against a key appearing twice on one event, which would raise
        "Scalar subquery produced more than one element". Only valid inside a select over
        the ga4.events source, because it reads the current row's event_params. -#}
    {%- set value_column = {
        'string': 'string_value',
        'int':    'int_value',
        'float':  'float_value',
        'double': 'double_value'
    }[type] -%}
    (select any_value(value.{{ value_column }}) from unnest(event_params) where key = '{{ key }}')
{%- endmacro %}