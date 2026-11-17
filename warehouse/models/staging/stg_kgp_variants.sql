select
    variant_key, variant_id, chrom, pos, end_pos, ref, alt, variant_class, sv_type, sv_len,
    is_transition, ref_check, source_id, filter_status,
    src_ac, src_an, src_af,
    src_ac_afr, src_an_afr, src_ac_amr, src_an_amr, src_ac_eas, src_an_eas,
    src_ac_eur, src_an_eur, src_ac_sas, src_an_sas,
    src_ac_afr_unrel, src_an_afr_unrel, src_ac_amr_unrel, src_an_amr_unrel,
    src_ac_eas_unrel, src_an_eas_unrel, src_ac_eur_unrel, src_an_eur_unrel,
    src_ac_sas_unrel, src_an_sas_unrel,
    src_hwe_afr, src_hwe_amr, src_hwe_eas, src_hwe_eur, src_hwe_sas
from {{ source('raw', 'kgp_variants') }}
