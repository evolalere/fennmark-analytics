with source as (

    select * from {{ source('backend', 'experiment_assignments') }}

),

renamed as (

    select
        -- surrogate key: raw has no natural key; one row per user x experiment
        {{ dbt_utils.generate_surrogate_key(['experiment_id', 'user_pseudo_id']) }}
                                                      as experiment_assignment_id,

        -- grain
        experiment_id,
        user_pseudo_id,                               -- ga4 cookie; joins to customers.user_pseudo_id for users who bought

        -- attributes
        variant,

        -- flags
        variant = 'treatment'                         as is_treatment,

        -- timestamps
        assigned_at,                                  -- = first view_promotion event
        loaded_at

    from source

)

select * from renamed