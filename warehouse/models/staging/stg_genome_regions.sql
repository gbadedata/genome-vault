-- GIAB difficult-region intervals. BED coordinates: 0-based start, exclusive end.
select
    stratification,
    chrom,
    start_0based,
    end_exclusive,
    end_exclusive - start_0based as length_bp
from {{ source('raw', 'genome_regions') }}
