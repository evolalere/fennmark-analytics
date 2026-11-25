{% macro lookback_start_date(date_column, lookback_days) %}

    {#- First date an incremental run reprocesses: the newest date already in this model's
        table, minus the lookback. Returned as a 'YYYY-MM-DD' string that is resolved before
        the model's SQL is sent, so BigQuery receives a literal and can prune shards and
        partitions. Falls back to the start of the window when the table is empty. -#}

    {%- if not execute -%}
        {{ return(var('ga4_start_date')) }}
    {%- endif -%}

    {%- set query -%}
        select cast(date_sub(max({{ date_column }}), interval {{ lookback_days }} day) as string)
        from {{ this }}
    {%- endset -%}

    {%- set result = run_query(query).columns[0].values()[0] -%}

    {{ return(result if result is not none else var('ga4_start_date')) }}

{% endmacro %}
