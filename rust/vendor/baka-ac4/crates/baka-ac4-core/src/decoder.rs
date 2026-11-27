//! Dolby AC-4 audio decoder (ETSI TS 103 190).

use crate::bitreader::BitReader;
use crate::error::{Result, invalid, unsupported};
use crate::imdct::Imdct;
use crate::kbd::kbd_window_init;
use crate::qmf::{QmfAnalysis, QmfSynthesis};
use crate::tables::*;
use crate::vlc::Vlc;

const MAX_QMF_TSLOTS: usize = 32;
/// Analysis+synthesis cascade group delay (9 slots + 1) used to shortcut
/// the QMF round trip when no QMF-domain consumer is active.
const QMF_BYPASS_DELAY: usize = 9 * MAX_QMF_BANDS + 1;
const MAX_QMF_BANDS: usize = 64;
const MAX_SBG_NOISE: usize = 5;
const MAX_ATSG_NOISE: usize = 2;
const MAX_ASPX_SIGNAL: usize = 5;

/* Number of model bits */
const SSF_MODEL_BITS: u32 = 15;
/* Model unit for the CDF specification */
const SSF_MODEL_UNIT: u32 = 1 << SSF_MODEL_BITS;
/* Number of range bits */
const SSF_RANGE_BITS: u32 = 30;
/* Half of the range unit */
const SSF_THRESHOLD_LARGE: u32 = 1 << (SSF_RANGE_BITS - 1);
/* Quarter of the range unit */
const SSF_THRESHOLD_SMALL: u32 = 1 << (SSF_RANGE_BITS - 2);
/* Offset bits */
#[allow(dead_code)] // completes the SSF constant set
const SSF_OFFSET_BITS: u32 = 14;

pub mod enums {
    pub const LONG_STRIDE: i32 = 0;
    pub const SHORT_STRIDE: i32 = 1;

    pub const IM_SCPL: i32 = 0;
    pub const IM_ASPX_SCPL: i32 = 1;
    pub const IM_ASPX_ACPL_1: i32 = 2;
    pub const IM_ASPX_ACPL_2: i32 = 3;
    pub const IM_ASPX_AJCC: i32 = 4;

    pub const ACPL_FULL: i32 = 0;
    pub const ACPL_PARTIAL: i32 = 1;

    pub const ST_SUBSTREAM: i32 = 0;
    pub const ST_PRESENTATION: i32 = 1;

    pub const SM_LEVEL: i32 = 0;
    pub const SM_BALANCE: i32 = 1;

    pub const DT_SIGNAL: i32 = 0;
    pub const DT_NOISE: i32 = 1;

    pub const SF_ASF: i32 = 0;
    pub const SF_SSF: i32 = 1;

    pub const HCB_F0: usize = 0;
    pub const HCB_DF: usize = 1;
    pub const HCB_DT: usize = 2;

    pub const CM_SIMPLE: i32 = 0;
    pub const CM_ASPX: i32 = 1;
    pub const CM_ASPX_ACPL_1: i32 = 2;
    pub const CM_ASPX_ACPL_2: i32 = 3;
    pub const CM_ASPX_ACPL_3: i32 = 4;

    pub const FIXFIX: i32 = 0;
    pub const FIXVAR: i32 = 1;
    pub const VARFIX: i32 = 2;
    pub const VARVAR: i32 = 3;

    pub const ALPHA1: i32 = 0;
    pub const ALPHA2: i32 = 1;
    pub const BETA1: i32 = 2;
    pub const BETA2: i32 = 3;
    pub const BETA3: i32 = 4;
    pub const GAMMA1: i32 = 5;
    pub const GAMMA2: i32 = 6;
    pub const GAMMA3: i32 = 7;
    pub const GAMMA4: i32 = 8;
    pub const GAMMA5: i32 = 9;
    pub const GAMMA6: i32 = 10;
}

// Canonical channel-order indices used by the ch_map tables
// (values 0..17; no "none" sentinel is needed here).
pub mod chan {
    pub const FRONT_LEFT: usize = 0;
    pub const FRONT_RIGHT: usize = 1;
    pub const FRONT_CENTER: usize = 2;
    pub const LOW_FREQUENCY: usize = 3;
    pub const BACK_LEFT: usize = 4;
    pub const BACK_RIGHT: usize = 5;
    pub const FRONT_LEFT_OF_CENTER: usize = 6;
    pub const FRONT_RIGHT_OF_CENTER: usize = 7;
    pub const BACK_CENTER: usize = 8;
    pub const SIDE_LEFT: usize = 9;
    pub const SIDE_RIGHT: usize = 10;
    pub const TOP_CENTER: usize = 11;
    pub const TOP_FRONT_LEFT: usize = 12;
    pub const TOP_FRONT_CENTER: usize = 13;
    pub const TOP_FRONT_RIGHT: usize = 14;
    pub const TOP_BACK_LEFT: usize = 15;
    pub const TOP_BACK_CENTER: usize = 16;
    pub const TOP_BACK_RIGHT: usize = 17;
}

#[derive(Default, Clone, Copy)]
pub struct ACState {
    ui_low: u32,
    ui_range: u32,
    ui_offset: u32,
    ui_offset2: u32,
    ui_threshold_small: u32,
    ui_threshold_large: u32,
    ui_model_unit: u32,
    ui_range_bits: u32,
    ui_model_bits: u32,
}

#[derive(Default, Clone, Copy)]
pub struct EMDFInfo {
    version: i32,
    key_id: i32,
    substream_index: i32,
}

#[derive(Default, Clone)]
pub struct SubstreamChannelParameters {
    long_frame: u8,
    transf_length_idx: [u8; 2],
    #[allow(dead_code)] // C stores this; lengths resolve via transf_length_idx
    transf_length: [i32; 2],

    different_framing: u8,
    max_sfb_side: [u8; 2],
    max_sfb: [u8; 2],
    scale_factor_grouping: [u8; 18],

    num_windows: u8,
    num_window_groups: u8,
    window_to_group: [u8; 16],
    num_win_in_group: [u8; 16],

    dual_maxsfb: u8,
    side_limited: u8,
    side_channel: u8,
}

// The decoder state starts fully zeroed: zero is a valid value for every
// field of the two structs below (they hold arrays longer than 32 elements,
// which std's Default derive does not cover).
macro_rules! pod_zeroed_default {
    ($name:ident) => {
        impl Default for $name {
            #[inline]
            fn default() -> Self {
                // SAFETY: every field is plain integer/float data and an
                // all-zero bit pattern is a valid value for each.
                unsafe { std::mem::zeroed() }
            }
        }
    };
}

#[derive(Clone)]
pub struct SubstreamChannel {
    scp: SubstreamChannelParameters,

    master_reset: i32,
    num_sbg_master: i32,
    num_sb_aspx: i32,
    num_sbg_noise: i32,
    num_sbg_sig_highres: i32,
    num_sbg_sig_lowres: i32,
    sba: i32,
    sbx: i32,
    sbz: i32,

    sap_mode: i32,
    n_prev: i32,
    idx_prev: i32,

    ms_used: [[u8; 128]; 16],
    sap_coeff_used: [[u8; 128]; 16],
    dpcm_alpha_q: [[u8; 128]; 16],

    delta_code_time: i32,

    num_sec_lsf: [i32; 16],
    num_sec: [i32; 16],
    sfb_cb: [[u8; 128]; 16],
    sect_cb: [[u8; 128]; 16],
    sect_start: [[i32; 128]; 16],
    sect_end: [[i32; 128]; 16],
    sect_sfb_offset: [[i32; 128]; 16],

    quant_spec: [i16; 8192],
    offset2sfb: [i16; 8192],
    offset2g: [u8; 8192],
    win_offset: [i32; 16],

    max_quant_idx: [[i32; 128]; 16],
    dpcm_sf: [[i32; 128]; 16],
    dpcm_snf: [[i32; 128]; 16],
    snf_data_exists: i32,

    sf_gain: [[f32; 128]; 16],

    aspx_int_class: i32,
    aspx_num_noise: i32,
    aspx_num_rel_left: i32,
    aspx_num_rel_right: i32,
    aspx_num_env: i32,
    num_atsg_sig: i32,
    num_atsg_sig_prev: i32,
    num_atsg_noise: i32,
    num_atsg_noise_prev: i32,
    aspx_freq_res: [u8; MAX_ASPX_SIGNAL + 1],
    aspx_var_bord_left: i32,
    aspx_var_bord_right: i32,
    aspx_rel_bord_left: [i32; 4],
    aspx_rel_bord_right: [i32; 4],
    aspx_tsg_ptr: i32,
    aspx_tsg_ptr_prev: i32,

    aspx_qmode_env: i32,
    aspx_sig_delta_dir: [u8; MAX_ASPX_SIGNAL],
    aspx_noise_delta_dir: [u8; 2],
    aspx_tna_mode: [u8; MAX_SBG_NOISE],
    aspx_tna_mode_prev: [u8; MAX_SBG_NOISE],
    aspx_add_harmonic: [u8; MAX_QMF_TSLOTS],
    aspx_fic_used_in_sfb: [u8; MAX_QMF_TSLOTS],
    aspx_tic_used_in_slot: [u8; MAX_QMF_TSLOTS],
    aspx_xover_subband_offset: i32,
    aspx_balance: i32,

    atsg_freqres: [u8; MAX_ASPX_SIGNAL],
    atsg_sig: [u8; MAX_ASPX_SIGNAL + 1],
    atsg_noise: [u8; MAX_ASPX_SIGNAL],
    previous_stop_pos: i32,

    sbg_noise: [i32; MAX_SBG_NOISE],
    sbg_sig_lowres: [i32; 24],
    sbg_sig_highres: [i32; 24],
    sbg_lim: [i32; 32],
    sbg_patches: [i32; MAX_SBG_NOISE],
    sbg_patch_num_sb: [i32; MAX_SBG_NOISE],
    sbg_patch_start_sb: [i32; MAX_SBG_NOISE],
    sbg_master: [i32; 24],

    num_sbg_sig: [i32; 6],
    sbg_sig: [[i32; 24]; 6],
    num_sbg_patches: i32,
    num_sbg_lim: i32,

    aspx_data: [[[i16; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL]; 2],

    qscf_prev: [[i8; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    qscf_noise_prev: [[i8; MAX_SBG_NOISE]; MAX_ATSG_NOISE],
    qscf_sig_sbg: [[i8; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    qscf_sig_sbg_prev: [[i8; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    scf_sig_sbg: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    scf_sig_sb: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    qscf_noise_sbg: [[i8; MAX_SBG_NOISE]; MAX_ATSG_NOISE],
    scf_noise_sbg: [[f32; MAX_SBG_NOISE]; MAX_ATSG_NOISE],
    scf_noise_sb: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],

    gain_vec: [f32; MAX_QMF_BANDS],
    chirp_arr: [f32; MAX_SBG_NOISE],
    chirp_arr_prev: [f32; MAX_SBG_NOISE],
    est_sig_sb: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    sine_idx_sb: [[u8; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    sine_idx_sb_prev: [[u8; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    sine_area_sb: [[u8; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    sine_lev_sb: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    noise_lev_sb: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    sig_gain_sb: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    max_sig_gain_sbg: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    max_sig_gain_sb: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    noise_lev_sb_lim: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    sig_gain_sb_lim: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    boost_fact_sbg: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    boost_fact_sb: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    sig_gain_sb_adj: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    noise_lev_sb_adj: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],
    sine_lev_sb_adj: [[f32; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL],

    sine_idx_prev: [[i8; MAX_QMF_BANDS]; MAX_QMF_TSLOTS],
    noise_idx_prev: [[i16; MAX_QMF_BANDS]; MAX_QMF_TSLOTS],

    acpl_interpolation_type: i32,
    acpl_num_param_sets_cod: i32,
    acpl_param_timeslot: [i32; 2],
    acpl_data: [[i32; 16]; 11],

    start_block: i32,
    end_block: i32,
    stride_flag: i32,
    num_bands: i32,
    predictor_presence: [i32; 4],
    predictor_lag_delta: [i32; 4],
    predictor_lag: [i32; 4],
    variance_preserving: [i32; 4],
    alloc_offset: [i32; 4],
    delta: [i32; 4],
    gain_bits: [i32; 4],
    env_idx: [i32; 19],
    acs: ACState,

    scaled_spec: [f32; 2048],
    spec_reord: [f32; 2048],

    pcm: [f32; 2048],
    imdct_out: [f32; 4096],
    overlap: [f32; 4096],

    qana_filt: [f32; MAX_QMF_BANDS * 10],
    qmf_sine: [[[f32; MAX_QMF_BANDS]; MAX_QMF_TSLOTS]; 2],
    qmf_noise: [[[f32; MAX_QMF_BANDS]; MAX_QMF_TSLOTS]; 2],
    qsyn_filt: [f32; MAX_QMF_BANDS * 20],
    l_: [f32; MAX_QMF_TSLOTS],
    g: [f32; MAX_QMF_TSLOTS],
    e: [[f32; MAX_QMF_BANDS]; MAX_QMF_TSLOTS],
    q: [[[f32; MAX_QMF_BANDS]; MAX_QMF_TSLOTS]; 2],
    q_prev: [[[f32; MAX_QMF_BANDS]; MAX_QMF_TSLOTS]; 2],
    q_low: [[[f32; MAX_QMF_BANDS]; MAX_QMF_TSLOTS + 6]; 2],
    q_low_prev: [[[f32; MAX_QMF_BANDS]; MAX_QMF_TSLOTS + 6]; 2],
    q_low_ext: [[[f32; MAX_QMF_BANDS]; MAX_QMF_TSLOTS + 10]; 2],
    q_high: [[[f32; MAX_QMF_BANDS]; MAX_QMF_TSLOTS + 4]; 2],
    cov: [[[[f32; 2]; 3]; 3]; MAX_QMF_BANDS],
    alpha0: [[f32; 2]; MAX_QMF_BANDS],
    alpha1: [[f32; 2]; MAX_QMF_BANDS],
    y: [[[f32; MAX_QMF_BANDS]; MAX_QMF_TSLOTS]; 2],
    y_prev: [[[f32; MAX_QMF_BANDS]; MAX_QMF_TSLOTS]; 2],
}

pod_zeroed_default!(SubstreamChannel);

#[derive(Clone)]
pub struct Substream {
    codec_mode: i32,
    im_codec_mode: i32,
    core_5ch_grouping: i32,
    use_sap_add_ch: i32,

    aspx_quant_mode_env: i32,
    aspx_start_freq: i32,
    prev_aspx_start_freq: i32,
    aspx_stop_freq: i32,
    prev_aspx_stop_freq: i32,
    aspx_master_freq_scale: i32,
    prev_aspx_master_freq_scale: i32,
    aspx_interpolation: i32,
    aspx_preflat: i32,
    aspx_limiter: i32,
    aspx_noise_sbg: i32,
    aspx_num_env_bits_fixfix: i32,
    aspx_freq_res_mode: i32,

    acpl_qmf_band: i32,
    acpl_param_band: i32,
    acpl_num_param_bands_id: i32,
    acpl_quant_mode: [u8; 2],

    sync_flag: u8,
    mode_2ch: u8,
    chel_matsel: u8,

    compand_on: [u8; 12],
    compand_avg: u8,

    max_sfb_master: i32,

    coding_config: u8,
    mdct_stereo_proc: [u8; 8],
    matrix_stereo: [[[[f32; 2]; 2]; 128]; 16],
    alpha_q: [[i8; 128]; 16],

    spec_frontend_l: i32,
    spec_frontend_r: i32,
    spec_frontend_m: i32,
    spec_frontend_s: i32,

    g_sum: [f32; MAX_QMF_TSLOTS],

    // Heap-allocated: 12 SubstreamChannels are ~3.4 MB, far beyond the
    // default 1 MB Windows main-thread stack if built as an inline array.
    ssch: Vec<SubstreamChannel>,
}

impl Default for Substream {
    fn default() -> Self {
        // Every field but `ssch` is plain numeric data; write the zeros out
        // instead of mem::zeroed (which is rejected for types holding a Vec).
        Substream {
            codec_mode: 0,
            im_codec_mode: 0,
            core_5ch_grouping: 0,
            use_sap_add_ch: 0,
            aspx_quant_mode_env: 0,
            aspx_start_freq: 0,
            prev_aspx_start_freq: 0,
            aspx_stop_freq: 0,
            prev_aspx_stop_freq: 0,
            aspx_master_freq_scale: 0,
            prev_aspx_master_freq_scale: 0,
            aspx_interpolation: 0,
            aspx_preflat: 0,
            aspx_limiter: 0,
            aspx_noise_sbg: 0,
            aspx_num_env_bits_fixfix: 0,
            aspx_freq_res_mode: 0,
            acpl_qmf_band: 0,
            acpl_param_band: 0,
            acpl_num_param_bands_id: 0,
            acpl_quant_mode: [0; 2],
            sync_flag: 0,
            mode_2ch: 0,
            chel_matsel: 0,
            compand_on: [0; 12],
            compand_avg: 0,
            max_sfb_master: 0,
            coding_config: 0,
            mdct_stereo_proc: [0; 8],
            matrix_stereo: [[[[0.0; 2]; 2]; 128]; 16],
            alpha_q: [[0; 128]; 16],
            spec_frontend_l: 0,
            spec_frontend_r: 0,
            spec_frontend_m: 0,
            spec_frontend_s: 0,
            g_sum: [0.0; MAX_QMF_TSLOTS],
            ssch: (0..12).map(|_| SubstreamChannel::default()).collect(),
        }
    }
}

#[derive(Default, Clone, Copy)]
pub struct PresentationSubstreamInfo {
    alternative: i32,
    pres_ndot: i32,
    substream_index: i32,
}

#[derive(Default, Clone, Copy)]
#[allow(dead_code)] // metadata blocks are parsed but not exported yet
pub struct Metadata {
    dialnorm_bits: i32,
    pre_dmixtyp_2ch: i32,
    phase90_info_2ch: i32,
    loro_center_mixgain: i32,
    loro_surround_mixgain: i32,
    loro_dmx_loud_corr: i32,
    ltrt_center_mixgain: i32,
    ltrt_surround_mixgain: i32,
    ltrt_dmx_loud_corr: i32,
    lfe_mixgain: i32,
    preferred_dmx_method: i32,
    pre_dmixtyp_5ch: i32,
    pre_upmixtyp_5ch: i32,
    pre_upmixtyp_3_4: i32,
    pre_upmixtyp_3_2_2: i32,
    phase90_info_mc: i32,
    surround_attenuation_known: i32,
    lfe_attenuation_known: i32,
    dc_block_on: i32,

    loudness_version: i32,
    loud_prac_type: i32,
    dialgate_prac_type: i32,
    loudcorr_type: i32,
    loudrelgat: i32,
    loudspchgat: i32,
    loudstrm3s: i32,
    max_loudstrm3s: i32,
    truepk: i32,
    max_truepk: i32,
    prgmbndy: i32,
    end_or_start: i32,
    prgmbndy_offset: i32,
    lra: i32,
    lra_prac_type: i32,
    loudmntry: i32,
    max_loudmntry: i32,

    drc_decoder_nr_modes: i32,
    drc_eac3_profile: i32,
}

#[derive(Default, Clone)]
pub struct SubstreamInfo {
    sus_ver: i32,
    channel_mode: i32,
    substream_index: i32,
    hsf_ext_substream_index: i32,
    sf_multiplier: i32,
    bitrate_indicator: i32,
    add_ch_base: i32,
    iframe: [i32; 4],
    back_channels_present: i32,
    centre_present: i32,
    top_channels_present: i32,

    lfe: i32,
    static_dmx: i32,
    audio_ndot: [i32; 4],
    n_fullband_dmx_signals: i32,
    core_bed_mask: u64,
    dynamic_dmx: bool,
    dynamic_upmix: bool,
    oamd_common: Option<crate::ajoc::common::CommonData>,
    n_fullband_upmix_signals: i32,

    n_objects: i32,

    #[allow(dead_code)] // consumed by the (commented-out) C metadata parser
    meta: Metadata,
}

#[derive(Default, Clone)]
pub struct SubstreamGroupInfo {
    channel_coded: i32,
    ajoc: i32,
    group_index: i32,
    oamd_index: Option<i32>,
    ssinfo: SubstreamInfo,
}

#[derive(Default, Clone)]
pub struct PresentationInfo {
    single_substream: i32,
    enable_presentation: i32,
    presentation_config: i32,
    presentation_version: i32,
    add_emdf_substreams: i32,
    n_add_emdf_substreams: i32,
    n_substream_groups: i32,
    mdcompat: i32,
    presentation_id: i32,
    multiplier: i32,
    multiplier_bit: i32,
    pre_virtualized: i32,
    frame_rate_factor: i32,
    frame_rate_fraction: i32,
    multi_pid: i32,
    hsf_ext: i32,
    emdf: [EMDFInfo; 32],
    psinfo: PresentationSubstreamInfo,
    ssinfo: [SubstreamInfo; 4],
}

/// Immutable after construction.
pub struct Tables {
    vlcs: &'static Vlcs,
    kbd_window: &'static [[Box<[f32; 2048]>; 5]; 8],
    tx: [[Imdct; 5]; 8],
    quant_lut: &'static [f32; 8192],
    qmf_ana: QmfAnalysis,
    qmf_syn: QmfSynthesis,
}

// Immutable codebooks/windows are shared across playback requests. Mutable FFT
// workspaces and all inter-frame state remain owned by each decoder.
struct SharedTables {
    vlcs: Vlcs,
    kbd_window: [[Box<[f32; 2048]>; 5]; 8],
    quant_lut: Box<[f32; 8192]>,
}

fn shared_tables() -> &'static SharedTables {
    static TABLES: std::sync::OnceLock<SharedTables> = std::sync::OnceLock::new();
    TABLES.get_or_init(|| {
        let kbd_window = std::array::from_fn(|j| {
            std::array::from_fn(|i| {
                let mut window = Box::new([0.0f32; 2048]);
                kbd_window_init(
                    &mut window[..],
                    KBD_WINDOW_ALPHA[j][i],
                    TRANSF_LENGTH_48KHZ[j][i] as usize,
                );
                window
            })
        });
        let mut quant_lut = Box::new([0.0f32; 8192]);
        for (i, q) in quant_lut.iter_mut().enumerate() {
            *q = (i as f32).powf(4.0f32 / 3.0);
        }
        SharedTables {
            vlcs: init_vlcs(),
            kbd_window,
            quant_lut,
        }
    })
}

pub struct Vlcs {
    channel_mode: Vlc,
    bitrate_indicator: Vlc,
    scale_factors: Vlc,
    snf: Vlc,
    asf_codebook: [Vlc; 11],
    aspx_int_class: Vlc,
    /// [level/balance][15/30][f0/df/dt]
    aspx_codebook_signal: [[[Vlc; 3]; 2]; 2],
    /// [level/balance][f0/df/dt]
    aspx_codebook_noise: [[Vlc; 3]; 2],
    /// [alpha/beta/beta3/gamma][fine/coarse][f0/df/dt]
    acpl_codebook: [[[Vlc; 3]; 2]; 4],
}

fn init_vlcs() -> Vlcs {
    Vlcs {
        channel_mode: Vlc::new(&CHANNEL_MODE_BITS, &CHANNEL_MODE_CODES).unwrap(),
        bitrate_indicator: Vlc::new(&BITRATE_INDICATOR_BITS, &BITRATE_INDICATOR_CODES).unwrap(),
        scale_factors: Vlc::new(&SCALE_FACTORS_BITS, &SCALE_FACTORS_CODES).unwrap(),
        snf: Vlc::new(&SNF_BITS, &SNF_CODES).unwrap(),
        asf_codebook: [
            Vlc::new(&ASF_CODEBOOK_1_BITS, &ASF_CODEBOOK_1_CODES).unwrap(),
            Vlc::new(&ASF_CODEBOOK_2_BITS, &ASF_CODEBOOK_2_CODES).unwrap(),
            Vlc::new(&ASF_CODEBOOK_3_BITS, &ASF_CODEBOOK_3_CODES).unwrap(),
            Vlc::new(&ASF_CODEBOOK_4_BITS, &ASF_CODEBOOK_4_CODES).unwrap(),
            Vlc::new(&ASF_CODEBOOK_5_BITS, &ASF_CODEBOOK_5_CODES).unwrap(),
            Vlc::new(&ASF_CODEBOOK_6_BITS, &ASF_CODEBOOK_6_CODES).unwrap(),
            Vlc::new(&ASF_CODEBOOK_7_BITS, &ASF_CODEBOOK_7_CODES).unwrap(),
            Vlc::new(&ASF_CODEBOOK_8_BITS, &ASF_CODEBOOK_8_CODES).unwrap(),
            Vlc::new(&ASF_CODEBOOK_9_BITS, &ASF_CODEBOOK_9_CODES).unwrap(),
            Vlc::new(&ASF_CODEBOOK_10_BITS, &ASF_CODEBOOK_10_CODES).unwrap(),
            Vlc::new(&ASF_CODEBOOK_11_BITS, &ASF_CODEBOOK_11_CODES).unwrap(),
        ],
        aspx_int_class: Vlc::new(&ASPX_INT_CLASS_BITS, &ASPX_INT_CLASS_CODES).unwrap(),
        aspx_codebook_signal: [
            [
                [
                    Vlc::new(
                        &ASPX_HCB_ENV_LEVEL_15_F0_BITS,
                        &ASPX_HCB_ENV_LEVEL_15_F0_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ASPX_HCB_ENV_LEVEL_15_DF_BITS,
                        &ASPX_HCB_ENV_LEVEL_15_DF_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ASPX_HCB_ENV_LEVEL_15_DT_BITS,
                        &ASPX_HCB_ENV_LEVEL_15_DT_CODES,
                    )
                    .unwrap(),
                ],
                [
                    Vlc::new(
                        &ASPX_HCB_ENV_LEVEL_30_F0_BITS,
                        &ASPX_HCB_ENV_LEVEL_30_F0_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ASPX_HCB_ENV_LEVEL_30_DF_BITS,
                        &ASPX_HCB_ENV_LEVEL_30_DF_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ASPX_HCB_ENV_LEVEL_30_DT_BITS,
                        &ASPX_HCB_ENV_LEVEL_30_DT_CODES,
                    )
                    .unwrap(),
                ],
            ],
            [
                [
                    Vlc::new(
                        &ASPX_HCB_ENV_BALANCE_15_F0_BITS,
                        &ASPX_HCB_ENV_BALANCE_15_F0_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ASPX_HCB_ENV_BALANCE_15_DF_BITS,
                        &ASPX_HCB_ENV_BALANCE_15_DF_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ASPX_HCB_ENV_BALANCE_15_DT_BITS,
                        &ASPX_HCB_ENV_BALANCE_15_DT_CODES,
                    )
                    .unwrap(),
                ],
                [
                    Vlc::new(
                        &ASPX_HCB_ENV_BALANCE_30_F0_BITS,
                        &ASPX_HCB_ENV_BALANCE_30_F0_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ASPX_HCB_ENV_BALANCE_30_DF_BITS,
                        &ASPX_HCB_ENV_BALANCE_30_DF_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ASPX_HCB_ENV_BALANCE_30_DT_BITS,
                        &ASPX_HCB_ENV_BALANCE_30_DT_CODES,
                    )
                    .unwrap(),
                ],
            ],
        ],
        aspx_codebook_noise: [
            [
                Vlc::new(
                    &ASPX_HCB_NOISE_LEVEL_F0_BITS,
                    &ASPX_HCB_NOISE_LEVEL_F0_CODES,
                )
                .unwrap(),
                Vlc::new(
                    &ASPX_HCB_NOISE_LEVEL_DF_BITS,
                    &ASPX_HCB_NOISE_LEVEL_DF_CODES,
                )
                .unwrap(),
                Vlc::new(
                    &ASPX_HCB_NOISE_LEVEL_DT_BITS,
                    &ASPX_HCB_NOISE_LEVEL_DT_CODES,
                )
                .unwrap(),
            ],
            [
                Vlc::new(
                    &ASPX_HCB_NOISE_BALANCE_F0_BITS,
                    &ASPX_HCB_NOISE_BALANCE_F0_CODES,
                )
                .unwrap(),
                Vlc::new(
                    &ASPX_HCB_NOISE_BALANCE_DF_BITS,
                    &ASPX_HCB_NOISE_BALANCE_DF_CODES,
                )
                .unwrap(),
                Vlc::new(
                    &ASPX_HCB_NOISE_BALANCE_DT_BITS,
                    &ASPX_HCB_NOISE_BALANCE_DT_CODES,
                )
                .unwrap(),
            ],
        ],
        acpl_codebook: [
            [
                [
                    Vlc::new(&ACPL_HCB_ALPHA_FINE_F0_BITS, &ACPL_HCB_ALPHA_FINE_F0_CODES).unwrap(),
                    Vlc::new(&ACPL_HCB_ALPHA_FINE_DF_BITS, &ACPL_HCB_ALPHA_FINE_DF_CODES).unwrap(),
                    Vlc::new(&ACPL_HCB_ALPHA_FINE_DT_BITS, &ACPL_HCB_ALPHA_FINE_DT_CODES).unwrap(),
                ],
                [
                    Vlc::new(
                        &ACPL_HCB_ALPHA_COARSE_F0_BITS,
                        &ACPL_HCB_ALPHA_COARSE_F0_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ACPL_HCB_ALPHA_COARSE_DF_BITS,
                        &ACPL_HCB_ALPHA_COARSE_DF_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ACPL_HCB_ALPHA_COARSE_DT_BITS,
                        &ACPL_HCB_ALPHA_COARSE_DT_CODES,
                    )
                    .unwrap(),
                ],
            ],
            [
                [
                    Vlc::new(&ACPL_HCB_BETA_FINE_F0_BITS, &ACPL_HCB_BETA_FINE_F0_CODES).unwrap(),
                    Vlc::new(&ACPL_HCB_BETA_FINE_DF_BITS, &ACPL_HCB_BETA_FINE_DF_CODES).unwrap(),
                    Vlc::new(&ACPL_HCB_BETA_FINE_DT_BITS, &ACPL_HCB_BETA_FINE_DT_CODES).unwrap(),
                ],
                [
                    Vlc::new(
                        &ACPL_HCB_BETA_COARSE_F0_BITS,
                        &ACPL_HCB_BETA_COARSE_F0_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ACPL_HCB_BETA_COARSE_DF_BITS,
                        &ACPL_HCB_BETA_COARSE_DF_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ACPL_HCB_BETA_COARSE_DT_BITS,
                        &ACPL_HCB_BETA_COARSE_DT_CODES,
                    )
                    .unwrap(),
                ],
            ],
            [
                [
                    Vlc::new(&ACPL_HCB_BETA3_FINE_F0_BITS, &ACPL_HCB_BETA3_FINE_F0_CODES).unwrap(),
                    Vlc::new(&ACPL_HCB_BETA3_FINE_DF_BITS, &ACPL_HCB_BETA3_FINE_DF_CODES).unwrap(),
                    Vlc::new(&ACPL_HCB_BETA3_FINE_DT_BITS, &ACPL_HCB_BETA3_FINE_DT_CODES).unwrap(),
                ],
                [
                    Vlc::new(
                        &ACPL_HCB_BETA3_COARSE_F0_BITS,
                        &ACPL_HCB_BETA3_COARSE_F0_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ACPL_HCB_BETA3_COARSE_DF_BITS,
                        &ACPL_HCB_BETA3_COARSE_DF_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ACPL_HCB_BETA3_COARSE_DT_BITS,
                        &ACPL_HCB_BETA3_COARSE_DT_CODES,
                    )
                    .unwrap(),
                ],
            ],
            [
                [
                    Vlc::new(&ACPL_HCB_GAMMA_FINE_F0_BITS, &ACPL_HCB_GAMMA_FINE_F0_CODES).unwrap(),
                    Vlc::new(&ACPL_HCB_GAMMA_FINE_DF_BITS, &ACPL_HCB_GAMMA_FINE_DF_CODES).unwrap(),
                    Vlc::new(&ACPL_HCB_GAMMA_FINE_DT_BITS, &ACPL_HCB_GAMMA_FINE_DT_CODES).unwrap(),
                ],
                [
                    Vlc::new(
                        &ACPL_HCB_GAMMA_COARSE_F0_BITS,
                        &ACPL_HCB_GAMMA_COARSE_F0_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ACPL_HCB_GAMMA_COARSE_DF_BITS,
                        &ACPL_HCB_GAMMA_COARSE_DF_CODES,
                    )
                    .unwrap(),
                    Vlc::new(
                        &ACPL_HCB_GAMMA_COARSE_DT_BITS,
                        &ACPL_HCB_GAMMA_COARSE_DT_CODES,
                    )
                    .unwrap(),
                ],
            ],
        ],
    }
}

/// Output layouts per channel_mode: (nb_channels, channel mask).
pub static CHANNEL_MODE_LAYOUTS: [(i32, u64); 18] = [
    (1, 0x4),   // MONO
    (2, 0x3),   // STEREO
    (3, 0x7),   // SURROUND
    (5, 0x607), // 5POINT0
    (6, 0x60F), // 5POINT1
    (7, 0x637), // 7POINT0
    (8, 0x63F), // 7POINT1
    (7, 0x6C7), // 7POINT0_FRONT
    (7, 0x63F), // custom: 7POINT0 | LFE
    (0, 0),
    (0, 0),
    (0, 0),
    (12, 0x2D63F), // custom: 7POINT1 + TFL TFR TBL TBR
    (0, 0),
    (0, 0),
    (0, 0),
    (0, 0),
    (0, 0),
];

pub static DECODE_DELAYS: [i32; 15] = [
    288, 288, 352, 96, 96, 960, 960, 1056, 672, 672, 1312, 864, 864, 352, 352,
];

/// Per-decoder mutable state (everything reset by `flush`).
pub struct State {
    pub audio_service_type: i32,

    target_presentation: i32,

    version: i32,
    sequence_counter: i32,
    /// Previous frame's frame_len_base; a change invalidates the per-channel
    /// window history (overlap-add state) of every channel.
    frame_len_base_prev: i32,
    sequence_counter_prev: i32,
    wait_frames: i32,
    nb_wait_frames: i32,
    fs_index: i32,
    frame_rate_index: i32,
    frame_len_base: i32,
    frame_len_base_idx: i32,
    resampling_ratio: (i64, i64),
    num_qmf_timeslots: i32,
    num_aspx_timeslots: i32,
    num_ts_in_ats: i32,
    ts_offset_hfgen: i32,
    #[allow(dead_code)] // C stores it; lengths resolve through the per-channel scp
    transform_length: i32,
    iframe_global: i32,
    first_frame: i32,
    have_iframe: i32,
    nb_presentations: i32,
    payload_base: i32,
    short_program_id: i32,
    nb_substreams: i32,
    total_groups: i32,
    substream_size: [i32; 32],
    substream_type: [i32; 32],
    ch_map: [i32; 256],
    /// Per-decoder-channel delay lines for the QMF bypass path.
    qmf_bypass_delay: Vec<Vec<f32>>,

    pinfo: [PresentationInfo; 16],
    ssgroup: [SubstreamGroupInfo; 16],
    substream: Substream,
    ajoc_history: crate::ajoc::History,
    ajoc_object_decoder: Option<Box<crate::ajoc::signals::ObjectDecoder>>,
}

impl Default for State {
    fn default() -> Self {
        State {
            audio_service_type: 0,
            target_presentation: 0,
            version: 0,
            frame_len_base_prev: 0,
            sequence_counter: 0,
            sequence_counter_prev: -1,
            wait_frames: 0,
            nb_wait_frames: 0,
            fs_index: 0,
            frame_rate_index: 0,
            frame_len_base: 0,
            frame_len_base_idx: 0,
            resampling_ratio: (1, 1),
            num_qmf_timeslots: 0,
            num_aspx_timeslots: 0,
            num_ts_in_ats: 0,
            ts_offset_hfgen: 0,
            transform_length: 0,
            iframe_global: 0,
            first_frame: 1,
            have_iframe: 0,
            nb_presentations: 0,
            payload_base: 0,
            short_program_id: 0,
            nb_substreams: 0,
            total_groups: 0,
            substream_size: [0; 32],
            substream_type: [0; 32],
            ch_map: [0; 256],
            qmf_bypass_delay: Vec::new(),
            pinfo: std::array::from_fn(|_| PresentationInfo::default()),
            ssgroup: std::array::from_fn(|_| SubstreamGroupInfo::default()),
            substream: Substream::default(),
            ajoc_history: crate::ajoc::History::default(),
            ajoc_object_decoder: None,
        }
    }
}

/// Meaning of the decoded PCM planes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioKind {
    /// Speaker feeds in ascending channel-mask bit order.
    Channels,
    /// A-JOC downmix essence; unanchored planes are not speaker feeds.
    AjocCoreSignals,
    /// Reconstructed object signals, LFE first when present; not speaker feeds.
    AjocObjectSignals,
    /// Basic gain/X-position stereo projection; not an immersive renderer.
    AjocStereoPreview,
    /// Object audio rendered to the configured WAVE speaker layout.
    AjocSpeakerFeeds,
}

/// Layout information returned by [`Ac4Decoder::decode_frame_into`] when a
/// frame was produced into a caller-owned buffer.
pub struct FrameInfo {
    pub audio_kind: AudioKind,
    pub sample_rate: u32,
    /// WAVE speaker mask, or zero for unanchored A-JOC signal planes.
    pub channel_mask: u64,
    pub nb_samples: usize,
    pub key_frame: bool,
}

/// Coding tools active in the most recently parsed substream. `codec_mode`
/// selects the tool set (0 = CM_SIMPLE, 1 = CM_ASPX, 2-4 add ACPL) and the
/// `spec_frontend_*` values select the spectral frontend per channel pair
/// element (0 = SF_ASF MDCT, 1 = SF_SSF QMF).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StreamFeatures {
    pub codec_mode: i32,
    pub spec_frontend_l: i32,
    pub spec_frontend_r: i32,
    pub spec_frontend_m: i32,
    pub spec_frontend_s: i32,
}

/// A decoded audio frame: planar f32 samples (one `Vec` per channel).
pub struct Frame {
    pub audio_kind: AudioKind,
    pub sample_rate: u32,
    /// WAVE speaker mask. Zero denotes unanchored A-JOC signal planes.
    pub channel_mask: u64,
    pub nb_samples: usize,
    /// True when this frame is a sync/iframe (all information self-contained).
    pub key_frame: bool,
    pub data: Vec<Vec<f32>>,
}

pub struct Ac4Decoder {
    tables: Tables,
    st: State,
    /// When enabled, streams with no QMF-domain consumer (codec_mode <
    /// CM_ASPX: no A-SPX, no companding) skip the QMF analysis/synthesis
    /// round trip and reproduce its perfect-reconstruction identity
    /// (gain 1/32768, group delay 577) directly. Faster, but the output
    /// no longer runs through the analysis/synthesis filterbank path
    /// (~76 dB vs ~82 dB SNR against the filterbank output on real
    /// streams).
    qmf_bypass: bool,
    ajoc_core: bool,
    ajoc_metadata_enabled: bool,
    ajoc_objects: bool,
    ajoc_preview: bool,
    ajoc_render: Option<crate::ajoc::render::RenderOptions>,
    ajoc_metadata: Option<crate::ajoc::AjocMetadata>,
    ajoc_qmf_available: bool,
    variable_pairs: Vec<(usize, usize)>,
}

impl Ac4Decoder {
    /// Creates a decoder with fresh state and precomputed tables.
    pub fn new() -> Result<Ac4Decoder> {
        let shared = shared_tables();
        let mut planner = rustfft::FftPlanner::new();
        let tx = std::array::from_fn(|j| {
            std::array::from_fn(|i| {
                let len = TRANSF_LENGTH_48KHZ[j][i] as usize;
                Imdct::with_planner(len, -1.0 / len as f32, &mut planner)
            })
        });

        Ok(Ac4Decoder {
            qmf_bypass: false,
            ajoc_core: false,
            ajoc_metadata_enabled: false,
            ajoc_objects: false,
            ajoc_preview: false,
            ajoc_render: None,
            ajoc_metadata: None,
            ajoc_qmf_available: false,
            variable_pairs: Vec::with_capacity(6),
            tables: Tables {
                qmf_ana: QmfAnalysis::new(),
                qmf_syn: QmfSynthesis::new(),
                vlcs: &shared.vlcs,
                kbd_window: &shared.kbd_window,
                tx,
                quant_lut: &shared.quant_lut,
            },
            st: State::default(),
        })
    }

    // ------------------------------------------------------------------
    // Bitstream helpers (C lines 795-835)

    fn variable_bits(gb: &mut BitReader, bits: u32) -> i32 {
        let mut value: i32 = 0;

        // wrapping: C accumulates in a plain int and a corrupt stream can
        // keep the continuation bits coming until it overflows
        loop {
            value = value.wrapping_add(gb.get_bits(bits) as i32);
            let read_more = gb.get_bits1();
            if read_more != 0 {
                value = value.wrapping_shl(bits);
                value = value.wrapping_add(1 << bits);
            } else {
                break;
            }
        }

        value
    }

    fn check_sequence(&self) -> Result<()> {
        if self.st.sequence_counter > 1020 {
            return Err(invalid("invalid sequence counter"));
        }

        if self.st.sequence_counter == self.st.sequence_counter_prev + 1 {
            return Ok(());
        }
        if self.st.sequence_counter != 0 && self.st.sequence_counter_prev == 0 {
            return Ok(());
        }
        if self.st.sequence_counter == 1 && self.st.sequence_counter_prev == 1020 {
            return Ok(());
        }
        if self.st.sequence_counter == 0 && self.st.sequence_counter_prev == 0 {
            return Ok(());
        }

        Err(invalid("unexpected sequence counter"))
    }

    // ------------------------------------------------------------------
    // TOC / presentations (C lines 835-1095)

    fn frame_rate_multiply_info(&mut self, gb: &mut BitReader, p_idx: usize) -> Result<()> {
        let fri = self.st.frame_rate_index;
        let p = &mut self.st.pinfo[p_idx];
        p.multiplier_bit = 0;

        match fri {
            2..=4 => {
                p.multiplier = gb.get_bits1() as i32;
                if p.multiplier != 0 {
                    p.multiplier_bit = gb.get_bits1() as i32;
                }
                p.frame_rate_factor = if p.multiplier != 0 {
                    if p.multiplier_bit != 0 { 4 } else { 2 }
                } else {
                    1
                };
            }
            0 | 1 | 7 | 8 | 9 => {
                p.multiplier = gb.get_bits1() as i32;
                p.frame_rate_factor = if p.multiplier != 0 { 2 } else { 1 };
            }
            _ => {
                p.frame_rate_factor = 1;
            }
        }

        Ok(())
    }

    fn emdf_payloads_substream_info(&mut self, gb: &mut BitReader, e: &mut EMDFInfo) -> Result<()> {
        e.substream_index = gb.get_bits(2) as i32;
        if e.substream_index == 3 {
            e.substream_index += Self::variable_bits(gb, 2);
        }
        Ok(())
    }

    fn emdf_protection(&mut self, gb: &mut BitReader, _e: &mut EMDFInfo) -> Result<()> {
        let first = gb.get_bits(2) as i32;
        let second = gb.get_bits(2) as i32;
        let mut skip = 0i32;

        if first > 0 {
            skip += 1 << (2 * (first - 1));
        }
        if second > 0 {
            skip += 1 << (2 * (second - 1));
        }

        gb.skip_bits_long(8 * skip as i64);
        Ok(())
    }

    fn emdf_info(&mut self, gb: &mut BitReader, e: &mut EMDFInfo) -> Result<()> {
        e.version = gb.get_bits(2) as i32;
        if e.version == 3 {
            e.version += Self::variable_bits(gb, 2);
        }
        e.key_id = gb.get_bits(3) as i32;
        if e.key_id == 7 {
            e.key_id += Self::variable_bits(gb, 3);
        }

        if gb.get_bits1() != 0 {
            self.emdf_payloads_substream_info(gb, e)?;
        }

        self.emdf_protection(gb, e)?;

        Ok(())
    }

    fn content_type(&mut self, gb: &mut BitReader, _p_idx: usize) -> Result<()> {
        self.st.audio_service_type = gb.get_bits(3) as i32;

        if gb.get_bits1() != 0 {
            if gb.get_bits1() != 0 {
                gb.skip_bits(1);
                gb.skip_bits(16);
            } else {
                let language_tag_bytes = gb.get_bits(6) as i64;
                gb.skip_bits_long(8 * language_tag_bytes);
            }
        }

        Ok(())
    }

    fn ac4_hsf_ext_substream_info(
        &mut self,
        gb: &mut BitReader,
        ssi: &mut SubstreamInfo,
        substream_present: bool,
    ) -> Result<()> {
        if substream_present {
            ssi.hsf_ext_substream_index = gb.get_bits(2) as i32;
            if ssi.hsf_ext_substream_index == 3 {
                ssi.hsf_ext_substream_index += Self::variable_bits(gb, 2);
            }
        }
        Ok(())
    }

    fn ac4_substream_info(
        &mut self,
        gb: &mut BitReader,
        p_idx: usize,
        ssi_idx: usize,
    ) -> Result<()> {
        {
            let ssi = &mut self.st.pinfo[p_idx].ssinfo[ssi_idx];
            ssi.sus_ver = 0;
        }

        let channel_mode = self
            .tables
            .vlcs
            .channel_mode
            .decode(gb)
            .map_err(|_| invalid("invalid channel mode"))?;
        self.st.pinfo[p_idx].ssinfo[ssi_idx].channel_mode = channel_mode;

        let mut channel_mode = channel_mode;
        if channel_mode == 16 {
            channel_mode += Self::variable_bits(gb, 2);
            self.st.pinfo[p_idx].ssinfo[ssi_idx].channel_mode = channel_mode;
        }

        let fs_index = self.st.fs_index;
        let ssi = &mut self.st.pinfo[p_idx].ssinfo[ssi_idx];
        if fs_index == 1 && gb.get_bits1() != 0 {
            ssi.sf_multiplier = 1 + gb.get_bits1() as i32;
        }

        if gb.get_bits1() != 0 {
            ssi.bitrate_indicator = self
                .tables
                .vlcs
                .bitrate_indicator
                .decode(gb)
                .map_err(|_| invalid("invalid bitrate indicator"))?;
        }

        if matches!(ssi.channel_mode, 7..=10) {
            ssi.add_ch_base = gb.get_bits1() as i32;
        }

        if gb.get_bits1() != 0 {
            self.content_type(gb, p_idx)?;
        }

        let frame_rate_factor = self.st.pinfo[p_idx].frame_rate_factor;
        let ssi = &mut self.st.pinfo[p_idx].ssinfo[ssi_idx];
        for i in 0..frame_rate_factor.max(0) as usize {
            ssi.iframe[i] = gb.get_bits1() as i32;
        }

        ssi.substream_index = gb.get_bits(2) as i32;
        if ssi.substream_index == 3 {
            ssi.substream_index += Self::variable_bits(gb, 2);
        }
        let substream_index = ssi.substream_index;
        if substream_index < 0 || substream_index >= self.st.substream_type.len() as i32 {
            return Err(invalid("substream index out of range"));
        }
        self.st.substream_type[substream_index as usize] = enums::ST_SUBSTREAM;

        Ok(())
    }

    fn presentation_config_ext_info(&mut self, gb: &mut BitReader) -> Result<()> {
        let mut n_skip_bytes = gb.get_bits(5) as i64;
        if gb.get_bits1() != 0 {
            n_skip_bytes += (Self::variable_bits(gb, 2) as i64) << 5;
        }

        gb.skip_bits_long(8 * n_skip_bytes);
        Ok(())
    }

    fn ac4_presentation_info(&mut self, gb: &mut BitReader, p_idx: usize) -> Result<()> {
        {
            let p = &mut self.st.pinfo[p_idx];
            p.single_substream = gb.get_bits1() as i32;
            if p.single_substream != 1 {
                p.presentation_config = gb.get_bits(3) as i32;
                if p.presentation_config == 7 {
                    p.presentation_config += Self::variable_bits(gb, 2);
                }
            }

            p.presentation_version = gb.get_unary(0, 31) as i32;
        }

        self.st.total_groups = 0;

        self.st.pinfo[p_idx].add_emdf_substreams = 0;
        if self.st.pinfo[p_idx].single_substream != 1
            && self.st.pinfo[p_idx].presentation_config == 6
        {
            self.st.pinfo[p_idx].add_emdf_substreams = 1;
        } else {
            self.st.pinfo[p_idx].mdcompat = gb.get_bits(3) as i32;

            if gb.get_bits1() != 0 {
                self.st.pinfo[p_idx].presentation_id = Self::variable_bits(gb, 2);
            }

            self.frame_rate_multiply_info(gb, p_idx)?;
            {
                let mut e = EMDFInfo::default();
                self.emdf_info(gb, &mut e)?;
                self.st.pinfo[p_idx].emdf[0] = e;
            }

            if self.st.pinfo[p_idx].single_substream == 1 {
                self.ac4_substream_info(gb, p_idx, 0)?;
            } else {
                self.st.pinfo[p_idx].hsf_ext = gb.get_bits1() as i32;
                match self.st.pinfo[p_idx].presentation_config {
                    0 => {
                        self.ac4_substream_info(gb, p_idx, 0)?;
                        if self.st.pinfo[p_idx].hsf_ext != 0 {
                            let mut ssi = self.st.pinfo[p_idx].ssinfo[0].clone();
                            self.ac4_hsf_ext_substream_info(gb, &mut ssi, true)?;
                            self.st.pinfo[p_idx].ssinfo[0] = ssi;
                        }
                        self.ac4_substream_info(gb, p_idx, 1)?;
                    }
                    1..=5 => {
                        // FIXME
                    }
                    _ => {
                        self.presentation_config_ext_info(gb)?;
                    }
                }
            }

            self.st.pinfo[p_idx].pre_virtualized = gb.get_bits1() as i32;
            self.st.pinfo[p_idx].add_emdf_substreams = gb.get_bits1() as i32;
        }

        if self.st.pinfo[p_idx].add_emdf_substreams != 0 {
            let mut n = gb.get_bits(2) as i32;
            if n == 0 {
                n = Self::variable_bits(gb, 2) + 4;
            }
            self.st.pinfo[p_idx].n_add_emdf_substreams = n;
            if n as usize > self.st.pinfo[p_idx].emdf.len() {
                return Err(invalid("too many emdf substreams"));
            }

            for i in 0..n as usize {
                let mut e = EMDFInfo::default();
                self.emdf_info(gb, &mut e)?;
                self.st.pinfo[p_idx].emdf[i] = e;
            }
        }

        Ok(())
    }

    fn substream_index_table(&mut self, gb: &mut BitReader) -> Result<()> {
        let mut nb_substreams = gb.get_bits(2) as i32;
        if nb_substreams == 0 {
            nb_substreams = Self::variable_bits(gb, 2) + 4;
        }
        self.st.nb_substreams = nb_substreams;

        if nb_substreams as usize > self.st.substream_size.len() {
            return Err(invalid("too many substreams"));
        }

        let size_present = if nb_substreams == 1 {
            gb.get_bits1()
        } else {
            1
        };

        if size_present != 0 {
            for i in 0..nb_substreams as usize {
                let more_bits = gb.get_bits1();
                let mut size = gb.get_bits(10) as i32;
                if more_bits != 0 {
                    size += Self::variable_bits(gb, 2) << 10;
                }
                self.st.substream_size[i] = size;
            }
        }

        Ok(())
    }

    fn presentation_substream_info(&mut self, gb: &mut BitReader, p_idx: usize) -> Result<()> {
        let psi = &mut self.st.pinfo[p_idx].psinfo;
        psi.alternative = gb.get_bits1() as i32;
        psi.pres_ndot = gb.get_bits1() as i32;
        psi.substream_index = gb.get_bits(2) as i32;
        if psi.substream_index == 3 {
            psi.substream_index += Self::variable_bits(gb, 2);
        }

        let substream_index = psi.substream_index;
        if substream_index < 0 || substream_index as usize >= self.st.substream_type.len() {
            return Err(invalid("presentation substream index out of range"));
        }

        self.st.substream_type[substream_index as usize] = enums::ST_PRESENTATION;

        Ok(())
    }

    fn frame_rate_fractions_info(&mut self, gb: &mut BitReader, p_idx: usize) -> Result<()> {
        let fri = self.st.frame_rate_index;
        let p = &mut self.st.pinfo[p_idx];
        p.frame_rate_fraction = 1;
        if (5..=9).contains(&fri) && p.frame_rate_factor == 1 && gb.get_bits1() != 0 {
            p.frame_rate_fraction = 2;
        }

        if (10..=12).contains(&fri) && gb.get_bits1() != 0 {
            p.frame_rate_fraction = if gb.get_bits1() != 0 { 4 } else { 2 };
        }

        Ok(())
    }

    fn oamd_substream_info(
        &mut self,
        gb: &mut BitReader,
        substreams_present: bool,
    ) -> Result<Option<i32>> {
        gb.skip_bits(1);
        if substreams_present {
            let mut substream_index = gb.get_bits(2) as i32;
            if substream_index == 3 {
                substream_index += Self::variable_bits(gb, 2);
            }
            return Ok(Some(substream_index));
        }
        Ok(None)
    }

    fn ac4_substream_info_chan(
        &mut self,
        gb: &mut BitReader,
        g_idx: usize,
        substreams_present: bool,
        sus_ver: i32,
    ) -> Result<()> {
        let mut channel_mode = self
            .tables
            .vlcs
            .channel_mode
            .decode(gb)
            .map_err(|_| invalid("invalid channel mode"))?;

        if channel_mode == 16 {
            channel_mode += Self::variable_bits(gb, 2);
        }

        if (5..=10).contains(&channel_mode) {
            for i in 0..self.st.nb_presentations as usize {
                if self.st.pinfo[i].presentation_version == 2 {
                    channel_mode = 1; /* immersive stereo */
                    break;
                }
            }
        }

        let ssi = &mut self.st.ssgroup[g_idx].ssinfo;
        ssi.sus_ver = sus_ver;
        ssi.channel_mode = channel_mode;

        if matches!(channel_mode, 11..=14) {
            ssi.back_channels_present = gb.get_bits1() as i32;
            ssi.centre_present = gb.get_bits1() as i32;
            ssi.top_channels_present = gb.get_bits(2) as i32;
        }

        let fs_index = self.st.fs_index;
        let ssi = &mut self.st.ssgroup[g_idx].ssinfo;
        if fs_index != 0 && gb.get_bits1() != 0 {
            ssi.sf_multiplier = 1 + gb.get_bits1() as i32;
        }

        if gb.get_bits1() != 0 {
            ssi.bitrate_indicator = self
                .tables
                .vlcs
                .bitrate_indicator
                .decode(gb)
                .map_err(|_| invalid("invalid bitrate indicator"))?;
        }

        if matches!(channel_mode, 7..=10) {
            ssi.add_ch_base = gb.get_bits1() as i32;
        }

        let frame_rate_factor = self.st.pinfo[0].frame_rate_factor;
        for i in 0..frame_rate_factor.max(0) as usize {
            ssi.iframe[i] = gb.get_bits1() as i32;
        }

        if substreams_present {
            ssi.substream_index = gb.get_bits(2) as i32;
            if ssi.substream_index == 3 {
                ssi.substream_index += Self::variable_bits(gb, 2);
            }
        }

        Ok(())
    }

    // Returns a speaker mask only for completely speaker-anchored beds.
    // Dynamic/ISF assignments remain distinct from a conventional channel bed.
    fn ac4_bed_dyn_obj_assignment(&mut self, gb: &mut BitReader, n_signals: i32) -> Result<u64> {
        if gb.get_bits1() != 0 {
            return Ok(0);
        }
        if gb.get_bits1() != 0 {
            gb.skip_bits(3);
            return Ok(0);
        }
        const BEDS: [u64; 8] = [0x3, 0x7, 0x607, 0, 0x2d607, 0x637, 0, 0x2d637];
        if gb.get_bits1() != 0 {
            return Ok(BEDS[gb.get_bits(3) as usize]);
        }
        if gb.get_bits1() != 0 {
            // Mask positions are transmitted MSB first. Keep unknown speaker
            // positions unsupported instead of inventing a channel order.
            if gb.get_bits1() != 0 {
                gb.skip_bits(17);
            } else {
                gb.skip_bits(10);
            }
            return Ok(0);
        }
        let n_bed_signals = if n_signals > 1 {
            let width = 32 - ((n_signals - 1) as u32).leading_zeros();
            gb.get_bits(width) as i32 + 1
        } else {
            1
        };
        if n_bed_signals > n_signals {
            return Err(invalid("invalid bed signal count"));
        }
        for _ in 0..n_bed_signals {
            gb.skip_bits(4);
        }
        Ok(0)
    }

    fn ac4_substream_info_ajoc(
        &mut self,
        gb: &mut BitReader,
        ssi: &mut SubstreamInfo,
        substreams_present: bool,
    ) -> Result<()> {
        ssi.lfe = gb.get_bits1() as i32;
        ssi.static_dmx = gb.get_bits1() as i32;
        ssi.dynamic_dmx = false;

        if ssi.static_dmx != 0 {
            ssi.n_fullband_dmx_signals = 5;
            ssi.core_bed_mask = 0x607;
        } else {
            ssi.n_fullband_dmx_signals = gb.get_bits(4) as i32 + 1;
            let n = ssi.n_fullband_dmx_signals;
            ssi.dynamic_dmx = gb.peek_bits(1) != 0;
            ssi.core_bed_mask = self.ac4_bed_dyn_obj_assignment(gb, n)?;
        }

        ssi.oamd_common = if gb.get_bits1() != 0 {
            // b_oamd_common_data_present
            let end = gb
                .bits_count()
                .saturating_add(gb.bits_left().max(0) as usize);
            Some(crate::ajoc::common::parse(gb, end)?)
        } else {
            None
        };

        ssi.n_fullband_upmix_signals = gb.get_bits(4) as i32 + 1;
        if ssi.n_fullband_upmix_signals == 16 {
            ssi.n_fullband_upmix_signals += Self::variable_bits(gb, 3);
        }
        if ssi.n_fullband_upmix_signals > 4096 {
            /* arbitrary value to prevent slowdowns */
            return Err(invalid("too many upmix signals"));
        }

        let n = ssi.n_fullband_upmix_signals;
        ssi.dynamic_upmix = gb.peek_bits(1) != 0;
        let _ = self.ac4_bed_dyn_obj_assignment(gb, n)?;

        let fs_index = self.st.fs_index;
        if fs_index == 1 && gb.get_bits1() != 0 {
            // b_sf_multiplier
            ssi.sf_multiplier = gb.get_bits1() as i32;
        }

        if gb.get_bits1() != 0 {
            // b_bitrate_info
            ssi.bitrate_indicator = self
                .tables
                .vlcs
                .bitrate_indicator
                .decode(gb)
                .map_err(|_| invalid("invalid bitrate indicator"))?;
        }

        let frame_rate_factor = self.st.pinfo[0].frame_rate_factor;
        for i in 0..frame_rate_factor.max(0) as usize {
            ssi.audio_ndot[i] = gb.get_bits1() as i32;
        }

        if substreams_present {
            ssi.substream_index = gb.get_bits(2) as i32;
            if ssi.substream_index == 3 {
                ssi.substream_index += Self::variable_bits(gb, 2);
            }
        }

        Ok(())
    }

    fn ac4_substream_info_obj(
        &mut self,
        gb: &mut BitReader,
        ssi: &mut SubstreamInfo,
        substreams_present: bool,
    ) -> Result<()> {
        let n_objects_code = gb.get_bits(3) as i32;
        match n_objects_code {
            0..=3 => {
                ssi.n_objects = ssi.lfe + n_objects_code;
            }
            4 => {
                ssi.n_objects = ssi.lfe + 5;
            }
            _ => return Err(invalid("invalid n_objects_code")),
        }

        if gb.get_bits1() != 0 {
            // b_dynamic_objects
            gb.skip_bits(1); // b_lfe
        } else if gb.get_bits1() != 0 {
            // b_bed_objects
            if gb.get_bits1() != 0 {
                // b_bed_start
                if gb.get_bits1() != 0 {
                    // b_ch_assign_code
                    gb.skip_bits(3); // bed_chan_assign_code
                } else if gb.get_bits1() != 0 {
                    // b_nonstd_bed_channel_assignment
                    gb.skip_bits(17); // nonstd_bed_channel_assignment_mask
                } else {
                    gb.skip_bits(10); // std_bed_channel_assignment_mask
                }
            }
        } else if gb.get_bits1() != 0 {
            // b_isf
            if gb.get_bits1() != 0 {
                // b_isf_start
                gb.skip_bits(3); // isf_config
            }
        } else {
            let res_bytes = gb.get_bits(4) as i64;
            gb.skip_bits_long(8 * res_bytes); // reserved_data
        }

        let fs_index = self.st.fs_index;
        if fs_index == 1 && gb.get_bits1() != 0 {
            // b_sf_multiplier
            ssi.sf_multiplier = gb.get_bits1() as i32;
        }

        if gb.get_bits1() != 0 {
            // b_bitrate_info
            ssi.bitrate_indicator = self
                .tables
                .vlcs
                .bitrate_indicator
                .decode(gb)
                .map_err(|_| invalid("invalid bitrate indicator"))?;
        }

        let frame_rate_factor = self.st.pinfo[0].frame_rate_factor;
        for _ in 0..frame_rate_factor.max(0) as usize {
            gb.skip_bits(1); // b_audio_ndot
        }

        if substreams_present {
            ssi.substream_index = gb.get_bits(2) as i32;
            if ssi.substream_index == 3 {
                ssi.substream_index += Self::variable_bits(gb, 2);
            }
        }

        Ok(())
    }

    fn ac4_substream_group_info(&mut self, gb: &mut BitReader, g_idx: usize) -> Result<()> {
        let substreams_present = gb.get_bits1() != 0;
        let hsf_ext = gb.get_bits1() != 0;
        let mut n_lf_substreams;
        if gb.get_bits1() != 0 {
            n_lf_substreams = 1;
        } else {
            n_lf_substreams = gb.get_bits(2) as i32 + 2;
            if n_lf_substreams == 5 {
                n_lf_substreams += Self::variable_bits(gb, 2);
                if n_lf_substreams > 16 {
                    /* arbitrary limit to prevent slowdowns */
                    return Err(invalid("too many LF substreams"));
                }
            }
        }

        self.st.ssgroup[g_idx].channel_coded = gb.get_bits1() as i32;
        if self.ajoc_core && self.st.ssgroup[g_idx].channel_coded == 0 && n_lf_substreams != 1 {
            return Err(unsupported("multiple object substreams in one group"));
        }
        self.st.ssgroup[g_idx].ajoc = 0;
        self.st.ssgroup[g_idx].oamd_index = None;
        if self.st.ssgroup[g_idx].channel_coded != 0 {
            for _sus in 0..n_lf_substreams {
                let sus_ver = if self.st.version == 1 {
                    gb.get_bits1() as i32
                } else {
                    1
                };

                self.ac4_substream_info_chan(gb, g_idx, substreams_present, sus_ver)?;
                if hsf_ext {
                    let mut ssi = self.st.ssgroup[g_idx].ssinfo.clone();
                    self.ac4_hsf_ext_substream_info(gb, &mut ssi, substreams_present)?;
                    self.st.ssgroup[g_idx].ssinfo = ssi;
                }
            }
        } else {
            if gb.get_bits1() != 0 {
                self.st.ssgroup[g_idx].oamd_index =
                    self.oamd_substream_info(gb, substreams_present)?;
            }
            for _sus in 0..n_lf_substreams {
                if gb.get_bits1() != 0 {
                    self.st.ssgroup[g_idx].ajoc = 1;
                    let mut ssi = self.st.ssgroup[g_idx].ssinfo.clone();
                    let r = self.ac4_substream_info_ajoc(gb, &mut ssi, substreams_present);
                    self.st.ssgroup[g_idx].ssinfo = ssi;
                    r?;
                } else {
                    let mut ssi = self.st.ssgroup[g_idx].ssinfo.clone();
                    let r = self.ac4_substream_info_obj(gb, &mut ssi, substreams_present);
                    self.st.ssgroup[g_idx].ssinfo = ssi;
                    r?;
                }
                if hsf_ext {
                    let mut ssi = self.st.ssgroup[g_idx].ssinfo.clone();
                    self.ac4_hsf_ext_substream_info(gb, &mut ssi, substreams_present)?;
                    self.st.ssgroup[g_idx].ssinfo = ssi;
                }
            }
        }

        if gb.get_bits1() != 0 {
            self.content_type(gb, 0)?;
        }

        Ok(())
    }

    fn ac4_sgi_specifier(&mut self, gb: &mut BitReader, g_idx: usize) -> Result<()> {
        if self.st.version == 1 {
            self.ac4_substream_group_info(gb, g_idx)?;
            // FIXME: g->group_index = ?
        } else {
            let mut group_index = gb.get_bits(3) as i32;
            if group_index == 7 {
                group_index += Self::variable_bits(gb, 2);
            }
            self.st.ssgroup[g_idx].group_index = group_index;
        }

        let gi = self.st.ssgroup[g_idx].group_index;
        self.st.total_groups = self.st.total_groups.max(gi);

        Ok(())
    }

    fn ac4_presentation_v1_info(&mut self, gb: &mut BitReader, p_idx: usize) -> Result<()> {
        let single_substream_group = gb.get_bits1() as i32;
        if single_substream_group != 1 {
            let mut pc = gb.get_bits(3) as i32;
            if pc == 7 {
                pc += Self::variable_bits(gb, 2);
            }
            self.st.pinfo[p_idx].presentation_config = pc;
        }
        if self.st.version != 1 {
            self.st.pinfo[p_idx].presentation_version = gb.get_unary(0, 31) as i32;
        }

        self.st.total_groups = 0;

        if single_substream_group != 1 && self.st.pinfo[p_idx].presentation_config == 6 {
            self.st.pinfo[p_idx].add_emdf_substreams = 1;
        } else {
            if self.st.version != 1 {
                self.st.pinfo[p_idx].mdcompat = gb.get_bits(3) as i32;
            }

            if gb.get_bits1() != 0 {
                self.st.pinfo[p_idx].presentation_id = Self::variable_bits(gb, 2);
            }

            self.frame_rate_multiply_info(gb, p_idx)?;
            self.frame_rate_fractions_info(gb, p_idx)?;
            {
                let mut e = EMDFInfo::default();
                self.emdf_info(gb, &mut e)?;
                self.st.pinfo[p_idx].emdf[0] = e;
            }

            if gb.get_bits1() != 0 {
                self.st.pinfo[p_idx].enable_presentation = gb.get_bits1() as i32;
            }

            if single_substream_group == 1 {
                self.ac4_sgi_specifier(gb, 0)?;
                self.st.pinfo[p_idx].n_substream_groups = 1;
            } else {
                self.st.pinfo[p_idx].multi_pid = gb.get_bits1() as i32;
                match self.st.pinfo[p_idx].presentation_config {
                    0 => {
                        /* Music and Effects + Dialogue */
                        self.ac4_sgi_specifier(gb, 0)?;
                        self.ac4_sgi_specifier(gb, 1)?;
                        self.st.pinfo[p_idx].n_substream_groups = 2;
                    }
                    1 => {
                        /* Main + DE */
                        self.ac4_sgi_specifier(gb, 0)?;
                        self.ac4_sgi_specifier(gb, 1)?;
                        self.st.pinfo[p_idx].n_substream_groups = 1;
                    }
                    2 => {
                        /* Main + Associated Audio */
                        self.ac4_sgi_specifier(gb, 0)?;
                        self.ac4_sgi_specifier(gb, 1)?;
                        self.st.pinfo[p_idx].n_substream_groups = 2;
                    }
                    3 => {
                        /* Music and Effects + Dialogue + Associated Audio */
                        self.ac4_sgi_specifier(gb, 0)?;
                        self.ac4_sgi_specifier(gb, 1)?;
                        self.ac4_sgi_specifier(gb, 2)?;
                        self.st.pinfo[p_idx].n_substream_groups = 3;
                    }
                    4 => {
                        /* Main + DE + Associated Audio */
                        self.ac4_sgi_specifier(gb, 0)?;
                        self.ac4_sgi_specifier(gb, 1)?;
                        self.ac4_sgi_specifier(gb, 2)?;
                        self.st.pinfo[p_idx].n_substream_groups = 2;
                    }
                    5 => {
                        /* Arbitrary number of roles and substream groups */
                        let mut n = gb.get_bits(2) as i32 + 2;
                        if n == 5 {
                            n += Self::variable_bits(gb, 2);
                        }
                        if n as usize > self.st.ssgroup.len() {
                            return Err(invalid("too many substream groups"));
                        }
                        self.st.pinfo[p_idx].n_substream_groups = n;

                        for sg in 0..n as usize {
                            self.ac4_sgi_specifier(gb, sg)?;
                        }
                    }
                    _ => {
                        /* EMDF and other data */
                        self.presentation_config_ext_info(gb)?;
                    }
                }
            }
            self.st.pinfo[p_idx].pre_virtualized = gb.get_bits1() as i32;
            self.st.pinfo[p_idx].add_emdf_substreams = gb.get_bits1() as i32;
            self.presentation_substream_info(gb, p_idx)?;
        }

        if self.st.pinfo[p_idx].add_emdf_substreams != 0 {
            let mut n = gb.get_bits(2) as i32;
            if n == 0 {
                n = Self::variable_bits(gb, 2) + 4;
            }
            self.st.pinfo[p_idx].n_add_emdf_substreams = n;
            if n as usize > self.st.pinfo[p_idx].emdf.len() {
                return Err(invalid("too many emdf substreams"));
            }

            for i in 0..n as usize {
                let mut e = EMDFInfo::default();
                self.emdf_info(gb, &mut e)?;
                self.st.pinfo[p_idx].emdf[i] = e;
            }
        }

        Ok(())
    }

    // ------------------------------------------------------------------
    // TOC (C lines 1599-1710)

    fn get_num_ts_in_ats(frame_length: i32) -> i32 {
        if (1536..=2048).contains(&frame_length) {
            2
        } else {
            1
        }
    }

    fn ac4_toc(&mut self, gb: &mut BitReader) -> Result<()> {
        self.st.version = gb.get_bits(2) as i32;
        if self.st.version == 3 {
            self.st.version += Self::variable_bits(gb, 2);
        }
        self.st.sequence_counter_prev = self.st.sequence_counter;
        self.st.sequence_counter = gb.get_bits(10) as i32;

        self.st.wait_frames = gb.get_bits1() as i32;
        if self.st.wait_frames != 0 {
            self.st.nb_wait_frames = gb.get_bits(3) as i32;
            if self.st.nb_wait_frames > 0 {
                gb.skip_bits(2);
            }
        }

        self.st.fs_index = gb.get_bits1() as i32;
        self.st.frame_rate_index = gb.get_bits(4) as i32;
        let fri = self.st.frame_rate_index as usize;
        // indices 14/15 map to frame_len_base 0 (reserved); reject like the
        // reference does instead of propagating an unusable length
        if fri >= FRAME_LEN_BASE_48KHZ.len() || FRAME_LEN_BASE_48KHZ[fri] == 0 {
            return Err(invalid("invalid frame rate index"));
        }
        self.st.frame_len_base = FRAME_LEN_BASE_48KHZ[fri] as i32;
        self.st.num_ts_in_ats = Self::get_num_ts_in_ats(self.st.frame_len_base);
        self.st.frame_len_base_idx = FRAME_LEN_BASE_IDX_48KHZ[fri] as i32;
        self.st.resampling_ratio = RESAMPLING_RATIOS[fri];
        self.st.num_qmf_timeslots = self.st.frame_len_base / MAX_QMF_BANDS as i32;
        self.st.num_aspx_timeslots = self.st.num_qmf_timeslots / self.st.num_ts_in_ats;
        self.st.ts_offset_hfgen = 3 * self.st.num_ts_in_ats;
        self.st.iframe_global = gb.get_bits1() as i32;
        if self.st.iframe_global != 0 {
            self.st.have_iframe = 1;
        } else {
            self.check_sequence()?;
        }
        if gb.get_bits1() != 0 {
            self.st.nb_presentations = 1;
        } else if gb.get_bits1() != 0 {
            let n = 2 + Self::variable_bits(gb, 2);
            if n as usize > self.st.pinfo.len() {
                return Err(invalid("too many presentations"));
            }
            self.st.nb_presentations = n;
        } else {
            self.st.nb_presentations = 0;
        }

        self.st.payload_base = 0;
        if gb.get_bits1() != 0 {
            let mut pb = gb.get_bits(5) as i32 + 1;
            if pb == 0x20 {
                pb += Self::variable_bits(gb, 3);
            }
            self.st.payload_base = pb;
        }

        if self.st.version <= 1 {
            for i in 0..self.st.nb_presentations as usize {
                self.ac4_presentation_info(gb, i)?;
            }
        } else {
            if gb.get_bits1() != 0 {
                self.st.short_program_id = gb.get_bits(16) as i32;
                if gb.get_bits1() != 0 {
                    gb.skip_bits_long(16 * 8);
                }
            }

            for i in 0..self.st.nb_presentations as usize {
                self.ac4_presentation_v1_info(gb, i)?;
            }

            if self.st.total_groups + 1 >= self.st.ssgroup.len() as i32 {
                return Err(invalid("too many substream groups"));
            }

            for i in 0..=self.st.total_groups as usize {
                self.ac4_substream_group_info(gb, i)?;
            }
        }

        self.substream_index_table(gb)?;

        gb.align();

        Ok(())
    }

    // ------------------------------------------------------------------
    // Codec config (C lines 1709-1795)

    fn sb_to_pb(acpl_num_param_bands_id: i32, acpl_qmf_band: i32) -> i32 {
        let id = acpl_num_param_bands_id as usize;
        let b = acpl_qmf_band;
        if (0..=8).contains(&b) {
            return QMF_SUBBANDS[b as usize][id] as i32;
        }
        if (9..=10).contains(&b) {
            return QMF_SUBBANDS[9][id] as i32;
        }
        if (11..=13).contains(&b) {
            return QMF_SUBBANDS[10][id] as i32;
        }
        if (14..=17).contains(&b) {
            return QMF_SUBBANDS[11][id] as i32;
        }
        if (18..=22).contains(&b) {
            return QMF_SUBBANDS[12][id] as i32;
        }
        if (23..=34).contains(&b) {
            return QMF_SUBBANDS[13][id] as i32;
        }
        if (35..=63).contains(&b) {
            return QMF_SUBBANDS[14][id] as i32;
        }
        0
    }

    fn acpl_config_1ch(&mut self, gb: &mut BitReader, mode: i32) -> Result<()> {
        let ss = &mut self.st.substream;
        ss.acpl_qmf_band = 0;
        ss.acpl_param_band = 0;
        ss.acpl_num_param_bands_id = gb.get_bits(2) as i32;
        ss.acpl_quant_mode[0] = gb.get_bits1() as u8;
        if mode == enums::ACPL_PARTIAL {
            ss.acpl_qmf_band = gb.get_bits(3) as i32 + 1;
            ss.acpl_param_band = Self::sb_to_pb(ss.acpl_num_param_bands_id, ss.acpl_qmf_band);
        }

        Ok(())
    }

    fn acpl_config_2ch(&mut self, gb: &mut BitReader) -> Result<()> {
        let ss = &mut self.st.substream;
        ss.acpl_qmf_band = 0;
        ss.acpl_param_band = 0;
        ss.acpl_num_param_bands_id = gb.get_bits(2) as i32;
        ss.acpl_quant_mode[0] = gb.get_bits1() as u8;
        ss.acpl_quant_mode[1] = gb.get_bits1() as u8;

        Ok(())
    }

    fn aspx_config(&mut self, gb: &mut BitReader) {
        let ss = &mut self.st.substream;
        ss.aspx_quant_mode_env = gb.get_bits1() as i32;
        ss.prev_aspx_start_freq = ss.aspx_start_freq;
        ss.aspx_start_freq = gb.get_bits(3) as i32;
        ss.prev_aspx_stop_freq = ss.aspx_stop_freq;
        ss.aspx_stop_freq = gb.get_bits(2) as i32;
        ss.prev_aspx_master_freq_scale = ss.aspx_master_freq_scale;
        ss.aspx_master_freq_scale = gb.get_bits1() as i32;
        ss.aspx_interpolation = gb.get_bits1() as i32;
        ss.aspx_preflat = gb.get_bits1() as i32;
        ss.aspx_limiter = gb.get_bits1() as i32;
        ss.aspx_noise_sbg = gb.get_bits(2) as i32;
        ss.aspx_num_env_bits_fixfix = gb.get_bits1() as i32;
        ss.aspx_freq_res_mode = gb.get_bits(2) as i32;
    }

    // ------------------------------------------------------------------
    // ASF transform / scale factor band helpers (C lines 1783-2160)

    fn transf_length_tab_row(&self) -> usize {
        match self.st.frame_len_base {
            2048 => 0,
            1920 => 1,
            1536 => 2,
            1024 => 3,
            960 => 4,
            768 => 5,
            512 => 6,
            384 => 7,
            _ => panic!("invalid frame_len_base"),
        }
    }

    fn get_transfer_length_from_idx(&self, idx: i32) -> i32 {
        TRANSF_LENGTH_48KHZ[self.transf_length_tab_row()][idx as usize] as i32
    }

    fn asf_transform_info(&mut self, gb: &mut BitReader, ch: usize) -> Result<()> {
        if self.st.frame_len_base >= 1536 {
            let long_frame = gb.get_bits1() as u8;
            if long_frame == 0 {
                let idx0 = gb.get_bits(2) as u8;
                let idx1 = gb.get_bits(2) as u8;
                let tl0 = self.get_transfer_length_from_idx(idx0 as i32);
                let tl1 = self.get_transfer_length_from_idx(idx1 as i32);
                let ssch = &mut self.st.substream.ssch[ch];
                ssch.scp.long_frame = long_frame;
                ssch.scp.transf_length_idx[0] = idx0;
                ssch.scp.transf_length_idx[1] = idx1;
                ssch.scp.transf_length[0] = tl0;
                ssch.scp.transf_length[1] = tl1;
            } else {
                let flb = self.st.frame_len_base;
                let ssch = &mut self.st.substream.ssch[ch];
                ssch.scp.long_frame = long_frame;
                ssch.scp.transf_length[0] = flb;
                ssch.scp.transf_length[1] = 0;
            }
        } else {
            let idx0 = gb.get_bits(2) as u8;
            let tl0 = self.get_transfer_length_from_idx(idx0 as i32);
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.scp.long_frame = 0;
            ssch.scp.transf_length_idx[0] = idx0;
            ssch.scp.transf_length[0] = tl0;
        }

        Ok(())
    }

    fn get_msfbl_bits(transf_length: i32) -> u32 {
        if (1536..=2048).contains(&transf_length) {
            3
        } else {
            2
        }
    }

    fn get_grp_bits(&self, ch: usize) -> Result<i32> {
        let ssch = &self.st.substream.ssch[ch];
        if self.st.frame_len_base >= 1536 && ssch.scp.long_frame == 1 {
            return Ok(0);
        }

        if self.st.frame_len_base >= 1536 && ssch.scp.long_frame == 0 {
            let i0 = ssch.scp.transf_length_idx[0] as usize;
            let i1 = ssch.scp.transf_length_idx[1] as usize;
            if i0 >= N_GRP_BITS_A.len() || i1 >= N_GRP_BITS_A[0].len() {
                return Err(invalid("transf_length_idx out of range"));
            }
            return Ok(N_GRP_BITS_A[i0][i1] as i32);
        }

        if self.st.frame_len_base < 1536 && self.st.frame_len_base > 512 {
            let i0 = ssch.scp.transf_length_idx[0] as usize;
            if i0 >= N_GRP_BITS_B.len() {
                return Err(invalid("transf_length_idx out of range"));
            }
            return Ok(N_GRP_BITS_B[i0] as i32);
        }

        if self.st.frame_len_base <= 512 {
            let i0 = ssch.scp.transf_length_idx[0] as usize;
            if i0 >= N_GRP_BITS_C.len() {
                return Err(invalid("transf_length_idx out of range"));
            }
            return Ok(N_GRP_BITS_C[i0] as i32);
        }

        Ok(0)
    }

    fn get_msfb_bits(transf_length: i32) -> u32 {
        if (384..=2048).contains(&transf_length) {
            6
        } else if (192..=256).contains(&transf_length) {
            5
        } else {
            4
        }
    }

    fn get_side_bits(transf_length: i32) -> u32 {
        if (480..=2048).contains(&transf_length) {
            5
        } else if (240..=384).contains(&transf_length) {
            4
        } else {
            3
        }
    }

    // ------------------------------------------------------------------
    // ASF / SSF bitstream (C lines 2165-2963)

    fn asf_psy_elements(&mut self, ch: usize, n_grp_bits: i32) -> Result<()> {
        let flb = self.st.frame_len_base;

        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.scp.num_windows = 1;
            ssch.scp.num_window_groups = 1;
            ssch.scp.window_to_group[0] = 0;

            if ssch.scp.long_frame == 0 {
                ssch.scp.num_windows = (n_grp_bits + 1) as u8;
                if ssch.scp.different_framing != 0 {
                    let num_windows_0 = 1i32 << (3 - ssch.scp.transf_length_idx[0] as i32);

                    let mut i = n_grp_bits;
                    while i >= num_windows_0 {
                        ssch.scp.scale_factor_grouping[i as usize] =
                            ssch.scp.scale_factor_grouping[i as usize - 1];
                        i -= 1;
                    }

                    ssch.scp.scale_factor_grouping[num_windows_0 as usize - 1] = 0;
                    ssch.scp.num_windows += 1;
                }

                for i in 0..ssch.scp.num_windows as i32 - 1 {
                    if ssch.scp.scale_factor_grouping[i as usize] == 0 {
                        ssch.scp.num_window_groups += 1;
                    }

                    ssch.scp.window_to_group[i as usize + 1] = ssch.scp.num_window_groups - 1;
                }
            }
        }

        let mut group_offset = 0i32;
        let mut win_offset = 0i32;
        let mut win = 0i32;
        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.offset2sfb = [0; 8192];
            ssch.offset2g = [0; 8192];
        }

        let num_window_groups = self.st.substream.ssch[ch].scp.num_window_groups as i32;
        for g in 0..num_window_groups {
            let (transf_length_g, _) = get_transf_length_(flb, &self.st.substream.ssch[ch], g);
            let sfb_offset = get_sfb_offset(transf_length_g);
            let sfb_max_size = get_sfb_size(transf_length_g);

            {
                let ssch = &mut self.st.substream.ssch[ch];
                ssch.scp.num_win_in_group[g as usize] = 0;
                for w in 0..ssch.scp.num_windows {
                    if ssch.scp.window_to_group[w as usize] as i32 == g {
                        ssch.scp.num_win_in_group[g as usize] += 1;
                    }
                }
            }

            let max_sfb = get_max_sfb_(flb, &self.st.substream.ssch[ch], g);
            if max_sfb >= sfb_max_size {
                return Err(invalid("max_sfb > sfb_max_size"));
            }
            let nwig = self.st.substream.ssch[ch].scp.num_win_in_group[g as usize] as i32;
            {
                let ssch = &mut self.st.substream.ssch[ch];
                for sfb in 0..max_sfb {
                    ssch.sect_sfb_offset[g as usize][sfb as usize] =
                        group_offset + sfb_offset[sfb as usize] as i32 * nwig;
                }
                group_offset += sfb_offset[max_sfb as usize] as i32 * nwig;
                ssch.sect_sfb_offset[g as usize][max_sfb as usize] = group_offset;
                for sfb in 0..max_sfb {
                    let s = ssch.sect_sfb_offset[g as usize][sfb as usize];
                    let e = ssch.sect_sfb_offset[g as usize][sfb as usize + 1];
                    for j in s..e {
                        if j as usize >= ssch.offset2g.len() {
                            return Err(invalid("offset2g overflow"));
                        }
                        ssch.offset2sfb[j as usize] = sfb as i16;
                        ssch.offset2g[j as usize] = g as u8;
                    }
                }

                for w in 0..nwig {
                    ssch.win_offset[(win + w) as usize] = win_offset;
                    win_offset += transf_length_g;
                }
                win += nwig;
            }
        }

        Ok(())
    }

    fn asf_psy_info(
        &mut self,
        gb: &mut BitReader,
        ch: usize,
        dual_maxsfb: bool,
        side_limited: bool,
    ) -> Result<()> {
        let mut n_side_bits = Self::get_side_bits(self.st.substream.ssch[ch].scp.transf_length[0]);
        let mut n_msfb_bits = Self::get_msfb_bits(self.st.substream.ssch[ch].scp.transf_length[0]);
        let n_grp_bits = self.get_grp_bits(ch)?;

        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.scp.different_framing = 0;
            if self.st.frame_len_base >= 1536
                && ssch.scp.long_frame == 0
                && ssch.scp.transf_length_idx[0] != ssch.scp.transf_length_idx[1]
            {
                ssch.scp.different_framing = 1;
            }
        }

        if side_limited {
            self.st.substream.ssch[ch].scp.max_sfb_side[0] = gb.get_bits(n_side_bits) as u8;
        } else {
            self.st.substream.ssch[ch].scp.max_sfb[0] = gb.get_bits(n_msfb_bits) as u8;
            if dual_maxsfb {
                self.st.substream.ssch[ch].scp.max_sfb_side[0] = gb.get_bits(n_msfb_bits) as u8;
            }
        }

        if self.st.substream.ssch[ch].scp.different_framing != 0 {
            let tl1 = self.st.substream.ssch[ch].scp.transf_length[1];
            n_side_bits = Self::get_side_bits(tl1);
            n_msfb_bits = Self::get_msfb_bits(tl1);

            if side_limited {
                self.st.substream.ssch[ch].scp.max_sfb_side[1] = gb.get_bits(n_side_bits) as u8;
            } else {
                self.st.substream.ssch[ch].scp.max_sfb[1] = gb.get_bits(n_msfb_bits) as u8;
                if dual_maxsfb {
                    self.st.substream.ssch[ch].scp.max_sfb_side[1] = gb.get_bits(n_msfb_bits) as u8;
                }
            }
        }

        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.scp.scale_factor_grouping = [0; 18];
            for i in 0..n_grp_bits {
                ssch.scp.scale_factor_grouping[i as usize] = gb.get_bits1() as u8;
            }
        }

        self.asf_psy_elements(ch, n_grp_bits)
    }

    fn sf_info(
        &mut self,
        gb: &mut BitReader,
        ch_id: usize,
        spec_frontend: i32,
        dual_maxsfb: bool,
        side_limited: bool,
    ) -> Result<()> {
        self.st.substream.ssch[ch_id].scp.dual_maxsfb = dual_maxsfb as u8;
        self.st.substream.ssch[ch_id].scp.side_limited = side_limited as u8;

        if spec_frontend == enums::SF_ASF {
            self.asf_transform_info(gb, ch_id)?;
            self.asf_psy_info(gb, ch_id, dual_maxsfb, side_limited)?;
        }

        Ok(())
    }

    fn sap_data(&mut self, gb: &mut BitReader, ch: usize) -> Result<()> {
        let flb = self.st.frame_len_base;

        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.sap_coeff_used = [[0; 128]; 16];
            ssch.dpcm_alpha_q = [[0; 128]; 16];
        }

        let num_window_groups = self.st.substream.ssch[ch].scp.num_window_groups as i32;
        if gb.get_bits1() == 0 {
            for g in 0..num_window_groups {
                let max_sfb_g = get_max_sfb_(flb, &self.st.substream.ssch[ch], g);

                let mut sfb = 0;
                while sfb < max_sfb_g {
                    let v = gb.get_bits1() as u8;
                    let ssch = &mut self.st.substream.ssch[ch];
                    ssch.sap_coeff_used[g as usize][sfb as usize] = v;
                    if sfb + 1 < max_sfb_g {
                        ssch.sap_coeff_used[g as usize][sfb as usize + 1] = v;
                    }
                    sfb += 2;
                }
            }
        } else {
            for g in 0..num_window_groups {
                let max_sfb_g = get_max_sfb_(flb, &self.st.substream.ssch[ch], g);
                for sfb in 0..max_sfb_g {
                    self.st.substream.ssch[ch].sap_coeff_used[g as usize][sfb as usize] = 1;
                }
            }
        }

        self.st.substream.ssch[ch].delta_code_time = 0;
        if self.st.substream.ssch[ch].scp.num_window_groups != 1 {
            self.st.substream.ssch[ch].delta_code_time = gb.get_bits1() as i32;
        }

        for g in 0..num_window_groups {
            let max_sfb_g = get_max_sfb_(flb, &self.st.substream.ssch[ch], g);

            let mut sfb = 0;
            while sfb < max_sfb_g {
                if self.st.substream.ssch[ch].sap_coeff_used[g as usize][sfb as usize] != 0 {
                    let v = self
                        .tables
                        .vlcs
                        .scale_factors
                        .decode(gb)
                        .map_err(|_| invalid("invalid scale factor"))?;
                    self.st.substream.ssch[ch].dpcm_alpha_q[g as usize][sfb as usize] = v as u8;
                }
                sfb += 2;
            }
        }

        Ok(())
    }

    fn ssf_st_data(&mut self, gb: &mut BitReader, ch: usize, iframe: i32) -> Result<()> {
        let ssch = &mut self.st.substream.ssch[ch];
        ssch.env_idx[0] = gb.get_bits(5) as i32;
        if iframe == 1 && ssch.stride_flag == enums::SHORT_STRIDE {
            ssch.env_idx[1] = gb.get_bits(5) as i32;
        }

        if ssch.stride_flag == enums::SHORT_STRIDE {
            for block in 0..4 {
                ssch.gain_bits[block] = gb.get_bits(4) as i32;
            }
        }

        let num_blocks = if ssch.stride_flag == enums::SHORT_STRIDE {
            4
        } else {
            1
        };

        for block in 0..num_blocks {
            if block >= ssch.start_block
                && block < ssch.end_block
                && ssch.predictor_presence[block as usize] != 0
            {
                if ssch.delta[block as usize] != 0 {
                    ssch.predictor_lag_delta[block as usize] = gb.get_bits(4) as i32;
                } else {
                    ssch.predictor_lag[block as usize] = gb.get_bits(9) as i32;
                }
            }
            ssch.variance_preserving[block as usize] = gb.get_bits1() as i32;
            ssch.alloc_offset[block as usize] = gb.get_bits(5) as i32;
        }

        Ok(())
    }

    fn ac_init(&mut self, gb: &mut BitReader, ch: usize) -> Result<()> {
        let acs = &mut self.st.substream.ssch[ch].acs;
        acs.ui_model_bits = SSF_MODEL_BITS;
        acs.ui_model_unit = SSF_MODEL_UNIT;
        acs.ui_range_bits = SSF_RANGE_BITS;
        acs.ui_threshold_large = SSF_THRESHOLD_LARGE;
        acs.ui_threshold_small = SSF_THRESHOLD_SMALL;

        acs.ui_low = 0;
        acs.ui_range = SSF_THRESHOLD_LARGE;

        acs.ui_offset = gb.get_bits1();
        for _index in 1..acs.ui_range_bits {
            let ui_tmp = gb.get_bits1();
            acs.ui_offset <<= 1;
            acs.ui_offset += ui_tmp;
        }

        acs.ui_offset2 = acs.ui_offset;

        Ok(())
    }

    fn ac_decode(&mut self, gb: &mut BitReader, ch: usize, cdf_low: u32, cdf_high: u32) {
        let acs = &mut self.st.substream.ssch[ch].acs;
        let ui_range = acs.ui_range >> acs.ui_model_bits;
        let ui_tmp1 = ui_range.wrapping_mul(cdf_low);
        acs.ui_offset = acs.ui_offset.wrapping_sub(ui_tmp1);

        if cdf_high < acs.ui_model_unit {
            let ui_tmp2 = cdf_high.wrapping_sub(cdf_low);
            acs.ui_range = ui_range.wrapping_mul(ui_tmp2);
        } else {
            acs.ui_range = acs.ui_range.wrapping_sub(ui_tmp1);
        }

        // denormalize (wrapping: C arithmetic is plain unsigned; corrupt
        // streams can normalize until values wrap)
        while acs.ui_range <= acs.ui_threshold_small {
            let bit = gb.get_bits1();
            acs.ui_range = acs.ui_range.wrapping_shl(1);
            acs.ui_offset = acs.ui_offset.wrapping_shl(1);
            acs.ui_offset = acs.ui_offset.wrapping_add(bit);
            acs.ui_offset2 = acs.ui_offset2.wrapping_shl(1);
            if acs.ui_offset & 1 != 0 {
                acs.ui_offset2 = acs.ui_offset2.wrapping_add(1);
            }
        }
    }

    fn ac_decode_finish(&mut self, ch: usize) {
        let acs = &mut self.st.substream.ssch[ch].acs;

        // all wrapping: this runs on arbitrary corrupt data; C uses plain
        // unsigned wrap semantics throughout
        acs.ui_low = acs.ui_offset & (acs.ui_threshold_large - 1);

        let mut ui_tmp1 = acs.ui_threshold_large.wrapping_sub(acs.ui_offset);
        acs.ui_low = acs.ui_low.wrapping_add(ui_tmp1);

        for bit_idx in 1..=acs.ui_range_bits {
            let ui_rev_idx = acs.ui_range_bits - bit_idx;
            let fact = (1u32 << ui_rev_idx).wrapping_sub(1);
            ui_tmp1 = acs.ui_low.wrapping_add(fact);
            let ui_bits = ui_tmp1 >> ui_rev_idx;
            let ui_val = ui_bits << ui_rev_idx;
            ui_tmp1 = ui_val.wrapping_add(fact);
            let ui_tmp2 = acs.ui_range.wrapping_sub(1).wrapping_add(acs.ui_low);

            if acs.ui_low <= ui_val && ui_tmp1 <= ui_tmp2 {
                break;
            }
        }
    }

    fn ssf_ac_data(&mut self, gb: &mut BitReader, ch: usize) -> Result<()> {
        self.ac_init(gb, ch)?;

        // Not sure if passing in ui_low and ui_range are the right values
        // for the cdf_low and cdf_high parameters - but it seems to work.
        let (low, range) = {
            let acs = &self.st.substream.ssch[ch].acs;
            (acs.ui_low, acs.ui_range)
        };
        self.ac_decode(gb, ch, low, range);

        self.ac_decode_finish(ch);
        Ok(())
    }

    fn ssf_granule(&mut self, gb: &mut BitReader, ch: usize, iframe: i32) -> Result<()> {
        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.stride_flag = gb.get_bits1() as i32;
            if iframe != 0 {
                ssch.num_bands = gb.get_bits(3) as i32 + 12;
            }

            ssch.start_block = 0;
            ssch.end_block = 0;
            if ssch.stride_flag == enums::LONG_STRIDE && iframe == 0 {
                ssch.end_block = 1;
            }

            if ssch.stride_flag == enums::SHORT_STRIDE {
                ssch.end_block = 4;
                if iframe != 0 {
                    ssch.start_block = 1;
                }
            }

            for block in ssch.start_block..ssch.end_block {
                ssch.predictor_presence[block as usize] = gb.get_bits1() as i32;
                if ssch.predictor_presence[block as usize] != 0 {
                    if ssch.start_block == 1 && block == 1 {
                        ssch.delta[block as usize] = 0;
                    } else {
                        ssch.delta[block as usize] = gb.get_bits1() as i32;
                    }
                }
            }
        }

        self.ssf_st_data(gb, ch, iframe)?;
        self.ssf_ac_data(gb, ch)
    }

    fn ssf_data(&mut self, gb: &mut BitReader, ch: usize, iframe: i32) -> Result<()> {
        let ssf_iframe = if iframe != 0 {
            1
        } else {
            gb.get_bits1() as i32
        };

        self.ssf_granule(gb, ch, ssf_iframe)?;
        if self.st.frame_len_base >= 1536 {
            self.ssf_granule(gb, ch, 0)?;
        }

        Ok(())
    }

    fn asf_section_data(&mut self, gb: &mut BitReader, ch: usize) -> Result<()> {
        let flb = self.st.frame_len_base;
        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.sect_cb = [[0; 128]; 16];
            ssch.sfb_cb = [[0; 128]; 16];
            ssch.sect_start = [[0; 128]; 16];
            ssch.sect_end = [[0; 128]; 16];
            ssch.num_sec_lsf = [0; 16];
            ssch.num_sec = [0; 16];
        }

        let num_window_groups = self.st.substream.ssch[ch].scp.num_window_groups as i32;
        for g in 0..num_window_groups {
            let (transf_length_g, gidx) = get_transf_length_(flb, &self.st.substream.ssch[ch], g);
            let (sect_esc_val, n_sect_bits) = if gidx <= 2 {
                ((1 << 3) - 1, 3)
            } else {
                ((1 << 5) - 1, 5)
            };
            let mut k = 0i32;
            let mut i = 0i32;
            self.st.substream.ssch[ch].num_sec_lsf[g as usize] = 0;
            let max_sfb = get_max_sfb_(flb, &self.st.substream.ssch[ch], g);
            while k < max_sfb {
                let cb_val = gb.get_bits(4) as i32;
                if cb_val > 11 {
                    return Err(invalid("sect_cb > 11"));
                }
                let mut sect_len = 1i32;
                let mut sect_len_incr = gb.get_bits(n_sect_bits) as i32;
                while sect_len_incr == sect_esc_val {
                    sect_len += sect_esc_val;
                    sect_len_incr = gb.get_bits(n_sect_bits) as i32;
                }

                sect_len += sect_len_incr;
                {
                    let ssch = &mut self.st.substream.ssch[ch];
                    ssch.sect_cb[g as usize][i as usize] = cb_val as u8;
                    ssch.sect_start[g as usize][i as usize] = k;
                    ssch.sect_end[g as usize][i as usize] = k + sect_len;
                }

                let ns48 = num_sfb_48(transf_length_g);
                let (start_i, end_i) = {
                    let ssch = &self.st.substream.ssch[ch];
                    (
                        ssch.sect_start[g as usize][i as usize],
                        ssch.sect_end[g as usize][i as usize],
                    )
                };
                if start_i < ns48 && end_i >= ns48 {
                    let ssch = &mut self.st.substream.ssch[ch];
                    ssch.num_sec_lsf[g as usize] = i + 1;
                    if ssch.sect_end[g as usize][i as usize] > ns48 {
                        ssch.sect_end[g as usize][i as usize] = ns48;
                        i += 1;
                        ssch.sect_start[g as usize][i as usize] = ns48;
                        ssch.sect_end[g as usize][i as usize] = k + sect_len;
                        ssch.sect_cb[g as usize][i as usize] =
                            ssch.sect_cb[g as usize][i as usize - 1];
                    }
                }

                if k + sect_len >= 128 {
                    return Err(invalid("k + sect_len overflow"));
                }

                {
                    let ssch = &mut self.st.substream.ssch[ch];
                    for sfb in k..k + sect_len {
                        ssch.sfb_cb[g as usize][sfb as usize] =
                            ssch.sect_cb[g as usize][i as usize];
                    }
                }
                k += sect_len;
                i += 1;
            }

            self.st.substream.ssch[ch].num_sec[g as usize] = i;
            if self.st.substream.ssch[ch].num_sec_lsf[g as usize] == 0 {
                self.st.substream.ssch[ch].num_sec_lsf[g as usize] =
                    self.st.substream.ssch[ch].num_sec[g as usize];
            }
        }

        Ok(())
    }

    fn asf_spectral_data(&mut self, gb: &mut BitReader, ch: usize) -> Result<()> {
        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.max_quant_idx = [[0; 128]; 16];
            ssch.quant_spec = [0; 8192];
        }

        let num_window_groups = self.st.substream.ssch[ch].scp.num_window_groups as i32;
        for g in 0..num_window_groups {
            let num_sec_lsf = self.st.substream.ssch[ch].num_sec_lsf[g as usize];
            for i in 0..num_sec_lsf {
                let sect_cb = self.st.substream.ssch[ch].sect_cb[g as usize][i as usize];
                if sect_cb == 0 || sect_cb > 11 {
                    continue;
                }

                let sect_start_line = self.st.substream.ssch[ch].sect_sfb_offset[g as usize]
                    [self.st.substream.ssch[ch].sect_start[g as usize][i as usize] as usize];
                let sect_end_line = self.st.substream.ssch[ch].sect_sfb_offset[g as usize]
                    [self.st.substream.ssch[ch].sect_end[g as usize][i as usize] as usize];
                let cb = sect_cb as usize - 1;

                // Per-section constants; `vlcs` (shared) and `ssch` (mutable)
                // live in disjoint fields of `self`, so both borrows coexist
                // for the whole loop.
                let cb_off = ASF_CODEBOOK_OFF[cb] as i32;
                let cb_mod = ASF_CODEBOOK_MOD[cb] as i32;
                let dim4 = ASF_CODEBOOK_DIM[cb] == 4;
                let unsigned = ASF_CODEBOOK_UNSIGNED[cb] != 0;
                let sect_cb11 = sect_cb == 11;
                let vlc = &self.tables.vlcs.asf_codebook[cb];
                let ssch = &mut self.st.substream.ssch[ch];
                let y = g as usize;

                let mut k = sect_start_line as usize;
                let end = sect_end_line as usize;
                while k < end {
                    let mut cb_idx = vlc
                        .decode(gb)
                        .map_err(|_| invalid("invalid asf codebook"))?;

                    if dim4 {
                        let cb_mod2 = 9i32;
                        let cb_mod3 = 27i32;

                        ssch.quant_spec[k] = (cb_idx / cb_mod3 - cb_off) as i16;
                        cb_idx -= (ssch.quant_spec[k] as i32 + cb_off) * cb_mod3;
                        ssch.quant_spec[k + 1] = (cb_idx / cb_mod2 - cb_off) as i16;
                        cb_idx -= (ssch.quant_spec[k + 1] as i32 + cb_off) * cb_mod2;
                        ssch.quant_spec[k + 2] = (cb_idx / cb_mod - cb_off) as i16;
                        cb_idx -= (ssch.quant_spec[k + 2] as i32 + cb_off) * cb_mod;
                        ssch.quant_spec[k + 3] = (cb_idx - cb_off) as i16;

                        if unsigned {
                            for l in 0..4 {
                                if ssch.quant_spec[k + l] != 0 && gb.get_bits1() != 0 {
                                    ssch.quant_spec[k + l] = -ssch.quant_spec[k + l];
                                }
                            }
                        }
                        for l in 0..4 {
                            let x = ssch.offset2sfb[k + l] as usize;
                            let v = (ssch.quant_spec[k + l] as i32).abs();
                            if ssch.max_quant_idx[y][x] < v {
                                ssch.max_quant_idx[y][x] = v;
                            }
                        }
                        k += 4;
                    } else {
                        /* asf_codebook_dim == 2 */
                        let mut sign0 = false;
                        let mut sign1 = false;

                        ssch.quant_spec[k] = (cb_idx / cb_mod - cb_off) as i16;
                        cb_idx -= (ssch.quant_spec[k] as i32 + cb_off) * cb_mod;
                        ssch.quant_spec[k + 1] = (cb_idx - cb_off) as i16;

                        if unsigned {
                            if ssch.quant_spec[k] != 0 && gb.get_bits1() != 0 {
                                sign0 = true;
                            }
                            if ssch.quant_spec[k + 1] != 0 && gb.get_bits1() != 0 {
                                sign1 = true;
                            }
                        }

                        if sect_cb11 {
                            if ssch.quant_spec[k] == 16 {
                                let ext = ext_decode(gb);
                                ssch.quant_spec[k] = ext as i16;
                            }
                            if ssch.quant_spec[k + 1] == 16 {
                                let ext = ext_decode(gb);
                                ssch.quant_spec[k + 1] = ext as i16;
                            }
                        }

                        if sign0 {
                            ssch.quant_spec[k] = -ssch.quant_spec[k];
                        }
                        if sign1 {
                            ssch.quant_spec[k + 1] = -ssch.quant_spec[k + 1];
                        }

                        for l in 0..2 {
                            let x = ssch.offset2sfb[k + l] as usize;
                            let v = (ssch.quant_spec[k + l] as i32).abs();
                            if ssch.max_quant_idx[y][x] < v {
                                ssch.max_quant_idx[y][x] = v;
                            }
                        }
                        k += 2;
                    }
                }
            }
        }

        Ok(())
    }

    fn asf_scalefac_data(&mut self, gb: &mut BitReader, ch: usize) -> Result<()> {
        let flb = self.st.frame_len_base;
        let mut first_scf_found = false;
        let mut scale_factor = gb.get_bits(8) as i32;

        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.sf_gain = [[0.0; 128]; 16];
        }

        let vlc = &self.tables.vlcs.scale_factors;
        let ssch = &mut self.st.substream.ssch[ch];
        let num_window_groups = ssch.scp.num_window_groups as i32;
        for g in 0..num_window_groups {
            let (tl, _) = get_transf_length_(flb, ssch, g);
            let max_sfb = get_max_sfb_(flb, ssch, g).min(num_sfb_48(tl));

            for sfb in 0..max_sfb {
                if ssch.sfb_cb[g as usize][sfb as usize] != 0
                    && ssch.max_quant_idx[g as usize][sfb as usize] > 0
                {
                    if first_scf_found {
                        let v = vlc
                            .decode(gb)
                            .map_err(|_| invalid("invalid scale factor"))?;
                        ssch.dpcm_sf[g as usize][sfb as usize] = v;
                        scale_factor += v - 60;
                    } else {
                        first_scf_found = true;
                    }

                    if !(0..=255).contains(&scale_factor) {
                        return Err(invalid("scale factor out of range"));
                    }
                    ssch.sf_gain[g as usize][sfb as usize] =
                        (2.0f32).powf((scale_factor - 100) as f32 / 4.0);
                }
            }
        }

        Ok(())
    }

    fn asf_snf_data(&mut self, gb: &mut BitReader, ch: usize) -> Result<()> {
        let flb = self.st.frame_len_base;
        let vlc = &self.tables.vlcs.snf;
        let ssch = &mut self.st.substream.ssch[ch];
        ssch.snf_data_exists = gb.get_bits1() as i32;
        if ssch.snf_data_exists != 0 {
            let num_window_groups = ssch.scp.num_window_groups as i32;
            for g in 0..num_window_groups {
                let (tl, _) = get_transf_length_(flb, ssch, g);
                let max_sfb = get_max_sfb_(flb, ssch, g).min(num_sfb_48(tl));

                for sfb in 0..max_sfb {
                    if ssch.sfb_cb[g as usize][sfb as usize] == 0
                        || ssch.max_quant_idx[g as usize][sfb as usize] == 0
                    {
                        let v = vlc.decode(gb).map_err(|_| invalid("invalid snf"))?;
                        ssch.dpcm_snf[g as usize][sfb as usize] = v - 17;
                    }
                }
            }
        }

        Ok(())
    }

    fn sf_data(
        &mut self,
        gb: &mut BitReader,
        ch_id: usize,
        iframe: i32,
        spec_frontend: i32,
    ) -> Result<()> {
        if spec_frontend == enums::SF_ASF {
            self.asf_section_data(gb, ch_id)?;
            self.asf_spectral_data(gb, ch_id)?;
            self.asf_scalefac_data(gb, ch_id)?;
            self.asf_snf_data(gb, ch_id)
        } else {
            self.ssf_data(gb, ch_id, iframe)
        }
    }

    fn chparam_info(&mut self, gb: &mut BitReader, ch_id: usize) -> Result<()> {
        let flb = self.st.frame_len_base;
        self.st.substream.ssch[ch_id].sap_mode = gb.get_bits(2) as i32;

        if self.st.substream.ssch[ch_id].sap_mode == 1 {
            let num_window_groups = self.st.substream.ssch[ch_id].scp.num_window_groups as i32;
            for g in 0..num_window_groups {
                let max_sfb_g = get_max_sfb_(flb, &self.st.substream.ssch[ch_id], g);

                for sfb in 0..max_sfb_g {
                    self.st.substream.ssch[ch_id].ms_used[g as usize][sfb as usize] =
                        gb.get_bits1() as u8;
                }
            }
        }

        if self.st.substream.ssch[ch_id].sap_mode == 3 {
            self.sap_data(gb, ch_id)?;
        }

        Ok(())
    }

    fn stereo_data(&mut self, gb: &mut BitReader, iframe: i32) -> Result<()> {
        self.st.substream.mdct_stereo_proc[0] = gb.get_bits1() as u8;
        if self.st.substream.mdct_stereo_proc[0] != 0 {
            self.st.substream.spec_frontend_l = enums::SF_ASF;
            self.st.substream.spec_frontend_r = enums::SF_ASF;
            self.sf_info(gb, 0, enums::SF_ASF, false, false)?;

            {
                let (scp, sect_sfb_offset, offset2sfb, offset2g, win_offset) = {
                    let ssch0 = &self.st.substream.ssch[0];
                    (
                        ssch0.scp.clone(),
                        ssch0.sect_sfb_offset,
                        ssch0.offset2sfb,
                        ssch0.offset2g,
                        ssch0.win_offset,
                    )
                };
                let ssch1 = &mut self.st.substream.ssch[1];
                ssch1.scp = scp;
                ssch1.sect_sfb_offset = sect_sfb_offset;
                ssch1.offset2sfb = offset2sfb;
                ssch1.offset2g = offset2g;
                ssch1.win_offset = win_offset;
            }

            self.chparam_info(gb, 0)?;
        } else {
            let sfl = gb.get_bits1() as i32;
            self.st.substream.spec_frontend_l = sfl;
            self.sf_info(gb, 0, sfl, false, false)?;
            let sfr = gb.get_bits1() as i32;
            self.st.substream.spec_frontend_r = sfr;
            self.sf_info(gb, 1, sfr, false, false)?;
        }

        let sfl = self.st.substream.spec_frontend_l;
        self.sf_data(gb, 0, iframe, sfl)?;
        let sfr = self.st.substream.spec_frontend_r;
        self.sf_data(gb, 1, iframe, sfr)?;

        Ok(())
    }

    fn companding_control(&mut self, gb: &mut BitReader, num_chan: i32) -> Result<()> {
        let mut need_avg = false;

        self.st.substream.sync_flag = 0;
        if num_chan > 1 {
            self.st.substream.sync_flag = gb.get_bits1() as u8;
        }

        let nc = if self.st.substream.sync_flag != 0 {
            1
        } else {
            num_chan
        };

        for i in 0..nc as usize {
            self.st.substream.compand_on[i] = gb.get_bits1() as u8;
            if self.st.substream.compand_on[i] == 0 {
                need_avg = true;
            }
        }

        if need_avg {
            self.st.substream.compand_avg = gb.get_bits1() as u8;
        }

        Ok(())
    }

    // ------------------------------------------------------------------
    // A-SPX framing / envelopes (C lines 2963-3400)

    fn noise_mid_border(aspx_tsg_ptr: i32, aspx_int_class: i32, num_atsg_sig: i32) -> i32 {
        if aspx_tsg_ptr == -1 {
            if aspx_int_class == enums::VARFIX {
                1
            } else if aspx_int_class != enums::FIXFIX {
                num_atsg_sig - 1
            } else {
                panic!("noise_mid_border: invalid int class")
            }
        } else if aspx_tsg_ptr >= 0 {
            if aspx_int_class == enums::VARFIX {
                num_atsg_sig - 1
            } else if aspx_int_class != enums::FIXFIX {
                1.max((num_atsg_sig - 1).min(aspx_tsg_ptr))
            } else {
                panic!("noise_mid_border: invalid int class")
            }
        } else {
            panic!("noise_mid_border: invalid tsg ptr")
        }
    }

    fn freq_res(
        atsg_sig: &[u8],
        atsg: i32,
        aspx_tsg_ptr: i32,
        num_aspx_timeslots: i32,
        aspx_freq_res_mode: i32,
        aspx_freq_res: &[u8],
    ) -> i32 {
        match aspx_freq_res_mode {
            0 => aspx_freq_res[atsg as usize] as i32,
            1 => 0,
            2 => {
                if (atsg < aspx_tsg_ptr && num_aspx_timeslots > 8)
                    || (atsg_sig[atsg as usize + 1] as i32 - atsg_sig[atsg as usize] as i32) as f32
                        > (num_aspx_timeslots as f32 / 6.0 + 3.25)
                {
                    1
                } else {
                    0
                }
            }
            3 => 1,
            _ => panic!("freq_res: invalid mode"),
        }
    }

    fn get_tab_border(atsg_sig: &mut [u8], num_aspx_timeslots: i32, num_atsg: i32) {
        let row = match num_aspx_timeslots {
            6 => &TAB_BORDER[0],
            8 => &TAB_BORDER[1],
            12 => &TAB_BORDER[2],
            15 => &TAB_BORDER[3],
            16 => &TAB_BORDER[4],
            _ => panic!("get_tab_border: invalid num_aspx_timeslots"),
        };
        atsg_sig[..5].copy_from_slice(&row[(num_atsg >> 1) as usize]);
    }

    fn aspx_atsg(&mut self, ch: usize, iframe: i32) -> Result<()> {
        let _ = iframe;
        let num_aspx_timeslots = self.st.num_aspx_timeslots;
        let freq_res_mode = self.st.substream.aspx_freq_res_mode;

        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.atsg_freqres = [0; MAX_ASPX_SIGNAL];
            ssch.atsg_sig = [0; MAX_ASPX_SIGNAL + 1];
        }

        let num_atsg_sig;
        let num_atsg_noise;
        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.num_atsg_sig_prev = ssch.num_atsg_sig;
            ssch.num_atsg_noise_prev = ssch.num_atsg_noise;

            num_atsg_sig = ssch.aspx_num_env;
            ssch.num_atsg_sig = num_atsg_sig;
            num_atsg_noise = ssch.aspx_num_noise;
            ssch.num_atsg_noise = num_atsg_noise;
            if ssch.num_atsg_sig_prev == 0 {
                ssch.num_atsg_sig_prev = ssch.num_atsg_sig;
            }

            if ssch.previous_stop_pos == 0 {
                ssch.previous_stop_pos = num_aspx_timeslots;
            }
        }

        let int_class = self.st.substream.ssch[ch].aspx_int_class;
        if int_class == enums::FIXFIX {
            {
                let ssch = &mut self.st.substream.ssch[ch];
                Self::get_tab_border(&mut ssch.atsg_sig, num_aspx_timeslots, num_atsg_sig);
                Self::get_tab_border(&mut ssch.atsg_noise, num_aspx_timeslots, num_atsg_noise);
                ssch.atsg_freqres[0] = Self::freq_res(
                    &ssch.atsg_sig,
                    0,
                    0,
                    num_aspx_timeslots,
                    freq_res_mode,
                    &ssch.aspx_freq_res,
                ) as u8;
                let fr0 = ssch.atsg_freqres[0];
                for atsg in 1..num_atsg_sig {
                    ssch.atsg_freqres[atsg as usize] = fr0;
                }
            }
        } else {
            {
                let ssch = &mut self.st.substream.ssch[ch];
                match int_class {
                    c if c == enums::FIXVAR => {
                        ssch.atsg_sig[0] = 0;
                        ssch.atsg_sig[num_atsg_sig as usize] =
                            (ssch.aspx_var_bord_right + num_aspx_timeslots) as u8;
                        for tsg in 0..ssch.aspx_num_rel_right {
                            // i32 math then truncate: matches C's uint8_t
                            // assignment of an int expression (wraps)
                            ssch.atsg_sig[(num_atsg_sig - tsg - 1) as usize] =
                                (ssch.atsg_sig[(num_atsg_sig - tsg) as usize] as i32
                                    - ssch.aspx_rel_bord_right[tsg as usize])
                                    as u8;
                        }
                    }
                    c if c == enums::VARFIX => {
                        if iframe != 0 {
                            ssch.atsg_sig[0] = ssch.aspx_var_bord_left as u8;
                        } else {
                            ssch.atsg_sig[0] = (ssch.previous_stop_pos - num_aspx_timeslots) as u8;
                        }
                        ssch.atsg_sig[num_atsg_sig as usize] = num_aspx_timeslots as u8;
                        for tsg in 0..ssch.aspx_num_rel_left {
                            ssch.atsg_sig[(tsg + 1) as usize] = (ssch.atsg_sig[tsg as usize] as i32
                                + ssch.aspx_rel_bord_left[tsg as usize])
                                as u8;
                        }
                    }
                    c if c == enums::VARVAR => {
                        if iframe != 0 {
                            ssch.atsg_sig[0] = ssch.aspx_var_bord_left as u8;
                        } else {
                            ssch.atsg_sig[0] = (ssch.previous_stop_pos - num_aspx_timeslots) as u8;
                        }
                        ssch.atsg_sig[num_atsg_sig as usize] =
                            (ssch.aspx_var_bord_right + num_aspx_timeslots) as u8;
                        for tsg in 0..ssch.aspx_num_rel_left {
                            ssch.atsg_sig[(tsg + 1) as usize] = (ssch.atsg_sig[tsg as usize] as i32
                                + ssch.aspx_rel_bord_left[tsg as usize])
                                as u8;
                        }
                        for tsg in 0..ssch.aspx_num_rel_right {
                            // i32 math then truncate: matches C's uint8_t
                            // assignment of an int expression (wraps)
                            ssch.atsg_sig[(num_atsg_sig - tsg - 1) as usize] =
                                (ssch.atsg_sig[(num_atsg_sig - tsg) as usize] as i32
                                    - ssch.aspx_rel_bord_right[tsg as usize])
                                    as u8;
                        }
                    }
                    _ => panic!("aspx_atsg: invalid int class"),
                }
            }

            let tsg_ptr = self.st.substream.ssch[ch].aspx_tsg_ptr;
            {
                let ssch = &mut self.st.substream.ssch[ch];
                ssch.atsg_noise[0] = ssch.atsg_sig[0];
                ssch.atsg_noise[num_atsg_noise as usize] = ssch.atsg_sig[num_atsg_sig as usize];
                if num_atsg_noise > 1 {
                    let mid = Self::noise_mid_border(tsg_ptr, int_class, num_atsg_sig);
                    ssch.atsg_noise[1] = ssch.atsg_sig[mid as usize];
                }
                for atsg in 0..num_atsg_sig {
                    ssch.atsg_freqres[atsg as usize] = Self::freq_res(
                        &ssch.atsg_sig,
                        atsg,
                        tsg_ptr,
                        num_aspx_timeslots,
                        freq_res_mode,
                        &ssch.aspx_freq_res,
                    ) as u8;
                }
            }
        }

        self.st.substream.ssch[ch].previous_stop_pos =
            self.st.substream.ssch[ch].atsg_sig[num_atsg_sig as usize] as i32;

        for atsg in 0..num_atsg_sig {
            let ssch = &mut self.st.substream.ssch[ch];
            if ssch.atsg_freqres[atsg as usize] != 0 {
                ssch.num_sbg_sig[atsg as usize] = ssch.num_sbg_sig_highres;
                ssch.sbg_sig[atsg as usize] = ssch.sbg_sig_highres;
            } else {
                ssch.num_sbg_sig[atsg as usize] = ssch.num_sbg_sig_lowres;
                ssch.sbg_sig[atsg as usize] = ssch.sbg_sig_lowres;
            }
        }
        self.st.substream.ssch[ch].atsg_sig[num_atsg_sig as usize] = num_aspx_timeslots
            .min(self.st.substream.ssch[ch].atsg_sig[num_atsg_sig as usize] as i32)
            as u8;

        Ok(())
    }

    fn aspx_framing(&mut self, gb: &mut BitReader, ch: usize, iframe: i32) -> Result<()> {
        let num_aspx_timeslots = self.st.num_aspx_timeslots;
        let num_env_bits_fixfix = self.st.substream.aspx_num_env_bits_fixfix;
        let freq_res_mode = self.st.substream.aspx_freq_res_mode;

        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.aspx_num_rel_left = 0;
            ssch.aspx_num_rel_right = 0;
            ssch.aspx_freq_res = [0; MAX_ASPX_SIGNAL + 1];
        }

        let int_class = self
            .tables
            .vlcs
            .aspx_int_class
            .decode(gb)
            .map_err(|_| invalid("invalid aspx int class"))?;
        self.st.substream.ssch[ch].aspx_int_class = int_class;

        match int_class {
            c if c == enums::FIXFIX => {
                let num_env = 1i32 << gb.get_bits(1 + num_env_bits_fixfix as u32);
                if num_env > 4 {
                    // validate before writing: the error path must not leave
                    // an out-of-range value behind for later frames
                    return Err(invalid("invalid aspx num env in FIXFIX"));
                }
                self.st.substream.ssch[ch].aspx_num_env = num_env;

                if freq_res_mode == 0 {
                    self.st.substream.ssch[ch].aspx_freq_res[0] = gb.get_bits1() as u8;
                }
            }
            c if c == enums::FIXVAR => {
                let ssch = &mut self.st.substream.ssch[ch];
                ssch.aspx_var_bord_right = gb.get_bits(2) as i32;
                ssch.aspx_num_rel_right = gb.get_bits(1 + (num_aspx_timeslots > 8) as u32) as i32;
                for i in 0..ssch.aspx_num_rel_right {
                    ssch.aspx_rel_bord_right[i as usize] =
                        2 * gb.get_bits(1 + (num_aspx_timeslots > 8) as u32) as i32 + 2;
                }
            }
            c if c == enums::VARVAR => {
                let ssch = &mut self.st.substream.ssch[ch];
                if iframe != 0 {
                    ssch.aspx_var_bord_left = gb.get_bits(2) as i32;
                }
                ssch.aspx_num_rel_left = gb.get_bits(1 + (num_aspx_timeslots > 8) as u32) as i32;
                for i in 0..ssch.aspx_num_rel_left {
                    ssch.aspx_rel_bord_left[i as usize] =
                        2 * gb.get_bits(1 + (num_aspx_timeslots > 8) as u32) as i32 + 2;
                }
                ssch.aspx_var_bord_right = gb.get_bits(2) as i32;
                ssch.aspx_num_rel_right = gb.get_bits(1 + (num_aspx_timeslots > 8) as u32) as i32;
                for i in 0..ssch.aspx_num_rel_right {
                    ssch.aspx_rel_bord_right[i as usize] =
                        2 * gb.get_bits(1 + (num_aspx_timeslots > 8) as u32) as i32 + 2;
                }
            }
            c if c == enums::VARFIX => {
                let ssch = &mut self.st.substream.ssch[ch];
                if iframe != 0 {
                    ssch.aspx_var_bord_left = gb.get_bits(2) as i32;
                }
                ssch.aspx_num_rel_left = gb.get_bits(1 + (num_aspx_timeslots > 8) as u32) as i32;
                for i in 0..ssch.aspx_num_rel_left {
                    ssch.aspx_rel_bord_left[i as usize] =
                        2 * gb.get_bits(1 + (num_aspx_timeslots > 8) as u32) as i32 + 2;
                }
            }
            _ => panic!("aspx_framing: invalid int class"),
        }

        if int_class != enums::FIXFIX {
            {
                let ssch = &mut self.st.substream.ssch[ch];
                let num_env = ssch.aspx_num_rel_left + ssch.aspx_num_rel_right + 1;
                if num_env > 5 {
                    // validate before writing (see FIXFIX branch above)
                    return Err(invalid("invalid aspx num env"));
                }
                ssch.aspx_num_env = num_env;
            }

            let num_env = self.st.substream.ssch[ch].aspx_num_env;
            let ptr_bits = ((num_env as f32 + 2.0).ln() / 2.0f32.ln()).ceil() as u32;
            self.st.substream.ssch[ch].aspx_tsg_ptr_prev = self.st.substream.ssch[ch].aspx_tsg_ptr;
            let ptr = gb.get_bits(ptr_bits) as i32 - 1;
            self.st.substream.ssch[ch].aspx_tsg_ptr = ptr;
            if freq_res_mode == 0 {
                for env in 0..num_env {
                    self.st.substream.ssch[ch].aspx_freq_res[env as usize] = gb.get_bits1() as u8;
                }
            }
        }

        if self.st.substream.ssch[ch].aspx_num_env > 1 {
            self.st.substream.ssch[ch].aspx_num_noise = 2;
        } else {
            self.st.substream.ssch[ch].aspx_num_noise = 1;
        }

        self.aspx_atsg(ch, iframe)
    }

    fn aspx_delta_dir(&mut self, gb: &mut BitReader, ch: usize) {
        let num_env = self.st.substream.ssch[ch].aspx_num_env;
        let num_noise = self.st.substream.ssch[ch].aspx_num_noise;
        let ssch = &mut self.st.substream.ssch[ch];
        for env in 0..num_env {
            ssch.aspx_sig_delta_dir[env as usize] = gb.get_bits1() as u8;
        }

        for env in 0..num_noise {
            ssch.aspx_noise_delta_dir[env as usize] = gb.get_bits1() as u8;
        }
    }

    fn aspx_hfgen_iwc_2ch(
        &mut self,
        gb: &mut BitReader,
        ch0: usize,
        ch1: usize,
        aspx_balance: i32,
    ) -> Result<()> {
        let num_aspx_timeslots = self.st.num_aspx_timeslots;
        assert!(ch0 < ch1);
        let ssch = &mut self.st.substream.ssch;
        let (l, r) = ssch.split_at_mut(ch1);
        let ssch0 = &mut l[ch0];
        let ssch1 = &mut r[0];

        ssch0.aspx_tna_mode_prev = ssch0.aspx_tna_mode;
        ssch1.aspx_tna_mode_prev = ssch1.aspx_tna_mode;
        ssch0.aspx_tna_mode = [0; MAX_SBG_NOISE];
        ssch1.aspx_tna_mode = [0; MAX_SBG_NOISE];
        ssch0.aspx_fic_used_in_sfb = [0; MAX_QMF_TSLOTS];
        ssch1.aspx_fic_used_in_sfb = [0; MAX_QMF_TSLOTS];
        ssch0.aspx_tic_used_in_slot = [0; MAX_QMF_TSLOTS];
        ssch1.aspx_tic_used_in_slot = [0; MAX_QMF_TSLOTS];

        let n0 = ssch0.num_sbg_noise;
        for n in 0..n0 {
            ssch0.aspx_tna_mode[n as usize] = gb.get_bits(2) as u8;
        }
        if aspx_balance == 0 {
            for n in 0..n0 {
                ssch1.aspx_tna_mode[n as usize] = gb.get_bits(2) as u8;
            }
        } else {
            for n in 0..n0 {
                ssch1.aspx_tna_mode[n as usize] = ssch0.aspx_tna_mode[n as usize];
            }
        }
        if gb.get_bits1() != 0 {
            for n in 0..ssch0.num_sbg_sig_highres {
                ssch0.aspx_add_harmonic[n as usize] = gb.get_bits1() as u8;
            }
        }
        if gb.get_bits1() != 0 {
            for n in 0..ssch0.num_sbg_sig_highres {
                ssch1.aspx_add_harmonic[n as usize] = gb.get_bits1() as u8;
            }
        }

        if gb.get_bits1() != 0 {
            if gb.get_bits1() != 0 {
                for n in 0..ssch0.num_sbg_sig_highres {
                    ssch0.aspx_fic_used_in_sfb[n as usize] = gb.get_bits1() as u8;
                }
            }

            if gb.get_bits1() != 0 {
                for n in 0..ssch0.num_sbg_sig_highres {
                    ssch1.aspx_fic_used_in_sfb[n as usize] = gb.get_bits1() as u8;
                }
            }
        }

        if gb.get_bits1() != 0 {
            let aspx_tic_copy = gb.get_bits1();
            let mut aspx_tic_left = 0;
            let mut aspx_tic_right = 0;

            if aspx_tic_copy == 0 {
                aspx_tic_left = gb.get_bits1();
                aspx_tic_right = gb.get_bits1();
            }

            if aspx_tic_copy != 0 || aspx_tic_left != 0 {
                for n in 0..num_aspx_timeslots {
                    ssch0.aspx_tic_used_in_slot[n as usize] = gb.get_bits1() as u8;
                }
            }

            if aspx_tic_right != 0 {
                for n in 0..num_aspx_timeslots {
                    ssch1.aspx_tic_used_in_slot[n as usize] = gb.get_bits1() as u8;
                }
            }

            if aspx_tic_copy != 0 {
                for n in 0..num_aspx_timeslots {
                    ssch1.aspx_tic_used_in_slot[n as usize] =
                        ssch0.aspx_tic_used_in_slot[n as usize];
                }
            }
        }

        Ok(())
    }

    fn aspx_huff_data(
        &mut self,
        gb: &mut BitReader,
        data_type: i32,
        num_sbg: i32,
        quant_mode: usize,
        stereo_mode: usize,
        direction: i32,
        data: &mut [i16],
    ) -> Result<()> {
        if direction == 0 {
            // FREQ
            data[0] = self
                .get_aspx_hcb(data_type, quant_mode, stereo_mode, enums::HCB_F0)
                .decode(gb)
                .map_err(|_| invalid("invalid aspx codebook"))? as i16;
            let aspx_off = Self::get_aspx_off(data_type, quant_mode, stereo_mode);
            for i in 1..num_sbg as usize {
                let v = self
                    .get_aspx_hcb(data_type, quant_mode, stereo_mode, enums::HCB_DF)
                    .decode(gb)
                    .map_err(|_| invalid("invalid aspx codebook"))?;
                data[i] = (v - aspx_off) as i16;
            }
        } else {
            // TIME
            let aspx_off = Self::get_aspx_off(data_type, quant_mode, stereo_mode);
            for i in 0..num_sbg as usize {
                let v = self
                    .get_aspx_hcb(data_type, quant_mode, stereo_mode, enums::HCB_DT)
                    .decode(gb)
                    .map_err(|_| invalid("invalid aspx codebook"))?;
                data[i] = (v - aspx_off) as i16;
            }
        }

        Ok(())
    }

    fn get_aspx_hcb(
        &self,
        data_type: i32,
        quant_mode: usize,
        stereo_mode: usize,
        hcb_type: usize,
    ) -> &Vlc {
        if data_type == enums::DT_SIGNAL {
            &self.tables.vlcs.aspx_codebook_signal[stereo_mode][quant_mode][hcb_type]
        } else {
            // NOISE
            &self.tables.vlcs.aspx_codebook_noise[stereo_mode][hcb_type]
        }
    }

    fn get_aspx_off(data_type: i32, quant_mode: usize, stereo_mode: usize) -> i32 {
        if data_type == enums::DT_SIGNAL {
            ASPX_CODEBOOK_SIGNAL_OFF[stereo_mode][quant_mode] as i32
        } else {
            ASPX_CODEBOOK_NOISE_OFF[stereo_mode] as i32
        }
    }

    fn aspx_ec_data(
        &mut self,
        gb: &mut BitReader,
        ch: usize,
        data_type: i32,
        num_env: i32,
        quant_mode: usize,
        stereo_mode: usize,
    ) -> Result<()> {
        for env in 0..num_env {
            let num_sbg = if data_type == enums::DT_SIGNAL {
                if self.st.substream.ssch[ch].atsg_freqres[env as usize] != 0 {
                    self.st.substream.ssch[ch].num_sbg_sig_highres
                } else {
                    self.st.substream.ssch[ch].num_sbg_sig_lowres
                }
            } else {
                self.st.substream.ssch[ch].num_sbg_noise
            };
            let dir = self.st.substream.ssch[ch].aspx_sig_delta_dir[env as usize] as i32;
            if data_type == enums::DT_NOISE {
                // direction array for noise is aspx_noise_delta_dir
                let dir_n = self.st.substream.ssch[ch].aspx_noise_delta_dir[env as usize] as i32;
                let mut data = self.st.substream.ssch[ch].aspx_data[1][env as usize];
                self.aspx_huff_data(
                    gb,
                    data_type,
                    num_sbg,
                    quant_mode,
                    stereo_mode,
                    dir_n,
                    &mut data,
                )?;
                self.st.substream.ssch[ch].aspx_data[1][env as usize] = data;
            } else {
                let mut data = self.st.substream.ssch[ch].aspx_data[0][env as usize];
                self.aspx_huff_data(
                    gb,
                    data_type,
                    num_sbg,
                    quant_mode,
                    stereo_mode,
                    dir,
                    &mut data,
                )?;
                self.st.substream.ssch[ch].aspx_data[0][env as usize] = data;
            }
        }

        Ok(())
    }

    fn is_element_of_sbg_patches(
        sbg_lim_sbg: i32,
        sbg_patches: &[i32; MAX_SBG_NOISE],
        num_sbg_patches: i32,
    ) -> bool {
        // C iterates to num inclusive and reads one past the table when
        // num == MAX_SBG_NOISE (off-by-one); clamp to the table.
        for i in 0..=(num_sbg_patches as usize).min(sbg_patches.len() - 1) {
            if sbg_patches[i] == sbg_lim_sbg {
                return true;
            }
        }
        false
    }

    fn remove_element(sbg_lim: &mut [i32], num_sbg_lim: i32, sbg: i32) {
        for i in sbg as usize..(num_sbg_lim as usize).min(sbg_lim.len() - 1) {
            sbg_lim[i] = sbg_lim[i + 1];
        }
    }

    fn aspx_elements(&mut self, ch: usize, iframe: i32) -> Result<()> {
        self.st.substream.ssch[ch].master_reset = 0;
        if iframe != 0 {
            let ss = &self.st.substream;
            let mr = (self.st.first_frame != 0) as i32
                + (ss.prev_aspx_start_freq != ss.aspx_start_freq) as i32
                + (ss.prev_aspx_stop_freq != ss.aspx_stop_freq) as i32
                + (ss.prev_aspx_master_freq_scale != ss.aspx_master_freq_scale) as i32;
            self.st.substream.ssch[ch].master_reset = (mr != 0) as i32;
        }

        {
            let ssch = &mut self.st.substream.ssch[ch];
            if ssch.master_reset != 0 {
                let (template, base) = if self.st.substream.aspx_master_freq_scale == 1 {
                    (&SBG_TEMPLATE_HIGHRES[..], 22)
                } else {
                    (&SBG_TEMPLATE_LOWRES[..], 20)
                };
                let start_freq = self.st.substream.aspx_start_freq;
                let stop_freq = self.st.substream.aspx_stop_freq;
                ssch.num_sbg_master = base - 2 * start_freq - 2 * stop_freq;
                for sbg in 0..=ssch.num_sbg_master {
                    ssch.sbg_master[sbg as usize] =
                        template[(2 * start_freq + sbg) as usize] as i32;
                }
            }
        }

        let (sba, sbz);
        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.sba = ssch.sbg_master[0];
            ssch.sbz = ssch.sbg_master[ssch.num_sbg_master as usize];
            sba = ssch.sba;
            sbz = ssch.sbz;
        }

        {
            let ssch = &mut self.st.substream.ssch[ch];
            let num_sbg_sig_highres = ssch.num_sbg_master - ssch.aspx_xover_subband_offset;
            if num_sbg_sig_highres < 0 {
                // crossover past the last master group: C would index
                // sbg_sig_highres negatively below (UB). Validate before
                // writing so the error path leaves no dirty state.
                return Err(invalid("invalid aspx crossover"));
            }
            ssch.num_sbg_sig_highres = num_sbg_sig_highres;
            for sbg in 0..=ssch.num_sbg_sig_highres {
                ssch.sbg_sig_highres[sbg as usize] =
                    ssch.sbg_master[(sbg + ssch.aspx_xover_subband_offset) as usize];
            }

            ssch.sbx = ssch.sbg_sig_highres[0];
            if ssch.sbx <= 0 {
                return Err(invalid("invalid sbx"));
            }
            ssch.num_sb_aspx = ssch.sbg_sig_highres[ssch.num_sbg_sig_highres as usize] - ssch.sbx;

            ssch.num_sbg_sig_lowres =
                ssch.num_sbg_sig_highres - (ssch.num_sbg_sig_highres as f32 / 2.0).floor() as i32;

            ssch.sbg_sig_lowres[0] = ssch.sbg_sig_highres[0];
            if (ssch.num_sbg_sig_highres & 1) == 0 {
                for sbg in 1..=ssch.num_sbg_sig_lowres {
                    ssch.sbg_sig_lowres[sbg as usize] = ssch.sbg_sig_highres[2 * sbg as usize];
                }
            } else {
                for sbg in 1..=ssch.num_sbg_sig_lowres {
                    ssch.sbg_sig_lowres[sbg as usize] = ssch.sbg_sig_highres[2 * sbg as usize - 1];
                }
            }

            ssch.num_sbg_sig[0] = ssch.num_sbg_sig_lowres;
            ssch.num_sbg_sig[1] = ssch.num_sbg_sig_highres;
        }

        let sbx = self.st.substream.ssch[ch].sbx;
        let aspx_noise_sbg = self.st.substream.aspx_noise_sbg;
        {
            let ssch = &mut self.st.substream.ssch[ch];
            let num_sbg_noise = 1.max(
                (aspx_noise_sbg as f32 * (sbz as f32 / sbx as f32).log2() + 0.5).floor() as i32,
            );
            if num_sbg_noise > 5 {
                // validate before writing: the error path must not leave an
                // out-of-range group count behind for later frames
                return Err(invalid("invalid num sbg noise"));
            }
            ssch.num_sbg_noise = num_sbg_noise;

            let mut prev_idx = 0;
            ssch.sbg_noise[0] = ssch.sbg_sig_lowres[0];
            // C's loop writes sbg_noise[num] with num == 5, one past the
            // MAX_SBG_NOISE-sized table (off-by-one); clamp to the table.
            for sbg in 1..=ssch.num_sbg_noise.min((ssch.sbg_noise.len() - 1) as i32) {
                let mut idx = prev_idx;

                idx += ((ssch.num_sbg_sig_lowres - prev_idx) as f32
                    / (ssch.num_sbg_noise + 1 - sbg) as f32)
                    .floor() as i32;
                ssch.sbg_noise[sbg as usize] = ssch.sbg_sig_lowres[idx as usize];
                prev_idx = idx;
            }
        }

        let (mut msb, mut usb) = (sba, sbx);
        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.num_sbg_patches = 0;
        }
        let goal_sb = if self.st.fs_index != 0 { 43 } else { 46 };
        let source_band_low = if self.st.substream.aspx_master_freq_scale == 1 {
            4
        } else {
            2
        };

        let num_sb_aspx = self.st.substream.ssch[ch].num_sb_aspx;
        let num_sbg_master = self.st.substream.ssch[ch].num_sbg_master;

        let mut sbg;
        if goal_sb < sbx + num_sb_aspx {
            sbg = 0;
            let ssch = &self.st.substream.ssch[ch];
            let mut i = 0;
            while ssch.sbg_master[i] < goal_sb {
                sbg = i as i32 + 1;
                i += 1;
            }
        } else {
            sbg = num_sbg_master;
        }

        let mut j;
        let mut sb;
        loop {
            j = sbg;
            {
                let ssch = &mut self.st.substream.ssch[ch];
                sb = ssch.sbg_master[j as usize];
            }
            let mut odd = (sb - 2 + sba) % 2;

            while sb > (sba - source_band_low + msb - odd) && j >= 1 {
                j -= 1;
                sb = self.st.substream.ssch[ch].sbg_master[j as usize];
                odd = (sb - 2 + sba) % 2;
            }

            {
                let ssch = &mut self.st.substream.ssch[ch];
                // clamp: corrupt streams can grow the patch count past the
                // MAX_SBG_NOISE-sized tables (C would index [5], one past)
                let pi = (ssch.num_sbg_patches as usize).min(ssch.sbg_patch_num_sb.len() - 1);
                ssch.sbg_patch_num_sb[pi] = (sb - usb).max(0);
                ssch.sbg_patch_start_sb[pi] = sba - odd - (sb - usb).max(0);
                if ssch.sbg_patch_num_sb[pi] > 0 {
                    usb = sb;
                    msb = sb;
                    ssch.num_sbg_patches += 1;
                } else {
                    msb = ssch.sbx;
                }

                let mi = (sbg.min(ssch.sbg_master.len() as i32 - 1)) as usize;
                if ssch.sbg_master[mi] - sb < 3 {
                    sbg = ssch.num_sbg_master;
                }
            }

            if !(sb != sbx + num_sb_aspx && j > 0) {
                break;
            }
        }

        {
            let ssch = &mut self.st.substream.ssch[ch];
            // min(): the patch cursor can exceed the table on corrupt
            // streams before the "too many patches" check below runs
            if ssch.num_sbg_patches > 1
                && ssch.sbg_patch_num_sb
                    [(ssch.num_sbg_patches as usize - 1).min(ssch.sbg_patch_num_sb.len() - 1)]
                    < 3
            {
                ssch.num_sbg_patches -= 1;
            }

            if ssch.num_sbg_patches > 5 {
                return Err(invalid("too many patches"));
            }

            ssch.sbg_patches[0] = ssch.sbx;
            // C's loop writes sbg_patches[num] with num == 5, one past the
            // MAX_SBG_NOISE-sized table (off-by-one); clamp to the table.
            for i in 1..=ssch
                .num_sbg_patches
                .min((ssch.sbg_patches.len() - 1) as i32)
            {
                ssch.sbg_patches[i as usize] =
                    ssch.sbg_patches[i as usize - 1] + ssch.sbg_patch_num_sb[i as usize - 1];
            }

            /* Copy sbg_sig_lowres into lower part of limiter table */
            for sbg_i in 0..=ssch.num_sbg_sig_lowres {
                ssch.sbg_lim[sbg_i as usize] = ssch.sbg_sig_lowres[sbg_i as usize];
            }

            /* Copy patch borders into higher part of limiter table */
            for sbg_i in 1..ssch.num_sbg_patches {
                ssch.sbg_lim[(sbg_i + ssch.num_sbg_sig_lowres) as usize] =
                    ssch.sbg_patches[sbg_i as usize];
            }

            /* Sort patch borders + low res sbg into temporary limiter table */
            ssch.num_sbg_lim = ssch.num_sbg_sig_lowres + ssch.num_sbg_patches - 1;
            let n = ssch.num_sbg_lim.max(0) as usize;
            ssch.sbg_lim[..n].sort_unstable();
        }

        let mut sbg_i = 1;
        loop {
            if sbg_i > self.st.substream.ssch[ch].num_sbg_lim {
                break;
            }
            let (lim_cur, lim_prev) = {
                let ssch = &self.st.substream.ssch[ch];
                (
                    ssch.sbg_lim[sbg_i as usize],
                    ssch.sbg_lim[sbg_i as usize - 1],
                )
            };
            let num_octaves = (lim_cur as f32 / lim_prev as f32).log2();

            if num_octaves < 0.245 {
                if lim_cur == lim_prev {
                    let ssch = &mut self.st.substream.ssch[ch];
                    Self::remove_element(&mut ssch.sbg_lim, ssch.num_sbg_lim, sbg_i);
                    ssch.num_sbg_lim -= 1;
                    continue;
                } else if Self::is_element_of_sbg_patches(
                    lim_cur,
                    &self.st.substream.ssch[ch].sbg_patches,
                    self.st.substream.ssch[ch].num_sbg_patches,
                ) {
                    if Self::is_element_of_sbg_patches(
                        lim_prev,
                        &self.st.substream.ssch[ch].sbg_patches,
                        self.st.substream.ssch[ch].num_sbg_patches,
                    ) {
                        sbg_i += 1;
                        continue;
                    } else {
                        let ssch = &mut self.st.substream.ssch[ch];
                        Self::remove_element(&mut ssch.sbg_lim, ssch.num_sbg_lim, sbg_i - 1);
                        ssch.num_sbg_lim -= 1;
                        continue;
                    }
                } else {
                    let ssch = &mut self.st.substream.ssch[ch];
                    Self::remove_element(&mut ssch.sbg_lim, ssch.num_sbg_lim, sbg_i);
                    ssch.num_sbg_lim -= 1;
                    continue;
                }
            } else {
                sbg_i += 1;
            }
        }

        Ok(())
    }

    fn aspx_data_2ch(
        &mut self,
        gb: &mut BitReader,
        ch0: usize,
        ch1: usize,
        iframe: i32,
    ) -> Result<()> {
        if iframe != 0 {
            let xover = gb.get_bits(3) as i32;
            self.st.substream.ssch[ch0].aspx_xover_subband_offset = xover;
            self.st.substream.ssch[ch1].aspx_xover_subband_offset = xover;
        }

        self.aspx_elements(ch0, iframe)?;
        self.aspx_elements(ch1, iframe)?;

        self.aspx_framing(gb, ch0, iframe)?;

        let qmode_env = self.st.substream.aspx_quant_mode_env;
        self.st.substream.ssch[ch0].aspx_qmode_env = qmode_env;
        self.st.substream.ssch[ch1].aspx_qmode_env = qmode_env;
        if self.st.substream.ssch[ch0].aspx_int_class == enums::FIXFIX
            && self.st.substream.ssch[ch0].aspx_num_env == 1
        {
            self.st.substream.ssch[ch0].aspx_qmode_env = 0;
            self.st.substream.ssch[ch1].aspx_qmode_env = 0;
        }

        let balance = gb.get_bits1() as i32;
        self.st.substream.ssch[ch0].aspx_balance = balance;
        self.st.substream.ssch[ch1].aspx_balance = balance;

        if balance == 0 {
            self.aspx_framing(gb, ch1, iframe)?;
            self.st.substream.ssch[ch1].aspx_qmode_env = self.st.substream.aspx_quant_mode_env;
            if self.st.substream.ssch[ch1].aspx_int_class == enums::FIXFIX
                && self.st.substream.ssch[ch1].aspx_num_env == 1
            {
                self.st.substream.ssch[ch1].aspx_qmode_env = 0;
            }
        } else {
            let (
                sbx,
                num_sb_aspx,
                aspx_num_env,
                aspx_num_noise,
                num_atsg_sig,
                num_atsg_noise,
                sbg_sig,
                atsg_sig,
                num_sbg_sig,
                atsg_freqres,
            ) = {
                let s0 = &self.st.substream.ssch[ch0];
                (
                    s0.sbx,
                    s0.num_sb_aspx,
                    s0.aspx_num_env,
                    s0.aspx_num_noise,
                    s0.num_atsg_sig,
                    s0.num_atsg_noise,
                    s0.sbg_sig,
                    s0.atsg_sig,
                    s0.num_sbg_sig,
                    s0.atsg_freqres,
                )
            };
            let s1 = &mut self.st.substream.ssch[ch1];
            s1.sbx = sbx;
            s1.num_sb_aspx = num_sb_aspx;
            s1.aspx_num_env = aspx_num_env;
            s1.aspx_num_noise = aspx_num_noise;
            s1.num_atsg_sig = num_atsg_sig;
            s1.num_atsg_noise = num_atsg_noise;
            s1.sbg_sig = sbg_sig;
            s1.atsg_sig = atsg_sig;
            s1.num_sbg_sig = num_sbg_sig;
            s1.atsg_freqres = atsg_freqres;
        }

        self.aspx_delta_dir(gb, ch0);
        self.aspx_delta_dir(gb, ch1);
        let balance0 = self.st.substream.ssch[ch0].aspx_balance;
        self.aspx_hfgen_iwc_2ch(gb, ch0, ch1, balance0)?;

        for ch in [ch0, ch1] {
            self.st.substream.ssch[ch].aspx_data = [[[0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL]; 2];
        }

        let num_env0 = self.st.substream.ssch[ch0].aspx_num_env;
        let qmode0 = self.st.substream.ssch[ch0].aspx_qmode_env as usize;
        self.aspx_ec_data(
            gb,
            ch0,
            enums::DT_SIGNAL,
            num_env0,
            qmode0,
            enums::SM_LEVEL as usize,
        )?;
        let num_env1 = self.st.substream.ssch[ch1].aspx_num_env;
        let qmode1 = self.st.substream.ssch[ch1].aspx_qmode_env as usize;
        let stereo_mode1 = if balance0 != 0 {
            enums::SM_BALANCE as usize
        } else {
            enums::SM_LEVEL as usize
        };
        self.aspx_ec_data(gb, ch1, enums::DT_SIGNAL, num_env1, qmode1, stereo_mode1)?;
        let num_noise0 = self.st.substream.ssch[ch0].aspx_num_noise;
        self.aspx_ec_data(
            gb,
            ch0,
            enums::DT_NOISE,
            num_noise0,
            0,
            enums::SM_LEVEL as usize,
        )?;
        let num_noise1 = self.st.substream.ssch[ch1].aspx_num_noise;
        self.aspx_ec_data(gb, ch1, enums::DT_NOISE, num_noise1, 0, stereo_mode1)?;

        Ok(())
    }

    fn aspx_hfgen_iwc_1ch(&mut self, gb: &mut BitReader, ch: usize) -> Result<()> {
        let ssch = &mut self.st.substream.ssch[ch];
        ssch.aspx_tna_mode_prev = ssch.aspx_tna_mode;
        ssch.aspx_tna_mode = [0; MAX_SBG_NOISE];
        ssch.aspx_fic_used_in_sfb = [0; MAX_QMF_TSLOTS];
        ssch.aspx_tic_used_in_slot = [0; MAX_QMF_TSLOTS];

        debug_assert!((ssch.num_sbg_noise as usize) <= MAX_SBG_NOISE);
        for n in 0..ssch.num_sbg_noise as usize {
            ssch.aspx_tna_mode[n] = gb.get_bits(2) as u8;
        }

        let num_sbg_sig_highres = ssch.num_sbg_sig_highres as usize;
        let num_aspx_timeslots = self.st.num_aspx_timeslots as usize;

        if gb.get_bits1() != 0 {
            for n in 0..num_sbg_sig_highres {
                ssch.aspx_add_harmonic[n] = gb.get_bits1() as u8;
            }
        }

        if gb.get_bits1() != 0 {
            for n in 0..num_sbg_sig_highres {
                ssch.aspx_fic_used_in_sfb[n] = gb.get_bits1() as u8;
            }
        }

        if gb.get_bits1() != 0 {
            for n in 0..num_aspx_timeslots {
                ssch.aspx_tic_used_in_slot[n] = gb.get_bits1() as u8;
            }
        }

        Ok(())
    }

    fn aspx_data_1ch(&mut self, gb: &mut BitReader, ch: usize, iframe: i32) -> Result<()> {
        if iframe != 0 {
            self.st.substream.ssch[ch].aspx_xover_subband_offset = gb.get_bits(3) as i32;
        }

        self.st.substream.ssch[ch].aspx_balance = 0;

        self.aspx_elements(ch, iframe)?;

        self.aspx_framing(gb, ch, iframe)?;

        self.st.substream.ssch[ch].aspx_qmode_env = self.st.substream.aspx_quant_mode_env;
        if self.st.substream.ssch[ch].aspx_int_class == enums::FIXFIX
            && self.st.substream.ssch[ch].aspx_num_env == 1
        {
            self.st.substream.ssch[ch].aspx_qmode_env = 0;
        }

        self.aspx_delta_dir(gb, ch);
        self.aspx_hfgen_iwc_1ch(gb, ch)?;

        self.st.substream.ssch[ch].aspx_data = [[[0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL]; 2];

        let num_env = self.st.substream.ssch[ch].aspx_num_env;
        let qmode = self.st.substream.ssch[ch].aspx_qmode_env as usize;
        self.aspx_ec_data(gb, ch, enums::DT_SIGNAL, num_env, qmode, 0)?;
        let num_noise = self.st.substream.ssch[ch].aspx_num_noise;
        self.aspx_ec_data(gb, ch, enums::DT_NOISE, num_noise, 0, 0)?;

        Ok(())
    }

    fn acpl_framing_data(&mut self, gb: &mut BitReader, ch: usize) {
        let ssch = &mut self.st.substream.ssch[ch];
        ssch.acpl_interpolation_type = gb.get_bits1() as i32;
        ssch.acpl_num_param_sets_cod = gb.get_bits1() as i32;
        if ssch.acpl_interpolation_type != 0 {
            for ps in 0..(ssch.acpl_num_param_sets_cod + 1) as usize {
                ssch.acpl_param_timeslot[ps] = gb.get_bits(5) as i32;
            }
        }
    }

    fn get_acpl_hcb(&self, data_type: usize, quant_mode: usize, hcb_type: usize) -> &Vlc {
        &self.tables.vlcs.acpl_codebook[data_type][quant_mode][hcb_type]
    }

    fn get_acpl_off(data_type: usize, quant_mode: usize, hcb_type: usize) -> i32 {
        ACPL_CODEBOOK_SIGNAL_OFF[data_type][quant_mode][hcb_type] as i32
    }

    fn acpl_huff_data(
        &mut self,
        gb: &mut BitReader,
        data_type: i32,
        data_bands: i32,
        start_band: usize,
        quant_mode: usize,
        data: &mut [i32],
    ) -> Result<()> {
        // Map the parameter enum onto the codebook family index.
        let cb_type = match data_type {
            enums::ALPHA1 | enums::ALPHA2 => 0,
            enums::BETA1 | enums::BETA2 => 1,
            enums::BETA3 => 2,
            _ => 3,
        };

        let diff_type = gb.get_bits1();
        if diff_type == 0 {
            // DIFF_FREQ
            let off = Self::get_acpl_off(cb_type, quant_mode, enums::HCB_F0);
            let v = self
                .get_acpl_hcb(cb_type, quant_mode, enums::HCB_F0)
                .decode(gb)
                .map_err(|_| invalid("invalid acpl codebook"))?;
            data[start_band] = v - off;
            let off = Self::get_acpl_off(cb_type, quant_mode, enums::HCB_DF);
            for i in start_band + 1..data_bands as usize {
                let v = self
                    .get_acpl_hcb(cb_type, quant_mode, enums::HCB_DF)
                    .decode(gb)
                    .map_err(|_| invalid("invalid acpl codebook"))?;
                data[i] = v - off;
            }
        } else {
            // DIFF_TIME
            let off = Self::get_acpl_off(cb_type, quant_mode, enums::HCB_DT);
            for i in start_band..data_bands as usize {
                let v = self
                    .get_acpl_hcb(cb_type, quant_mode, enums::HCB_DT)
                    .decode(gb)
                    .map_err(|_| invalid("invalid acpl codebook"))?;
                data[i] = v - off;
            }
        }

        Ok(())
    }

    fn acpl_ec_data(
        &mut self,
        gb: &mut BitReader,
        ch: usize,
        data_type: usize,
        data_bands: i32,
        start_band: usize,
        quant_mode: usize,
    ) -> Result<()> {
        let num_ps = self.st.substream.ssch[ch].acpl_num_param_sets_cod + 1;
        for _ in 0..num_ps {
            let mut data = self.st.substream.ssch[ch].acpl_data[data_type];
            self.acpl_huff_data(
                gb,
                data_type as i32,
                data_bands,
                start_band,
                quant_mode,
                &mut data,
            )?;
            self.st.substream.ssch[ch].acpl_data[data_type] = data;
        }

        Ok(())
    }

    fn acpl_data_2ch(&mut self, gb: &mut BitReader, ch0: usize, ch1: usize) -> Result<()> {
        self.acpl_framing_data(gb, ch0);

        let num_bands =
            ACPL_NUM_PARAM_BANDS[self.st.substream.acpl_num_param_bands_id as usize] as i32;
        let st = self.st.substream.acpl_param_band as usize;
        let qm0 = self.st.substream.acpl_quant_mode[0] as usize;
        let qm1 = self.st.substream.acpl_quant_mode[1] as usize;

        self.acpl_ec_data(gb, ch0, enums::ALPHA1 as usize, num_bands, st, qm0)?;
        self.acpl_ec_data(gb, ch0, enums::ALPHA2 as usize, num_bands, st, qm0)?;
        self.acpl_ec_data(gb, ch0, enums::BETA1 as usize, num_bands, st, qm0)?;
        self.acpl_ec_data(gb, ch0, enums::BETA2 as usize, num_bands, st, qm0)?;
        self.acpl_ec_data(gb, ch0, enums::BETA3 as usize, num_bands, st, qm0)?;
        self.acpl_ec_data(gb, ch1, enums::GAMMA1 as usize, num_bands, st, qm1)?;
        self.acpl_ec_data(gb, ch1, enums::GAMMA2 as usize, num_bands, st, qm1)?;
        self.acpl_ec_data(gb, ch1, enums::GAMMA3 as usize, num_bands, st, qm1)?;
        self.acpl_ec_data(gb, ch1, enums::GAMMA4 as usize, num_bands, st, qm1)?;
        self.acpl_ec_data(gb, ch1, enums::GAMMA5 as usize, num_bands, st, qm1)?;
        self.acpl_ec_data(gb, ch1, enums::GAMMA6 as usize, num_bands, st, qm1)?;

        Ok(())
    }

    fn acpl_data_1ch(&mut self, gb: &mut BitReader, ch: usize) -> Result<()> {
        self.acpl_framing_data(gb, ch);

        let num_bands =
            ACPL_NUM_PARAM_BANDS[self.st.substream.acpl_num_param_bands_id as usize] as i32;
        let start = self.st.substream.acpl_param_band as usize;
        let qm0 = self.st.substream.acpl_quant_mode[0] as usize;

        self.acpl_ec_data(gb, ch, enums::ALPHA1 as usize, num_bands, start, qm0)?;
        self.acpl_ec_data(gb, ch, enums::BETA1 as usize, num_bands, start, qm0)?;

        Ok(())
    }

    /// Copies the per-frame transform parameters between channel pairs
    /// (sf_info output shared by MS channels).
    fn copy_ch_frame_params(&mut self, src: usize, dst: usize) {
        let (scp, sect_sfb_offset, offset2sfb, offset2g, win_offset) = {
            let s = &self.st.substream.ssch[src];
            (
                s.scp.clone(),
                s.sect_sfb_offset,
                s.offset2sfb,
                s.offset2g,
                s.win_offset,
            )
        };
        let d = &mut self.st.substream.ssch[dst];
        d.scp = scp;
        d.sect_sfb_offset = sect_sfb_offset;
        d.offset2sfb = offset2sfb;
        d.offset2g = offset2g;
        d.win_offset = win_offset;
    }

    fn channel_pair_element(&mut self, gb: &mut BitReader, iframe: i32) -> Result<()> {
        self.st.ch_map[chan::FRONT_LEFT] = 0;
        self.st.ch_map[chan::FRONT_RIGHT] = 1;

        self.st.substream.codec_mode = gb.get_bits(2) as i32;
        if iframe != 0 {
            if self.st.substream.codec_mode != enums::CM_SIMPLE {
                self.aspx_config(gb);
            }
            if self.st.substream.codec_mode == enums::CM_ASPX_ACPL_1 {
                self.acpl_config_1ch(gb, enums::ACPL_PARTIAL)?;
            }
            if self.st.substream.codec_mode == enums::CM_ASPX_ACPL_2 {
                self.acpl_config_1ch(gb, enums::ACPL_FULL)?;
            }
        }

        match self.st.substream.codec_mode {
            enums::CM_SIMPLE => self.stereo_data(gb, iframe),
            enums::CM_ASPX => {
                self.companding_control(gb, 2)?;
                self.stereo_data(gb, iframe)?;
                self.aspx_data_2ch(gb, 0, 1, iframe)
            }
            enums::CM_ASPX_ACPL_1 => {
                self.companding_control(gb, 1)?;
                self.st.substream.mdct_stereo_proc[0] = gb.get_bits1() as u8;
                if self.st.substream.mdct_stereo_proc[0] != 0 {
                    self.st.substream.spec_frontend_m = enums::SF_ASF;
                    self.st.substream.spec_frontend_s = enums::SF_ASF;
                    self.sf_info(gb, 0, enums::SF_ASF, true, false)?;

                    self.copy_ch_frame_params(0, 1);

                    self.chparam_info(gb, 0)?;
                } else {
                    self.st.substream.spec_frontend_m = gb.get_bits1() as i32;
                    self.sf_info(gb, 0, self.st.substream.spec_frontend_m, false, false)?;
                    self.st.substream.spec_frontend_s = gb.get_bits1() as i32;
                    self.sf_info(gb, 1, self.st.substream.spec_frontend_s, false, true)?;
                }
                let fem = self.st.substream.spec_frontend_m;
                self.sf_data(gb, 0, iframe, fem)?;
                self.sf_data(gb, 1, iframe, fem)?;
                self.aspx_data_1ch(gb, 0, iframe)?;
                self.acpl_data_1ch(gb, 0)
            }
            enums::CM_ASPX_ACPL_2 => {
                self.companding_control(gb, 1)?;
                let spec_frontend = gb.get_bits1() as i32;
                self.sf_info(gb, 0, spec_frontend, false, false)?;
                self.sf_data(gb, 0, iframe, spec_frontend)?;
                self.aspx_data_1ch(gb, 0, iframe)?;
                self.acpl_data_1ch(gb, 0)
            }
            _ => Ok(()),
        }
    }

    fn four_channel_data(
        &mut self,
        gb: &mut BitReader,
        iframe: i32,
        ch_id: &[usize; 4],
    ) -> Result<()> {
        self.sf_info(gb, ch_id[0], enums::SF_ASF, false, false)?;

        let src = self.st.substream.ssch[ch_id[0]].clone();
        for &ch in &ch_id[1..] {
            self.st.substream.ssch[ch] = src.clone();
        }

        for &ch in ch_id {
            self.chparam_info(gb, ch)?;
        }

        for &ch in ch_id {
            self.sf_data(gb, ch, iframe, enums::SF_ASF)?;
        }

        Ok(())
    }

    fn five_channel_info(&mut self, gb: &mut BitReader, ch_id: &[usize; 5]) -> Result<()> {
        self.st.substream.chel_matsel = gb.get_bits(4) as u8;

        for &ch in ch_id {
            self.chparam_info(gb, ch)?;
        }

        Ok(())
    }

    fn five_channel_data(
        &mut self,
        gb: &mut BitReader,
        iframe: i32,
        ch_id: &[usize; 5],
    ) -> Result<()> {
        self.sf_info(gb, ch_id[0], enums::SF_ASF, false, false)?;

        for &ch in &ch_id[1..] {
            self.copy_ch_frame_params(ch_id[0], ch);
        }

        self.five_channel_info(gb, ch_id)?;

        for &ch in ch_id {
            self.sf_data(gb, ch, iframe, enums::SF_ASF)?;
        }

        Ok(())
    }

    fn sf_info_lfe(&mut self, gb: &mut BitReader, ch: usize) -> Result<()> {
        let n_msfbl_bits = Self::get_msfbl_bits(self.st.frame_len_base);
        let n_grp_bits = self.get_grp_bits(ch)?;

        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.scp.long_frame = 1;
            ssch.scp.max_sfb[0] = gb.get_bits(n_msfbl_bits) as u8;
            ssch.scp.num_window_groups = 1;
            ssch.scp.transf_length_idx[0] = 4;
        }

        self.asf_psy_elements(ch, n_grp_bits)
    }

    fn mono_data(&mut self, gb: &mut BitReader, ch: usize, lfe: bool, iframe: i32) -> Result<()> {
        let spec_frontend;
        if lfe {
            spec_frontend = enums::SF_ASF;
            self.sf_info_lfe(gb, ch)?;
        } else {
            spec_frontend = gb.get_bits1() as i32;
            self.sf_info(gb, ch, spec_frontend, false, false)?;
        }
        self.sf_data(gb, ch, iframe, spec_frontend)
    }

    fn two_channel_data(
        &mut self,
        gb: &mut BitReader,
        ch_id: &[usize; 2],
        x: usize,
        iframe: i32,
    ) -> Result<()> {
        self.st.substream.mdct_stereo_proc[x] = gb.get_bits1() as u8;
        if self.st.substream.mdct_stereo_proc[x] != 0 {
            self.sf_info(gb, ch_id[0], enums::SF_ASF, false, false)?;

            self.copy_ch_frame_params(ch_id[0], ch_id[1]);

            self.chparam_info(gb, ch_id[0])?;
        } else {
            self.sf_info(gb, ch_id[0], enums::SF_ASF, false, false)?;
            self.sf_info(gb, ch_id[1], enums::SF_ASF, false, false)?;
        }
        self.sf_data(gb, ch_id[0], iframe, enums::SF_ASF)?;
        self.sf_data(gb, ch_id[1], iframe, enums::SF_ASF)
    }

    fn three_channel_info(&mut self, gb: &mut BitReader, ch_id: &[usize; 3]) -> Result<()> {
        self.st.substream.chel_matsel = gb.get_bits(4) as u8;
        self.chparam_info(gb, ch_id[0])?;
        self.chparam_info(gb, ch_id[1])
    }

    fn three_channel_data(
        &mut self,
        gb: &mut BitReader,
        ch_id: &[usize; 3],
        iframe: i32,
    ) -> Result<()> {
        self.sf_info(gb, ch_id[0], enums::SF_ASF, false, false)?;

        for &ch in &ch_id[1..] {
            self.copy_ch_frame_params(ch_id[0], ch);
        }

        self.three_channel_info(gb, ch_id)?;
        self.sf_data(gb, ch_id[0], iframe, enums::SF_ASF)?;
        self.sf_data(gb, ch_id[1], iframe, enums::SF_ASF)?;
        self.sf_data(gb, ch_id[2], iframe, enums::SF_ASF)?;

        Ok(())
    }

    fn immers_cfg(&mut self, gb: &mut BitReader) -> Result<()> {
        if self.st.substream.im_codec_mode != enums::IM_SCPL {
            self.aspx_config(gb);
        }

        if self.st.substream.im_codec_mode == enums::IM_ASPX_ACPL_1 {
            self.acpl_config_1ch(gb, enums::ACPL_PARTIAL)?;
        }

        if self.st.substream.im_codec_mode == enums::IM_ASPX_ACPL_2 {
            self.acpl_config_1ch(gb, enums::ACPL_FULL)?;
        }

        Ok(())
    }

    const IMMERSIVE_CH_INDEX: [[[usize; 2]; 2]; 2] = [[[0, 1], [3, 4]], [[0, 3], [1, 4]]];

    fn immersive_channel_element(
        &mut self,
        gb: &mut BitReader,
        lfe: bool,
        fronts: bool,
        iframe: i32,
    ) -> Result<()> {
        {
            let ch_map = &mut self.st.ch_map;
            ch_map[chan::FRONT_LEFT] = 0;
            ch_map[chan::FRONT_RIGHT] = 1;
            ch_map[chan::FRONT_CENTER] = 2;
            ch_map[chan::LOW_FREQUENCY] = 7;
            ch_map[chan::SIDE_LEFT] = 3;
            ch_map[chan::SIDE_RIGHT] = 4;
            ch_map[chan::BACK_LEFT] = 5;
            ch_map[chan::BACK_RIGHT] = 6;
            ch_map[chan::TOP_FRONT_LEFT] = 8;
            ch_map[chan::TOP_FRONT_RIGHT] = 9;
            ch_map[chan::TOP_BACK_LEFT] = 10;
            ch_map[chan::TOP_BACK_RIGHT] = 11;
        }

        if gb.get_bits1() == 0 {
            self.st.substream.im_codec_mode = gb.get_bits(2) as i32;
        } else {
            self.st.substream.im_codec_mode = enums::IM_ASPX_AJCC;
        }

        if iframe != 0 {
            self.immers_cfg(gb)?;
        }

        if lfe {
            self.mono_data(gb, 7, true, iframe)?;
        }

        if self.st.substream.im_codec_mode == enums::IM_ASPX_AJCC {
            self.companding_control(gb, 5)?;
        }

        self.st.substream.core_5ch_grouping = gb.get_bits(2) as i32;
        match self.st.substream.core_5ch_grouping {
            0 => {
                self.st.substream.mode_2ch = gb.get_bits1() as u8;
                let idx = Self::IMMERSIVE_CH_INDEX[self.st.substream.mode_2ch as usize];
                self.two_channel_data(gb, &idx[0], 0, iframe)?;
                self.two_channel_data(gb, &idx[1], 1, iframe)?;
                self.mono_data(gb, 2, false, iframe)?;
            }
            1 => {
                self.three_channel_data(gb, &[0, 1, 2], iframe)?;
                self.two_channel_data(gb, &[3, 4], 0, iframe)?;
            }
            2 => {
                self.four_channel_data(gb, iframe, &[0, 1, 2, 3])?;
                self.mono_data(gb, 4, false, iframe)?;
            }
            3 => {
                self.five_channel_data(gb, iframe, &[0, 1, 2, 3, 4])?;
            }
            _ => {}
        }

        let im = self.st.substream.im_codec_mode;
        if im != enums::IM_ASPX_AJCC {
            self.st.substream.use_sap_add_ch = gb.get_bits1() as i32;

            if self.st.substream.use_sap_add_ch != 0 {
                self.chparam_info(gb, 5)?;
                self.chparam_info(gb, 6)?;
            }

            self.two_channel_data(gb, &[5, 6], 2, iframe)?;
        }

        if im == enums::IM_ASPX_SCPL {
            self.aspx_data_2ch(gb, 0, 1, iframe)?;
            self.aspx_data_2ch(gb, 2, 3, iframe)?;
            self.aspx_data_1ch(gb, 7, iframe)?;

            if fronts {
                self.aspx_data_2ch(gb, 4, 5, iframe)?;
                self.aspx_data_2ch(gb, 6, 8, iframe)?;
            } else {
                self.aspx_data_2ch(gb, 4, 5, iframe)?;
            }

            self.aspx_data_2ch(gb, 9, 10, iframe)?;
            self.aspx_data_2ch(gb, 10, 11, iframe)?;
        } else if im != enums::IM_SCPL {
            self.aspx_data_2ch(gb, 0, 1, iframe)?;
            self.aspx_data_2ch(gb, 3, 4, iframe)?;

            if im != enums::IM_ASPX_AJCC {
                self.aspx_data_2ch(gb, 5, 6, iframe)?;
            }

            self.aspx_data_1ch(gb, 2, iframe)?;
        }

        if im == enums::IM_SCPL || im == enums::IM_ASPX_SCPL || im == enums::IM_ASPX_ACPL_1 {
            self.two_channel_data(gb, &[8, 9], 3, iframe)?;

            self.two_channel_data(gb, &[10, 11], 4, iframe)?;
        }

        if im == enums::IM_ASPX_ACPL_1 || im == enums::IM_ASPX_ACPL_2 {
            self.acpl_data_1ch(gb, 0)?;
            self.acpl_data_1ch(gb, 1)?;
            self.acpl_data_1ch(gb, 2)?;
            self.acpl_data_1ch(gb, 3)?;
            if fronts {
                self.acpl_data_1ch(gb, 4)?;
                self.acpl_data_1ch(gb, 5)?;
            }
        }

        Ok(())
    }

    fn channel_element_7x(
        &mut self,
        gb: &mut BitReader,
        channel_mode: i32,
        iframe: i32,
    ) -> Result<()> {
        self.st.substream.codec_mode = gb.get_bits(2) as i32;
        if iframe != 0 {
            if self.st.substream.codec_mode != enums::CM_SIMPLE {
                self.aspx_config(gb);
            }
            if self.st.substream.codec_mode == enums::CM_ASPX_ACPL_1 {
                self.acpl_config_1ch(gb, enums::ACPL_PARTIAL)?;
            }
            if self.st.substream.codec_mode == enums::CM_ASPX_ACPL_2 {
                self.acpl_config_1ch(gb, enums::ACPL_FULL)?;
            }
        }

        if channel_mode == 6 {
            self.mono_data(gb, 7, true, iframe)?;
        }

        if self.st.substream.codec_mode == enums::CM_ASPX_ACPL_1
            || self.st.substream.codec_mode == enums::CM_ASPX_ACPL_2
        {
            self.companding_control(gb, 5)?;
        }

        self.st.substream.coding_config = gb.get_bits(2) as u8;
        match self.st.substream.coding_config {
            0 => {
                self.st.substream.mode_2ch = gb.get_bits1() as u8;
                self.two_channel_data(gb, &[0, 1], 0, iframe)?;
                self.two_channel_data(gb, &[2, 3], 1, iframe)?;
            }
            1 => {
                self.three_channel_data(gb, &[0, 1, 2], iframe)?;
                self.two_channel_data(gb, &[3, 4], 1, iframe)?;
            }
            2 => {
                self.four_channel_data(gb, iframe, &[0, 1, 2, 3])?;
            }
            3 => {
                self.five_channel_data(gb, iframe, &[0, 1, 2, 3, 4])?;
            }
            _ => {}
        }

        if self.st.substream.codec_mode == enums::CM_SIMPLE
            || self.st.substream.codec_mode == enums::CM_ASPX
        {
            if gb.get_bits1() != 0 {
                // C ignores the return values of these two calls.
                let _ = self.chparam_info(gb, 5);
                let _ = self.chparam_info(gb, 6);
            }
            self.two_channel_data(gb, &[5, 6], 1, iframe)?;
        }

        // C has an empty CM_ASPX_ACPL_1 branch here (XXX).

        Ok(())
    }

    fn channel_element_3x(&mut self, gb: &mut BitReader, iframe: i32) -> Result<()> {
        self.st.substream.codec_mode = gb.get_bits1() as i32;
        if self.st.substream.codec_mode == enums::CM_ASPX {
            if iframe != 0 {
                self.aspx_config(gb);
            }
            self.companding_control(gb, 3)?;
        }

        self.st.ch_map[chan::FRONT_LEFT] = 0;
        self.st.ch_map[chan::FRONT_RIGHT] = 1;
        self.st.ch_map[chan::FRONT_CENTER] = 2;

        self.st.substream.coding_config = gb.get_bits1() as u8;
        match self.st.substream.coding_config {
            0 => {
                self.stereo_data(gb, iframe)?;
                self.mono_data(gb, 2, false, iframe)?;
            }
            1 => {
                self.three_channel_data(gb, &[0, 1, 2], iframe)?;
            }
            _ => {}
        }

        if self.st.substream.codec_mode == enums::CM_ASPX {
            self.aspx_data_2ch(gb, 0, 1, iframe)?;
            self.aspx_data_1ch(gb, 2, iframe)?;
        }

        Ok(())
    }

    fn channel_element_5x(&mut self, gb: &mut BitReader, lfe: bool, iframe: i32) -> Result<()> {
        self.st.substream.codec_mode = gb.get_bits(3) as i32;
        if iframe != 0 {
            if self.st.substream.codec_mode != enums::CM_SIMPLE {
                self.aspx_config(gb);
            }
            if self.st.substream.codec_mode == enums::CM_ASPX_ACPL_1 {
                self.acpl_config_1ch(gb, enums::ACPL_PARTIAL)?;
            }
            if self.st.substream.codec_mode == enums::CM_ASPX_ACPL_2 {
                self.acpl_config_1ch(gb, enums::ACPL_FULL)?;
            }
            if self.st.substream.codec_mode == enums::CM_ASPX_ACPL_3 {
                self.acpl_config_2ch(gb)?;
            }
        }

        if lfe {
            self.st.ch_map[chan::LOW_FREQUENCY] = 5;

            self.mono_data(gb, 5, true, iframe)?;
        }

        match self.st.substream.codec_mode {
            enums::CM_SIMPLE | enums::CM_ASPX => {
                if self.st.substream.codec_mode == enums::CM_ASPX {
                    self.companding_control(gb, 5)?;
                }

                self.st.substream.coding_config = gb.get_bits(2) as u8;
                match self.st.substream.coding_config {
                    0 => {
                        self.st.substream.mode_2ch = gb.get_bits1() as u8;

                        if self.st.substream.mode_2ch != 0 {
                            self.st.ch_map[chan::FRONT_LEFT] = 0;
                            self.st.ch_map[chan::SIDE_LEFT] = 1;
                            self.st.ch_map[chan::FRONT_RIGHT] = 2;
                            self.st.ch_map[chan::SIDE_RIGHT] = 3;
                        } else {
                            self.st.ch_map[chan::FRONT_LEFT] = 0;
                            self.st.ch_map[chan::FRONT_RIGHT] = 1;
                            self.st.ch_map[chan::SIDE_LEFT] = 2;
                            self.st.ch_map[chan::SIDE_RIGHT] = 3;
                        }
                        self.st.ch_map[chan::FRONT_CENTER] = 4;

                        self.two_channel_data(gb, &[0, 1], 0, iframe)?;
                        self.two_channel_data(gb, &[2, 3], 1, iframe)?;
                        self.mono_data(gb, 4, false, iframe)?;
                    }
                    1 => {
                        self.st.ch_map[chan::FRONT_LEFT] = 0;
                        self.st.ch_map[chan::FRONT_RIGHT] = 1;
                        self.st.ch_map[chan::FRONT_CENTER] = 2;
                        self.st.ch_map[chan::SIDE_LEFT] = 3;
                        self.st.ch_map[chan::SIDE_RIGHT] = 4;

                        self.three_channel_data(gb, &[0, 1, 2], iframe)?;
                        self.two_channel_data(gb, &[3, 4], 0, iframe)?;
                    }
                    2 => {
                        self.st.ch_map[chan::FRONT_LEFT] = 0;
                        self.st.ch_map[chan::FRONT_RIGHT] = 1;
                        self.st.ch_map[chan::SIDE_LEFT] = 2;
                        self.st.ch_map[chan::SIDE_RIGHT] = 3;
                        self.st.ch_map[chan::FRONT_CENTER] = 4;

                        self.four_channel_data(gb, iframe, &[0, 1, 2, 3])?;
                        self.mono_data(gb, 4, false, iframe)?;
                    }
                    3 => {
                        self.st.ch_map[chan::FRONT_LEFT] = 0;
                        self.st.ch_map[chan::FRONT_RIGHT] = 1;
                        self.st.ch_map[chan::FRONT_CENTER] = 2;
                        self.st.ch_map[chan::SIDE_LEFT] = 3;
                        self.st.ch_map[chan::SIDE_RIGHT] = 4;

                        self.five_channel_data(gb, iframe, &[0, 1, 2, 3, 4])?;
                    }
                    _ => {}
                }

                if self.st.substream.codec_mode == enums::CM_ASPX {
                    self.aspx_data_2ch(gb, 0, 1, iframe)?;
                    self.aspx_data_2ch(gb, 2, 3, iframe)?;
                    self.aspx_data_1ch(gb, 4, iframe)?;
                }
            }
            enums::CM_ASPX_ACPL_1 | enums::CM_ASPX_ACPL_2 => {
                self.companding_control(gb, 3)?;
                self.st.substream.coding_config = gb.get_bits1() as u8;
                if self.st.substream.coding_config != 0 {
                    self.three_channel_data(gb, &[0, 1, 2], iframe)?;
                } else {
                    self.two_channel_data(gb, &[0, 1], 0, iframe)?;
                }

                if self.st.substream.codec_mode == enums::CM_ASPX_ACPL_1 {
                    self.st.substream.max_sfb_master = gb.get_bits(5) as i32; // XXX
                    let cc = self.st.substream.coding_config as usize;
                    self.chparam_info(gb, 2 + cc)?;
                    self.chparam_info(gb, 3 + cc)?;
                    self.sf_data(gb, 2 + cc, iframe, enums::SF_ASF)?;
                    self.sf_data(gb, 3 + cc, iframe, enums::SF_ASF)?;
                }
                if self.st.substream.coding_config == 0 {
                    self.mono_data(gb, 2, false, iframe)?;
                }

                self.st.ch_map[chan::FRONT_LEFT] = 0;
                self.st.ch_map[chan::FRONT_RIGHT] = 1;
                self.st.ch_map[chan::FRONT_CENTER] = 2;
                self.st.ch_map[chan::SIDE_LEFT] = 3;
                self.st.ch_map[chan::SIDE_RIGHT] = 4;

                self.aspx_data_2ch(gb, 0, 1, iframe)?;
                self.aspx_data_1ch(gb, 2, iframe)?;
                self.acpl_data_1ch(gb, 0)?;
                self.acpl_data_1ch(gb, 1)?;
            }
            enums::CM_ASPX_ACPL_3 => {
                self.companding_control(gb, 2)?;
                self.stereo_data(gb, iframe)?;

                self.st.ch_map[chan::FRONT_LEFT] = 0;
                self.st.ch_map[chan::FRONT_RIGHT] = 1;
                self.st.ch_map[chan::FRONT_CENTER] = 2;
                self.st.ch_map[chan::SIDE_LEFT] = 3;
                self.st.ch_map[chan::SIDE_RIGHT] = 4;

                self.aspx_data_2ch(gb, 0, 1, iframe)?;
                self.acpl_data_2ch(gb, 0, 1)?;
            }
            _ => {
                return Err(invalid("invalid codec mode"));
            }
        }

        Ok(())
    }

    fn single_channel_element(&mut self, gb: &mut BitReader, iframe: i32) -> Result<()> {
        self.st.ch_map[chan::FRONT_CENTER] = 0;

        self.st.substream.codec_mode = gb.get_bits1() as i32;
        if iframe != 0 && self.st.substream.codec_mode == enums::CM_ASPX {
            self.aspx_config(gb);
        }
        if self.st.substream.codec_mode == enums::CM_SIMPLE {
            self.mono_data(gb, 0, false, iframe)
        } else {
            self.companding_control(gb, 1)?;
            self.mono_data(gb, 0, false, iframe)?;
            self.aspx_data_1ch(gb, 0, iframe)
        }
    }

    fn audio_data(&mut self, gb: &mut BitReader, channel_mode: i32, iframe: i32) -> Result<()> {
        match channel_mode {
            0 => self.single_channel_element(gb, iframe),
            1 => self.channel_pair_element(gb, iframe),
            2 => self.channel_element_3x(gb, iframe),
            3 => self.channel_element_5x(gb, false, iframe),
            4 => self.channel_element_5x(gb, true, iframe),
            5 | 6 => self.channel_element_7x(gb, channel_mode, iframe),
            11 => self.immersive_channel_element(gb, false, false, iframe),
            12 => self.immersive_channel_element(gb, true, false, iframe),
            13 => self.immersive_channel_element(gb, false, true, iframe),
            14 => self.immersive_channel_element(gb, true, true, iframe),
            _ => Err(unsupported("channel_mode")),
        }
    }

    fn variable_channel_element(
        &mut self,
        gb: &mut BitReader,
        count: usize,
        lfe: bool,
        iframe: i32,
    ) -> Result<()> {
        let first = usize::from(lfe);
        if count == 0 || count + first > 12 {
            return Err(unsupported("A-JOC core signal count"));
        }
        self.variable_pairs.clear();
        self.st.substream.compand_on.fill(0);
        self.st.substream.sync_flag = 0;
        self.st.substream.codec_mode = gb.get_bits1() as i32;
        if self.st.substream.codec_mode == enums::CM_ASPX {
            if iframe != 0 {
                self.aspx_config(gb);
            }
            if count <= 5 {
                self.companding_control(gb, count as i32)?;
                if lfe {
                    self.st.substream.compand_on.copy_within(0..count, 1);
                    self.st.substream.compand_on[0] = 0;
                }
            }
        }
        if lfe {
            self.mono_data(gb, 0, true, iframe)?;
        }
        let pairs = count / 2;
        let regular_pairs = if count % 2 == 1 && count > 1 {
            pairs - 1
        } else {
            pairs
        };
        for p in 0..regular_pairs {
            let ch = first + p * 2;
            self.two_channel_data(gb, &[ch, ch + 1], p, iframe)?;
            if self.st.substream.mdct_stereo_proc[p] != 0 {
                self.variable_pairs.push((ch, ch + 1));
            }
        }
        if count == 1 {
            self.mono_data(gb, first, false, iframe)?;
        } else if count % 2 == 1 {
            let ch = first + regular_pairs * 2;
            if gb.get_bits1() == 0 {
                self.two_channel_data(gb, &[ch, ch + 1], regular_pairs, iframe)?;
                if self.st.substream.mdct_stereo_proc[regular_pairs] != 0 {
                    self.variable_pairs.push((ch, ch + 1));
                }
                self.mono_data(gb, ch + 2, false, iframe)?;
            } else {
                return Err(unsupported("A-JOC three-channel core grouping"));
            }
        }
        if self.st.substream.codec_mode == enums::CM_ASPX {
            for p in 0..pairs {
                self.aspx_data_2ch(gb, first + p * 2, first + p * 2 + 1, iframe)?;
            }
            if count % 2 == 1 {
                self.aspx_data_1ch(gb, first + count - 1, iframe)?;
            }
        }
        Ok(())
    }

    fn ac4_substream(
        &mut self,
        gb: &mut BitReader,
        ssg_idx: usize,
        substream_size: i32,
    ) -> Result<()> {
        if substream_size > 0 && substream_size as i64 * 8 > gb.bits_left() {
            return Err(invalid("truncated audio substream"));
        }
        let header_start = gb.bits_count();
        let mut audio_size = gb.get_bits(15) as i64;
        if gb.get_bits1() != 0 {
            audio_size += (Self::variable_bits(gb, 7) as i64) << 15;
        }
        let header_bytes = (gb.bits_count() - header_start).div_ceil(8) as i64;
        if !(0..=131072).contains(&audio_size)
            || audio_size * 8 > gb.bits_left()
            || (substream_size > 0 && audio_size + header_bytes > substream_size as i64)
        {
            return Err(invalid("invalid audio_size"));
        }
        let audio_size = audio_size as i32;

        gb.align();

        let offset = (gb.bits_count() >> 3) as i32;
        if self.st.ssgroup[ssg_idx].channel_coded != 0 {
            let channel_mode = self.st.ssgroup[ssg_idx].ssinfo.channel_mode;
            let iframe0 = self.st.ssgroup[ssg_idx].ssinfo.iframe[0];
            self.audio_data(gb, channel_mode, iframe0)?;
        } else if self.st.ssgroup[ssg_idx].ajoc != 0 && self.ajoc_core {
            let ssi = self.st.ssgroup[ssg_idx].ssinfo.clone();
            let iframe = ssi.audio_ndot[0];
            if ssi.static_dmx != 0 {
                self.audio_data(gb, if ssi.lfe != 0 { 4 } else { 3 }, iframe)?;
            } else {
                let count = ssi.n_fullband_dmx_signals as usize;
                if gb.get_bits1() != 0 {
                    gb.skip_bits_long(count as i64);
                }
                self.variable_channel_element(gb, count, ssi.lfe != 0, iframe)?;
            }
            if self.ajoc_metadata_enabled {
                if self.st.pinfo[0].psinfo.alternative != 0 {
                    return Err(unsupported("alternative A-JOC object metadata"));
                }
                if ssi.static_dmx != 0 || !ssi.dynamic_dmx || !ssi.dynamic_upmix {
                    return Err(unsupported("A-JOC metadata assignment"));
                }
                self.ajoc_metadata = Some(crate::ajoc::parse(
                    gb,
                    (offset + audio_size) as usize * 8,
                    ssi.n_fullband_dmx_signals as usize,
                    ssi.n_fullband_upmix_signals as usize,
                    ssi.lfe != 0,
                    iframe != 0,
                    &mut self.st.ajoc_history,
                )?);
            }
            // Core decoding ends after the downmix essence. The remaining
            // audio_size bytes contain reconstruction and object metadata.
            // They are bounded and skipped below, never treated as PCM.
        } else {
            //audio_data_objs();
            return Err(unsupported("objects substream"));
        }

        gb.align();
        let consumed = (gb.bits_count() >> 3) as i32 - offset;
        if self.ajoc_core && self.st.ssgroup[ssg_idx].ajoc != 0 && consumed > audio_size {
            return Err(invalid("A-JOC essence exceeds audio_size"));
        }

        if consumed < audio_size {
            gb.skip_bits_long((audio_size - consumed) as i64 * 8);
        }

        gb.align();

        if substream_size > 0 {
            // i64 math: corrupt streams can make the difference huge or
            // negative; negative padding (C would rewind into UB) is skipped
            let pad = (substream_size as i64 - audio_size as i64 - 2).max(0) * 8;
            gb.skip_bits_long(pad);
        }

        Ok(())
    }

    fn spectral_reordering(&mut self, ch: usize) {
        let flb = self.st.frame_len_base;
        let ssch = &mut self.st.substream.ssch[ch];
        let mut k = 0usize;
        let mut win = 0usize;
        ssch.spec_reord = [0.0; 2048];

        for g in 0..ssch.scp.num_window_groups as usize {
            let (transf_length_g, _) = get_transf_length_(flb, ssch, g as i32);
            let sfb_offset = get_sfb_offset(transf_length_g);
            let max_sfb = get_max_sfb_(flb, ssch, g as i32);

            for sfb in 0..max_sfb as usize {
                // corrupt streams can report max_sfb past the offset table
                if sfb + 1 >= sfb_offset.len() {
                    break;
                }
                for w in 0..ssch.scp.num_win_in_group[g] as usize {
                    for l in sfb_offset[sfb] as usize..sfb_offset[sfb + 1] as usize {
                        let dst = (ssch.win_offset[win + w] + l as i32) as usize;
                        // corrupt streams can push dst/k past the buffers;
                        // C would index out of bounds (UB). The masks keep
                        // this branch-free on the hot path.
                        ssch.spec_reord[dst & 2047] = ssch.scaled_spec[k & 2047];
                        k += 1;
                    }
                }
            }
            win += ssch.scp.num_win_in_group[g] as usize;
        }
    }

    fn scale_spec(&mut self, ch: usize) {
        let flb = self.st.frame_len_base as usize;
        let ssch = &mut self.st.substream.ssch[ch];
        ssch.scaled_spec = [0.0; 2048];

        for k in 0..flb {
            let x = ssch.quant_spec[k] as i32;
            let sfb = ssch.offset2sfb[k] as usize;
            let g = ssch.offset2g[k] as usize;
            // clamp: escape-decoded values can exceed the table (C would
            // read past it)
            let mag = self.tables.quant_lut[x.unsigned_abs() as usize & 8191];
            ssch.scaled_spec[k] = ssch.sf_gain[g][sfb] * mag.copysign(x as f32);
        }
    }

    fn two_channel_processing(&mut self, ch0: usize, ch1: usize) {
        let flb = self.st.frame_len_base;
        self.st.substream.alpha_q = [[0i8; 128]; 16];

        let mut max_sfb_prev = get_max_sfb_(flb, &self.st.substream.ssch[ch0], 0);
        for g in 0..self.st.substream.ssch[ch0].scp.num_window_groups as i32 {
            let max_sfb_g = get_max_sfb_(flb, &self.st.substream.ssch[ch0], g);

            for sfb in 0..max_sfb_g as usize {
                let (sap_mode, ms, cu, dpcm, dct) = {
                    let s0 = &self.st.substream.ssch[ch0];
                    (
                        s0.sap_mode,
                        s0.ms_used[g as usize][sfb],
                        s0.sap_coeff_used[g as usize][sfb],
                        s0.dpcm_alpha_q[g as usize][sfb],
                        s0.delta_code_time,
                    )
                };
                let m;
                if sap_mode == 0 || (sap_mode == 1 && ms == 0) {
                    m = [[1.0f32, 0.0], [0.0, 1.0]];
                } else if sap_mode == 2 || (sap_mode == 1 && ms == 1) {
                    m = [[1.0f32, 1.0], [1.0, -1.0]];
                } else if sap_mode == 3 {
                    if cu != 0 {
                        // setup alpha_q[g][sfb]
                        if sfb & 1 != 0 {
                            self.st.substream.alpha_q[g as usize][sfb] =
                                self.st.substream.alpha_q[g as usize][sfb - 1];
                        } else {
                            let delta = dpcm as i32 - 60;
                            let code_delta = if g == 0 || max_sfb_g != max_sfb_prev {
                                0
                            } else {
                                dct
                            };
                            let aq = if code_delta != 0 {
                                self.st.substream.alpha_q[(g - 1) as usize][sfb] as i32 + delta
                            } else if sfb == 0 {
                                delta
                            } else {
                                self.st.substream.alpha_q[g as usize][sfb - 2] as i32 + delta
                            };
                            self.st.substream.alpha_q[g as usize][sfb] = aq as i8;
                        }
                        // inverse quantize alpha_q[g][sfb]
                        let sap_gain = self.st.substream.alpha_q[g as usize][sfb] as f32 * 0.1;
                        m = [[1.0 + sap_gain, 1.0], [1.0 - sap_gain, -1.0]];
                    } else {
                        m = [[1.0f32, 0.0], [0.0, 1.0]];
                    }
                } else {
                    // sap_mode outside 0..3 would leave m uninitialized;
                    // the bitstream cannot produce it through sap_data().
                    m = [[1.0f32, 0.0], [0.0, 1.0]];
                }

                self.st.substream.matrix_stereo[g as usize][sfb] = m;
            }

            max_sfb_prev = max_sfb_g;
        }

        for k in 0..flb as usize {
            let (sfb, g, i0, i1) = {
                let s0 = &self.st.substream.ssch[ch0];
                let s1 = &self.st.substream.ssch[ch1];
                (
                    s0.offset2sfb[k] as usize,
                    s0.offset2g[k] as usize,
                    s0.scaled_spec[k],
                    s1.scaled_spec[k],
                )
            };
            let m = self.st.substream.matrix_stereo[g][sfb];
            let o0 = i0 * m[0][0] + i1 * m[0][1];
            let o1 = i0 * m[1][0] + i1 * m[1][1];
            self.st.substream.ssch[ch0].scaled_spec[k] = o0;
            self.st.substream.ssch[ch1].scaled_spec[k] = o1;
        }
    }

    fn stereo_processing(&mut self) {
        if self.st.substream.mdct_stereo_proc[0] != 0 {
            self.two_channel_processing(0, 1);
        }
    }

    fn m5channel_processing(&mut self) {
        match self.st.substream.codec_mode {
            enums::CM_SIMPLE | enums::CM_ASPX => {
                if self.st.substream.coding_config == 0 {
                    if self.st.substream.mdct_stereo_proc[0] != 0 {
                        self.two_channel_processing(0, 1);
                    }
                    if self.st.substream.mdct_stereo_proc[1] != 0 {
                        self.two_channel_processing(2, 3);
                    }
                }
            }
            enums::CM_ASPX_ACPL_1 | enums::CM_ASPX_ACPL_2 | enums::CM_ASPX_ACPL_3
                if self.st.substream.coding_config == 0
                    && self.st.substream.mdct_stereo_proc[0] != 0 =>
            {
                self.two_channel_processing(0, 1);
            }
            _ => {}
        }
    }

    fn qmf_analysis(&mut self, ch: usize) {
        let nts = self.st.num_qmf_timeslots as usize;
        let mut u = [0.0f32; MAX_QMF_BANDS * 2];

        for ts in 0..nts {
            let ssch = &mut self.st.substream.ssch[ch];
            // shift time-domain input samples by MAX_QMF_BANDS
            ssch.qana_filt
                .copy_within(0..MAX_QMF_BANDS * 10 - MAX_QMF_BANDS, MAX_QMF_BANDS);

            // feed new audio samples
            for sb in (0..MAX_QMF_BANDS).rev() {
                ssch.qana_filt[sb] =
                    ssch.pcm[ts * MAX_QMF_BANDS + MAX_QMF_BANDS - 1 - sb] / 32768.0;
            }

            // fold the windowed samples straight into u:
            // u[j] = sum_k filt[128k + j] * QWIN[128k + j], k ascending
            // (same per-element arithmetic as the naive window-then-sum).
            {
                let filt = &ssch.qana_filt;
                for j in 0..MAX_QMF_BANDS * 2 {
                    u[j] = filt[j] * QWIN[j];
                }
                for k in 1..5 {
                    let s = &filt[k * MAX_QMF_BANDS * 2..(k + 1) * MAX_QMF_BANDS * 2];
                    let ws = &QWIN[k * MAX_QMF_BANDS * 2..(k + 1) * MAX_QMF_BANDS * 2];
                    for j in 0..MAX_QMF_BANDS * 2 {
                        u[j] += s[j] * ws[j];
                    }
                }
            }

            // compute MAX_QMF_BANDS new subband samples (FFT-based; the
            // naive dot products are covered by the qmf.rs unit tests).
            let (qa, qb) = ssch.q.split_at_mut(1);
            self.tables
                .qmf_ana
                .bands(&u, &mut qa[0][ts], &mut qb[0][ts]);
        }
    }

    fn qmf_synthesis(&mut self, ch: usize, pcm_out: &mut [f32]) {
        let nts = self.st.num_qmf_timeslots as usize;
        for ts in 0..nts {
            let ssch = &mut self.st.substream.ssch[ch];
            let mut slot = [0.0; MAX_QMF_BANDS];
            self.tables.qmf_syn.synthesize_slot(
                &mut ssch.qsyn_filt,
                &ssch.q[0][ts],
                &ssch.q[1][ts],
                &mut slot,
            );
            pcm_out[ts * MAX_QMF_BANDS..(ts + 1) * MAX_QMF_BANDS].copy_from_slice(&slot);
        }
    }

    fn spectral_synthesis(&mut self, ch: usize) {
        let mut swinl = [0.0f32; 2048];
        let mut swinr = [0.0f32; 2048];
        let n_full = self.st.frame_len_base;
        let midx = self.st.frame_len_base_idx as usize;
        let mut win = 0usize;

        for g in 0..self.st.substream.ssch[ch].scp.num_window_groups as usize {
            let (n, idx) = get_transf_length_(n_full, &self.st.substream.ssch[ch], g as i32);
            let idx = idx as usize;
            let n_prev = {
                let ssch = &self.st.substream.ssch[ch];
                if ssch.n_prev == 0 {
                    n_full
                } else {
                    ssch.n_prev
                }
            };
            let n_w = n.min(n_prev);
            let wnskip_prev = (n_prev - n_w) >> 1;
            let wnskip = (n - n_w) >> 1;
            let nskip_prev = (n_full - n_prev) >> 1;
            let nskip = (n_full - n) >> 1;

            debug_assert!(wnskip + wnskip + n_w == n);
            debug_assert!(wnskip_prev + wnskip_prev + n_w == n_prev);

            {
                let idx_prev = self.st.substream.ssch[ch].idx_prev as usize;
                let winl: &[f32] = &self.tables.kbd_window[midx][idx][..];
                let winr: &[f32] = &self.tables.kbd_window[midx][idx_prev][..];
                let winf: &[f32] = if n_w == n { winl } else { winr };
                for v in swinl.iter_mut() {
                    *v = 0.0;
                }
                for v in swinr.iter_mut() {
                    *v = 0.0;
                }
                swinl[wnskip as usize..(wnskip + n_w) as usize]
                    .copy_from_slice(&winf[..n_w as usize]);
                for n in 0..wnskip as usize {
                    swinl[(wnskip + n_w) as usize + n] = 1.0;
                }
                swinr[wnskip_prev as usize..(wnskip_prev + n_w) as usize]
                    .copy_from_slice(&winf[..n_w as usize]);
                for n in 0..wnskip_prev as usize {
                    swinr[(wnskip_prev + n_w) as usize + n] = 1.0;
                }
            }

            for w in 0..self.st.substream.ssch[ch].scp.num_win_in_group[g] as usize {
                // clamp: corrupt streams can push the window past the buffer
                // (C would read out of bounds); well-formed windows are
                // always within bounds so this is a no-op for them
                let woff = (self.st.substream.ssch[ch].win_offset[win + w] as usize)
                    .min(2048 - n as usize);
                let ssch = &mut self.st.substream.ssch[ch];
                self.tables.tx[midx][idx].imdct(
                    &ssch.spec_reord[woff..woff + n as usize],
                    &mut ssch.imdct_out[..(2 * n) as usize],
                );

                for n in 0..n as usize {
                    ssch.imdct_out[n] *= swinl[n];
                }
                // reversed window: overlap[i] *= swinr[len-1-i]
                for n in 0..n_prev as usize {
                    let i = nskip_prev as usize + n;
                    ssch.overlap[i] *= swinr[n_prev as usize - 1 - n];
                }

                for n in 0..n as usize {
                    ssch.overlap[nskip as usize + n] += ssch.imdct_out[n];
                }

                ssch.pcm[woff..woff + n as usize].copy_from_slice(&ssch.overlap[..n as usize]);
                ssch.overlap
                    .copy_within(n as usize..(n + nskip) as usize, 0);
                ssch.overlap[nskip as usize..(nskip + n) as usize]
                    .copy_from_slice(&ssch.imdct_out[n as usize..(2 * n) as usize]);
            }

            let ssch = &mut self.st.substream.ssch[ch];
            ssch.n_prev = n;
            ssch.idx_prev = idx as i32;

            win += ssch.scp.num_win_in_group[g] as usize;
        }
    }

    fn get_qsignal_scale_factors(&mut self, ch: usize) -> Result<()> {
        let mut sbg_idx_high2low = [0i32; 24];
        let mut sbg_idx_low2high = [0i32; 24];

        let (num_sbg_sig_highres, sbg_sig_lowres, sbg_sig_highres) = {
            let ssch = &self.st.substream.ssch[ch];
            (
                ssch.num_sbg_sig_highres,
                ssch.sbg_sig_lowres,
                ssch.sbg_sig_highres,
            )
        };
        let mut sbg_low = 0usize;
        for sbg in 0..num_sbg_sig_highres.max(0) as usize {
            // get(): corrupt streams can walk sbg_low past the table
            let next_low = sbg_sig_lowres.get(sbg_low + 1).copied().unwrap_or(i32::MIN);
            if next_low == sbg_sig_highres[sbg] && sbg_low + 1 < sbg_idx_low2high.len() {
                sbg_low += 1;
                sbg_idx_low2high[sbg_low] = sbg as i32;
            }
            sbg_idx_high2low[sbg] = sbg_low as i32;
        }

        let delta = if (ch & 1) != 0 && self.st.substream.ssch[ch].aspx_balance == 1 {
            2
        } else {
            1
        };

        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.qscf_sig_sbg_prev = ssch.qscf_sig_sbg;
            ssch.qscf_sig_sbg = [[0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];
        }

        if self.st.substream.ssch[ch].num_atsg_sig_prev <= 0 {
            return Err(invalid("num_atsg_sig_prev"));
        }

        // Loop over Envelopes
        for atsg in 0..self.st.substream.ssch[ch].num_atsg_sig as usize {
            let ssch = &mut self.st.substream.ssch[ch];
            let freqres_prev = if atsg == 0 {
                ssch.atsg_freqres[ssch.num_atsg_sig_prev as usize - 1]
            } else {
                ssch.atsg_freqres[atsg - 1]
            };

            // Loop over scale factor subband groups
            for sbg in 0..ssch.num_sbg_sig[atsg] as usize {
                let sbg_prev = if ssch.atsg_freqres[atsg] == freqres_prev {
                    sbg as i32
                } else if ssch.atsg_freqres[atsg] == 0 && freqres_prev == 1 {
                    sbg_idx_low2high[sbg]
                } else {
                    sbg_idx_high2low[sbg]
                };

                if atsg == 0 {
                    ssch.qscf_prev[atsg][sbg] = ssch.qscf_sig_sbg_prev
                        [ssch.num_atsg_sig_prev as usize - 1][sbg_prev as usize];
                } else {
                    ssch.qscf_prev[atsg][sbg] = ssch.qscf_sig_sbg[atsg - 1][sbg_prev as usize];
                }

                let v = if ssch.aspx_sig_delta_dir[atsg] == 0 {
                    // FREQ
                    let mut acc = 0i32;
                    for i in 0..=sbg {
                        acc += delta * ssch.aspx_data[0][atsg][i] as i32;
                    }
                    acc
                } else {
                    // TIME
                    ssch.qscf_prev[atsg][sbg] as i32 + delta * ssch.aspx_data[0][atsg][sbg] as i32
                };

                // value-range assumptions hold only for well-formed
                // streams; C stores through int8_t (truncating) which the
                // `as i8` below matches
                ssch.qscf_sig_sbg[atsg][sbg] = v as i8;
            }
        }

        Ok(())
    }

    fn get_qnoise_scale_factors(&mut self, ch: usize) {
        let delta = if (ch & 1) != 0 && self.st.substream.ssch[ch].aspx_balance == 1 {
            2
        } else {
            1
        };

        {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.qscf_noise_prev = ssch.qscf_noise_sbg;
            ssch.qscf_noise_sbg = [[0; MAX_SBG_NOISE]; MAX_ATSG_NOISE];
        }

        let ssch = &mut self.st.substream.ssch[ch];
        ssch.num_atsg_noise_prev = ssch.num_atsg_noise_prev.max(1);

        // Loop over envelopes
        for atsg in 0..ssch.num_atsg_noise as usize {
            // Loop over noise subband groups
            for sbg in 0..ssch.num_sbg_noise as usize {
                if ssch.aspx_noise_delta_dir[atsg] == 0 {
                    // FREQ (each += wraps through the i8 store)
                    for i in 0..=sbg {
                        let cur = ssch.qscf_noise_sbg[atsg][sbg] as i32;
                        ssch.qscf_noise_sbg[atsg][sbg] =
                            (cur + delta * ssch.aspx_data[1][atsg][i] as i32) as i8;
                    }
                } else {
                    // TIME
                    let base = if atsg == 0 {
                        let row = (ssch.num_atsg_noise_prev as usize - 1)
                            .min(ssch.qscf_noise_prev.len() - 1);
                        ssch.qscf_noise_prev[row][sbg] as i32
                    } else {
                        ssch.qscf_noise_sbg[atsg - 1][sbg] as i32
                    };
                    ssch.qscf_noise_sbg[atsg][sbg] =
                        (base + delta * ssch.aspx_data[1][atsg][sbg] as i32) as i8;
                }

                // range assumptions like above: int8_t store in C
            }
        }
    }

    /// `run_qmf == false` skips the QMF analysis round trip: both QMF-domain
    /// consumers (`channels_companding`, `channels_aspx_processing`) return
    /// early when `codec_mode < CM_ASPX`, so the analysis/synthesis cascade
    /// is a perfect-reconstruction identity for those streams. `q` is zeroed
    /// so the state stays defined if a later iframe switches to an A-SPX
    /// mode (the first such frame sees zero instead of the previous
    /// subbands — a one-frame HF transient at worst).
    fn prepare_channel(&mut self, ch: usize, run_qmf: bool) {
        self.spectral_reordering(ch);
        self.spectral_synthesis(ch);
        if run_qmf {
            self.qmf_analysis(ch);
        } else {
            let ssch = &mut self.st.substream.ssch[ch];
            ssch.q = [[[0.0; MAX_QMF_BANDS]; MAX_QMF_TSLOTS]; 2];
        }
    }

    fn aspx_processing(&mut self, ch: usize) {
        let nts = self.st.num_qmf_timeslots as usize;
        let tso = self.st.ts_offset_hfgen as usize;

        let ssch = &mut self.st.substream.ssch[ch];
        ssch.q_low_prev = ssch.q_low;
        ssch.q_low = [[[0.0; MAX_QMF_BANDS]; MAX_QMF_TSLOTS + 6]; 2];

        for ts in 0..tso {
            for sb in 0..MAX_QMF_BANDS {
                if (sb as i32) < ssch.sbx {
                    ssch.q_low[0][ts][sb] = ssch.q_prev[0][ts + nts - tso][sb];
                    ssch.q_low[1][ts][sb] = ssch.q_prev[1][ts + nts - tso][sb];
                }
            }
        }

        for ts in tso..nts + tso {
            for sb in 0..MAX_QMF_BANDS {
                if (sb as i32) < ssch.sbx {
                    ssch.q_low[0][ts][sb] = ssch.q[0][ts - tso][sb];
                    ssch.q_low[1][ts][sb] = ssch.q[1][ts - tso][sb];
                }
            }
        }
    }

    fn mono_deq_signal_factors(&mut self, ch: usize) {
        let ssch = &mut self.st.substream.ssch[ch];
        let a = 1.0 + (ssch.aspx_qmode_env == 0) as i32 as f32;
        let b = ssch.sbx as f32;

        ssch.scf_sig_sbg = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];

        for atsg in 0..ssch.num_atsg_sig as usize {
            let num_sbg = ssch.num_sbg_sig[ssch.atsg_freqres[atsg] as usize] as usize;
            for sbg in 0..num_sbg {
                ssch.scf_sig_sbg[atsg][sbg] =
                    b * (2.0f32).powf(ssch.qscf_sig_sbg[atsg][sbg] as f32 / a);
            }

            if ssch.aspx_sig_delta_dir[atsg] == 0
                && ssch.qscf_sig_sbg[atsg][0] == 0
                && ssch.scf_sig_sbg[atsg][1] < 0.0
            {
                ssch.scf_sig_sbg[atsg][0] = ssch.scf_sig_sbg[atsg][1];
            }
        }
    }

    fn mono_deq_noise_factors(&mut self, ch: usize) {
        const NOISE_FLOOR_OFFSET: f32 = 6.0;
        let ssch = &mut self.st.substream.ssch[ch];
        ssch.scf_noise_sbg = [[0.0; MAX_SBG_NOISE]; MAX_ATSG_NOISE];

        for atsg in 0..ssch.num_atsg_noise as usize {
            for sbg in 0..ssch.num_sbg_noise as usize {
                ssch.scf_noise_sbg[atsg][sbg] =
                    (2.0f32).powf(NOISE_FLOOR_OFFSET - ssch.qscf_noise_sbg[atsg][sbg] as f32);
            }
        }
    }

    fn joint_deq_signoise_factors(&mut self, ch0: usize, ch1: usize) {
        const PAN_OFFSET: f32 = 12.0;
        const NOISE_FLOOR_OFFSET: f32 = 6.0;
        assert!(ch0 < ch1);
        let ssch = &mut self.st.substream.ssch;
        let (l, r) = ssch.split_at_mut(ch1);
        let ssch0 = &mut l[ch0];
        let ssch1 = &mut r[0];

        let a = 1.0 + (ssch0.aspx_qmode_env == 0) as i32 as f32;
        let b = ssch0.sbx as f32;

        ssch0.scf_sig_sbg = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];
        ssch0.scf_noise_sbg = [[0.0; MAX_SBG_NOISE]; MAX_ATSG_NOISE];
        ssch1.scf_sig_sbg = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];
        ssch1.scf_noise_sbg = [[0.0; MAX_SBG_NOISE]; MAX_ATSG_NOISE];

        for atsg in 0..ssch0.num_atsg_sig as usize {
            let num_sbg = ssch0.num_sbg_sig[ssch0.atsg_freqres[atsg] as usize] as usize;
            for sbg in 0..num_sbg {
                let nom = b * (2.0f32).powf(ssch0.qscf_sig_sbg[atsg][sbg] as f32 / a + 1.0);
                let denom_a =
                    1.0 + (2.0f32).powf(PAN_OFFSET - ssch1.qscf_sig_sbg[atsg][sbg] as f32 / a);
                let denom_b =
                    1.0 + (2.0f32).powf(ssch1.qscf_sig_sbg[atsg][sbg] as f32 / a - PAN_OFFSET);

                ssch0.scf_sig_sbg[atsg][sbg] = nom / denom_a;
                ssch1.scf_sig_sbg[atsg][sbg] = nom / denom_b;
            }
        }

        for atsg in 0..ssch0.num_atsg_noise as usize {
            for sbg in 0..ssch0.num_sbg_noise as usize {
                let nom = (2.0f32)
                    .powf(NOISE_FLOOR_OFFSET - ssch0.qscf_noise_sbg[atsg][sbg] as f32 + 1.0);
                let denom_a =
                    1.0 + (2.0f32).powf(PAN_OFFSET - ssch1.qscf_noise_sbg[atsg][sbg] as f32);
                let denom_b =
                    1.0 + (2.0f32).powf(ssch1.qscf_noise_sbg[atsg][sbg] as f32 - PAN_OFFSET);

                ssch0.scf_noise_sbg[atsg][sbg] = nom / denom_a;
                ssch1.scf_noise_sbg[atsg][sbg] = nom / denom_b;
            }
        }
    }

    fn preflattening(&mut self, ch: usize) {
        let num_ts_in_ats = self.st.num_ts_in_ats;
        let ssch = &mut self.st.substream.ssch[ch];
        if ssch.sbx < 3 {
            return;
        }

        let polynomial_order = 3usize;
        let num_qmf_subbands = ssch.sbx as usize;
        let mut poly_array = [0.0f32; MAX_QMF_BANDS];
        let mut pow_env = [0.0f32; MAX_QMF_BANDS];
        let mut slope = [0.0f32; MAX_QMF_BANDS];
        let mut x = [0.0f32; MAX_QMF_BANDS];

        for (i, (xi, si)) in x.iter_mut().zip(slope.iter_mut()).enumerate() {
            *xi = i as f32;
            *si = 0.0;
        }
        // Calculate the spectral signal envelope in dB over the current interval.
        let mut mean_energy = 0.0f32;
        for sb in 0..num_qmf_subbands {
            let mut nom = 0.0f32;
            let ts0 = ssch.atsg_sig[0] as i32 * num_ts_in_ats;
            let ts1 = ssch.atsg_sig[ssch.num_atsg_sig as usize] as i32 * num_ts_in_ats;
            for ts in ts0..ts1 {
                nom += ssch.q_low[0][ts as usize][sb].powi(2);
                nom += ssch.q_low[1][ts as usize][sb].powi(2);
            }
            let denom = (ssch.atsg_sig[ssch.num_atsg_sig as usize] as i32 - ssch.atsg_sig[0] as i32)
                as f32
                * num_ts_in_ats as f32;
            pow_env[sb] = nom / denom;
            pow_env[sb] = 10.0 * (pow_env[sb] + 1.0).log10();
            mean_energy += pow_env[sb];
        }

        mean_energy /= num_qmf_subbands as f32;
        // C ignores polyfit's return value; on bad input it leaves the
        // partially reduced coefficients in place, and so do we
        let _ = polyfit(
            polynomial_order,
            num_qmf_subbands as i32,
            &x,
            &pow_env,
            &mut poly_array,
        );

        // Transform polynomial into slope
        for k in (0..=polynomial_order).rev() {
            for sb in 0..num_qmf_subbands {
                slope[sb] += x[sb].powi(k as i32) * poly_array[k];
            }
        }

        // Derive a gain vector from the slope (bounded: corrupt streams can
        // report more subbands than the gain vector holds)
        for sb in 0..num_qmf_subbands.min(ssch.gain_vec.len()) {
            ssch.gain_vec[sb] = (10.0f32).powf((mean_energy - slope[sb]) / 20.0);
        }
    }

    fn get_chirps(&mut self, ch: usize) {
        let ssch = &mut self.st.substream.ssch[ch];
        ssch.chirp_arr_prev = ssch.chirp_arr;

        for sbg in 0..ssch.num_sbg_noise as usize {
            let mut new_chirp = NEW_CHIRP_TAB[ssch.aspx_tna_mode[sbg] as usize]
                [ssch.aspx_tna_mode_prev[sbg] as usize];

            debug_assert!(ssch.aspx_tna_mode[sbg] <= 3);
            debug_assert!(ssch.aspx_tna_mode_prev[sbg] <= 3);
            if new_chirp < ssch.chirp_arr_prev[sbg] {
                new_chirp = 0.75000 * new_chirp + 0.25000 * ssch.chirp_arr_prev[sbg];
            } else {
                new_chirp = 0.90625 * new_chirp + 0.09375 * ssch.chirp_arr_prev[sbg];
            }

            if new_chirp < 0.015625 {
                ssch.chirp_arr[sbg] = 0.0;
            } else {
                ssch.chirp_arr[sbg] = new_chirp;
            }
        }
    }

    fn get_covariance(&mut self, ch: usize) {
        const TS_OFFSET_HFADJ: usize = 4;
        let nts = self.st.num_qmf_timeslots as usize;
        let tso = self.st.ts_offset_hfgen as usize;
        let ssch = &mut self.st.substream.ssch[ch];
        let num_ts_ext = nts + tso + TS_OFFSET_HFADJ;

        // Create an additional delay of TS_OFFSET_HFADJ QMF time slots
        let ts_offset_prev = nts - TS_OFFSET_HFADJ;
        for sb in 0..ssch.sba as usize {
            for ts in 0..TS_OFFSET_HFADJ {
                ssch.q_low_ext[0][ts][sb] = ssch.q_low_prev[0][ts + ts_offset_prev][sb];
                ssch.q_low_ext[1][ts][sb] = ssch.q_low_prev[1][ts + ts_offset_prev][sb];
            }
            for ts in 0..nts + tso {
                ssch.q_low_ext[0][ts + TS_OFFSET_HFADJ][sb] = ssch.q_low[0][ts][sb];
                ssch.q_low_ext[1][ts + TS_OFFSET_HFADJ][sb] = ssch.q_low[1][ts][sb];
            }
        }

        // Loop over QMF subbands
        for sb in 0..ssch.sba as usize {
            for i in 0..3 {
                for j in 1..3 {
                    ssch.cov[sb][i][j][0] = 0.0;
                    ssch.cov[sb][i][j][1] = 0.0;
                    // Loop over QMF time slots
                    let mut ts = TS_OFFSET_HFADJ;
                    while ts < num_ts_ext {
                        let (re, im) = fcomplex_mul(
                            ssch.q_low_ext[0][ts - 2 * i][sb],
                            ssch.q_low_ext[1][ts - 2 * i][sb],
                            ssch.q_low_ext[0][ts - 2 * j][sb],
                            -ssch.q_low_ext[1][ts - 2 * j][sb],
                        );
                        ssch.cov[sb][i][j][0] += re;
                        ssch.cov[sb][i][j][1] += im;
                        ts += 2;
                    }
                }
            }
        }
    }

    fn get_alphas(&mut self, ch: usize) {
        let epsilon_inv = (1.0f64 * 2f64.powi(-20)) as f32;
        let ssch = &mut self.st.substream.ssch[ch];

        for sb in 0..ssch.sba as usize {
            let (mut dr, di) = fcomplex_mul(
                ssch.cov[sb][2][2][0],
                ssch.cov[sb][2][2][1],
                ssch.cov[sb][1][1][0],
                ssch.cov[sb][1][1][1],
            );
            dr -= sqr(ssch.cov[sb][1][2][0], ssch.cov[sb][1][2][1]) / (1.0 + epsilon_inv);
            if sqr(dr, di) <= 1e-6 {
                ssch.alpha1[sb][0] = 0.0;
                ssch.alpha1[sb][1] = 0.0;
            } else {
                let (a, bi) = fcomplex_mul(
                    ssch.cov[sb][0][1][0],
                    ssch.cov[sb][0][1][1],
                    ssch.cov[sb][1][2][0],
                    ssch.cov[sb][1][2][1],
                );
                let (c, di2) = fcomplex_mul(
                    ssch.cov[sb][0][2][0],
                    ssch.cov[sb][0][2][1],
                    ssch.cov[sb][1][1][0],
                    ssch.cov[sb][1][1][1],
                );
                let (r, i) = fcomplex_div(a - c, bi - di2, dr, di);
                ssch.alpha1[sb][0] = r;
                ssch.alpha1[sb][1] = i;
            }

            if sqr(ssch.cov[sb][1][1][0], ssch.cov[sb][1][1][1]) <= 1e-6 {
                ssch.alpha0[sb][0] = 0.0;
                ssch.alpha0[sb][1] = 0.0;
            } else {
                let (a, bi) = fcomplex_mul(
                    ssch.alpha1[sb][0],
                    ssch.alpha1[sb][1],
                    ssch.cov[sb][1][2][0],
                    -ssch.cov[sb][1][2][1],
                );
                let (r, i) = fcomplex_div(
                    -ssch.cov[sb][0][1][0] + a,
                    -ssch.cov[sb][0][1][1] + bi,
                    ssch.cov[sb][1][1][0],
                    ssch.cov[sb][1][1][1],
                );
                ssch.alpha0[sb][0] = r;
                ssch.alpha0[sb][1] = i;
            }

            if sqr(ssch.alpha0[sb][0], ssch.alpha0[sb][1]) >= 16.0
                || sqr(ssch.alpha1[sb][0], ssch.alpha1[sb][1]) >= 16.0
            {
                ssch.alpha0[sb][0] = 0.0;
                ssch.alpha0[sb][1] = 0.0;
                ssch.alpha1[sb][0] = 0.0;
                ssch.alpha1[sb][1] = 0.0;
            }
        }
    }

    fn create_high_signal(&mut self, ch: usize) {
        const TS_OFFSET_HFADJ: i32 = 4;
        let num_ts_in_ats = self.st.num_ts_in_ats;
        let ssch = &mut self.st.substream.ssch[ch];

        // Loop over QMF time slots
        let ts0 = ssch.atsg_sig[0] as i32 * num_ts_in_ats;
        let ts1 = ssch.atsg_sig[ssch.num_atsg_sig as usize] as i32 * num_ts_in_ats;
        for ts in ts0..ts1 {
            let mut sum_sb_patches = 0i32;
            let mut g = 0usize;
            // Loop over number of patches (min(): the cursor can exceed the
            // table on corrupt streams)
            for i in 0..(ssch.num_sbg_patches as usize).min(ssch.sbg_patch_num_sb.len()) {
                // Loop over number of subbands per patch
                for sb in 0..ssch.sbg_patch_num_sb[i] {
                    // Map to High QMF Subband
                    let sb_high = ssch.sbx + sum_sb_patches + sb;

                    // Map to current noise envelope (get(): corrupt streams
                    // can walk g past the noise boundary table)
                    let next_noise_b = ssch.sbg_noise.get(g + 1).copied().unwrap_or(i32::MIN);
                    if next_noise_b == sb_high {
                        g += 1;
                    }

                    let n = ts + TS_OFFSET_HFADJ;
                    // Current low QMF Subband (clamped: corrupt streams can
                    // push both the patch origin and the high-band target
                    // outside the QMF buffers; C would index out of bounds)
                    let p = (ssch.sbg_patch_start_sb[i] + sb).clamp(0, MAX_QMF_BANDS as i32 - 1)
                        as usize;
                    let sb_high =
                        (ssch.sbx + sum_sb_patches + sb).clamp(0, MAX_QMF_BANDS as i32 - 1);

                    let (re, im) = (
                        ssch.q_low_ext[0][n as usize][p],
                        ssch.q_low_ext[1][n as usize][p],
                    );
                    ssch.q_high[0][ts as usize][sb_high as usize] = re;
                    ssch.q_high[1][ts as usize][sb_high as usize] = im;

                    let (cr, ci) = fcomplex_mul(
                        ssch.alpha0[p][0],
                        ssch.alpha0[p][1],
                        ssch.q_low_ext[0][(n - 2) as usize][p],
                        ssch.q_low_ext[1][(n - 2) as usize][p],
                    );
                    ssch.q_high[0][ts as usize][sb_high as usize] += cr * ssch.chirp_arr[g];
                    ssch.q_high[1][ts as usize][sb_high as usize] += ci * ssch.chirp_arr[g];

                    let (cr, ci) = fcomplex_mul(
                        ssch.alpha1[p][0],
                        ssch.alpha1[p][1],
                        ssch.q_low_ext[0][(n - 4) as usize][p],
                        ssch.q_low_ext[1][(n - 4) as usize][p],
                    );
                    let m = ssch.chirp_arr[g].powi(2);
                    ssch.q_high[0][ts as usize][sb_high as usize] += cr * m;
                    ssch.q_high[1][ts as usize][sb_high as usize] += ci * m;

                    if self.st.substream.aspx_preflat != 0 {
                        let m = 1.0 / ssch.gain_vec[p];
                        ssch.q_high[0][ts as usize][sb_high as usize] *= m;
                        ssch.q_high[1][ts as usize][sb_high as usize] *= m;
                    }
                }
                sum_sb_patches += ssch.sbg_patch_num_sb[i];
            }
        }
    }

    fn estimate_spectral_envelopes(&mut self, ch: usize) {
        const TS_OFFSET_HFADJ: i32 = 4;
        let num_ts_in_ats = self.st.num_ts_in_ats;
        let ssch = &mut self.st.substream.ssch[ch];

        for atsg in 0..ssch.num_atsg_sig as usize {
            // Loop over QMF subbands in A-SPX range
            let mut sbg = 0usize;
            for sb in 0..ssch.num_sb_aspx as usize {
                let mut est_sig = 0.0f32;
                // Update current subband group (get(): corrupt streams can
                // run sbg past the table; no match means no advancement)
                let next_lim = ssch.sbg_sig[ssch.atsg_freqres[atsg] as usize]
                    .get(sbg + 1)
                    .copied()
                    .unwrap_or(i32::MIN);
                if sb as i32 == next_lim {
                    sbg += 1;
                }

                // clamp: corrupt streams can push the envelope timeslots far
                // outside the QMF history buffers (C: OOB access)
                let tsa = (ssch.atsg_sig[atsg] as i32 * num_ts_in_ats + TS_OFFSET_HFADJ)
                    .clamp(0, (MAX_QMF_TSLOTS + 4) as i32);
                let tsz = (ssch.atsg_sig[atsg + 1] as i32 * num_ts_in_ats + TS_OFFSET_HFADJ)
                    .clamp(0, (MAX_QMF_TSLOTS + 4) as i32);
                for ts in tsa..tsz {
                    if self.st.substream.aspx_interpolation == 0 {
                        let lo = ssch.sbg_sig[ssch.atsg_freqres[atsg] as usize][sbg];
                        let hi = ssch.sbg_sig[ssch.atsg_freqres[atsg] as usize][sbg + 1];
                        let lo = lo.clamp(0, MAX_QMF_BANDS as i32);
                        let hi = hi.clamp(0, MAX_QMF_BANDS as i32);
                        for j in lo..hi {
                            est_sig += sqr(
                                ssch.q_high[0][ts as usize][j as usize],
                                ssch.q_high[1][ts as usize][j as usize],
                            );
                        }
                    } else {
                        est_sig += sqr(
                            ssch.q_high[0][ts as usize][sb + ssch.sbx as usize],
                            ssch.q_high[1][ts as usize][sb + ssch.sbx as usize],
                        );
                    }
                }

                // i32 difference: C subtracts uint8_t values in int domain,
                // so a corrupt stream can produce a negative count here
                let env_len = (ssch.atsg_sig[atsg + 1] as i32 - ssch.atsg_sig[atsg] as i32) as f32;
                if self.st.substream.aspx_interpolation == 0 {
                    let lo = ssch.sbg_sig[ssch.atsg_freqres[atsg] as usize][sbg];
                    let hi = ssch.sbg_sig[ssch.atsg_freqres[atsg] as usize][sbg + 1];
                    est_sig /= (hi - lo) as f32;
                    est_sig /= env_len;
                } else {
                    est_sig /= env_len;
                }
                ssch.est_sig_sb[atsg][sb] = est_sig;
            }
        }
    }

    fn map_signoise(&mut self, ch: usize) {
        let ssch = &mut self.st.substream.ssch[ch];
        let mut atsg_noise = 0usize;

        ssch.scf_noise_sb = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];
        ssch.scf_sig_sb = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];

        // Loop over Signal Envelopes
        for atsg in 0..ssch.num_atsg_sig as usize {
            let fr = ssch.atsg_freqres[atsg] as usize;
            // Map Signal Envelopes from subband groups to QMF subbands
            // (clamped: corrupt streams can push lo/hi outside the subband
            // domain, where C would index out of bounds)
            for sbg in 0..ssch.num_sbg_sig[fr] as usize {
                let lo = (ssch.sbg_sig[fr][sbg] - ssch.sbx).clamp(0, MAX_QMF_BANDS as i32);
                let hi = (ssch.sbg_sig[fr][sbg + 1] - ssch.sbx).clamp(0, MAX_QMF_BANDS as i32);
                for sb in lo..hi {
                    ssch.scf_sig_sb[atsg][sb as usize] = ssch.scf_sig_sbg[atsg][sbg];
                }
            }

            // cap the walk: corrupt streams can keep matching past the
            // noise-envelope table (C would index past it)
            let next_noise = ssch
                .atsg_noise
                .get(atsg_noise + 1)
                .copied()
                .unwrap_or(u8::MAX);
            if atsg_noise + 1 < ssch.scf_noise_sbg.len() && ssch.atsg_sig[atsg] == next_noise {
                atsg_noise += 1;
            }

            debug_assert!(atsg_noise < ssch.scf_noise_sbg.len());
            // Map Noise Floors from subband groups to QMF subbands (clamped
            // as above; min(): corrupt streams can report more noise groups
            // than the boundary table holds)
            for sbg in 0..(ssch.num_sbg_noise as usize).min(ssch.sbg_noise.len() - 1) {
                let lo = (ssch.sbg_noise[sbg] - ssch.sbx).clamp(0, MAX_QMF_BANDS as i32);
                let hi = (ssch.sbg_noise.get(sbg + 1).copied().unwrap_or(i32::MAX) - ssch.sbx)
                    .clamp(0, MAX_QMF_BANDS as i32);
                for sb in lo..hi {
                    ssch.scf_noise_sb[atsg][sb as usize] = ssch.scf_noise_sbg[atsg_noise][sbg];
                }
            }
        }
    }

    fn add_sinusoids(&mut self, ch: usize) {
        let ssch = &mut self.st.substream.ssch[ch];
        let epsilon = 1.0f32;
        let lim_gain = 1.41254f32;
        let epsilon0 = (10.0f32).powi(-12);
        let max_sig_gain = (10.0f32).powi(5);
        let max_boost_fact = 1.584_893_2_f32;

        let p_sine_at_end = if ssch.aspx_tsg_ptr_prev == ssch.num_atsg_sig_prev {
            0
        } else {
            -1
        };

        ssch.sine_idx_sb_prev = ssch.sine_idx_sb;
        ssch.sine_idx_sb = [[0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];

        // Loop over envelopes
        for atsg in 0..ssch.num_atsg_sig as usize {
            // Loop over high resolution signal envelope subband groups
            for sbg in 0..ssch.num_sbg_sig_highres as usize {
                let sba = ssch.sbg_sig_highres[sbg] - ssch.sbx;
                let sbz = ssch.sbg_sig_highres[sbg + 1] - ssch.sbx;
                let sb_mid = (0.5f32 * (sbz + sba) as f32) as i32;
                // Map sinusoid markers to QMF subbands (clamped for corrupt
                // streams)
                let sba = sba.clamp(0, MAX_QMF_BANDS as i32);
                let sbz = sbz.clamp(0, MAX_QMF_BANDS as i32);
                for sb in sba..sbz {
                    // num_atsg_sig_prev == 0 (never-framed balance channel)
                    // reads sine_idx_sb_prev[-1] in C (UB); index [0] instead.
                    let prev_row = (ssch.num_atsg_sig_prev.max(1) - 1) as usize;
                    if sb == sb_mid
                        && (atsg as i32 >= ssch.aspx_tsg_ptr
                            || p_sine_at_end == 0
                            || ssch.sine_idx_sb_prev[prev_row][sb as usize] != 0)
                    {
                        ssch.sine_idx_sb[atsg][sb as usize] = ssch.aspx_add_harmonic[sbg];
                    }
                }
            }
        }

        ssch.sine_area_sb = [[0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];

        for atsg in 0..ssch.num_atsg_sig as usize {
            let fr = ssch.atsg_freqres[atsg] as usize;
            for sbg in 0..ssch.num_sbg_sig[fr] as usize {
                let mut sine_present = 0u8;
                // Corrupt streams can push these past the subband domain
                // (negative or > MAX_QMF_BANDS); C would index out of bounds
                let lo = (ssch.sbg_sig[fr][sbg] - ssch.sbx).clamp(0, MAX_QMF_BANDS as i32);
                let hi = (ssch.sbg_sig[fr][sbg + 1] - ssch.sbx).clamp(0, MAX_QMF_BANDS as i32);
                // Additional sinusoid present in SF band?
                for sb in lo..hi {
                    if ssch.sine_idx_sb[atsg][sb as usize] == 1 {
                        sine_present = 1;
                    }
                }
                // Mark all subbands in current subband group accordingly
                for sb in lo..hi {
                    ssch.sine_area_sb[atsg][sb as usize] = sine_present;
                }
            }
        }

        ssch.sine_lev_sb = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];
        ssch.noise_lev_sb = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];

        for atsg in 0..ssch.num_atsg_sig as usize {
            for sb in 0..ssch.num_sb_aspx as usize {
                let sig_noise_fact =
                    ssch.scf_sig_sb[atsg][sb] / (1.0 + ssch.scf_noise_sb[atsg][sb]);
                ssch.sine_lev_sb[atsg][sb] =
                    (ssch.sine_idx_sb[atsg][sb] as f32 * sig_noise_fact).sqrt();
                ssch.noise_lev_sb[atsg][sb] = ssch.scf_sig_sb[atsg][sb].sqrt();
            }
        }

        ssch.sig_gain_sb = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];

        for atsg in 0..ssch.num_atsg_sig as usize {
            for sb in 0..ssch.num_sb_aspx as usize {
                if ssch.sine_area_sb[atsg][sb] == 0 {
                    let mut denom = epsilon + ssch.est_sig_sb[atsg][sb];
                    if !(atsg as i32 == ssch.aspx_tsg_ptr || atsg as i32 == p_sine_at_end) {
                        denom *= 1.0 + ssch.scf_noise_sb[atsg][sb];
                    }
                    ssch.sig_gain_sb[atsg][sb] = (ssch.scf_sig_sb[atsg][sb] / denom).sqrt();
                } else {
                    let mut denom = epsilon + ssch.est_sig_sb[atsg][sb];
                    denom *= 1.0 + ssch.scf_noise_sb[atsg][sb];
                    ssch.sig_gain_sb[atsg][sb] =
                        (ssch.scf_sig_sb[atsg][sb] * ssch.scf_noise_sb[atsg][sb] / denom).sqrt();
                }
            }
        }

        ssch.max_sig_gain_sbg = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];
        ssch.max_sig_gain_sb = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];

        for atsg in 0..ssch.num_atsg_sig as usize {
            // Loop over limiter subband groups (min()+clamp: corrupt streams
            // can overrun the boundary table / subband domain)
            for sbg in 0..(ssch.num_sbg_lim as usize).min(ssch.sbg_lim.len()) {
                let mut denom = epsilon0;
                let mut nom = 0.0f32;
                let lo = (ssch.sbg_lim[sbg] - ssch.sbx).clamp(0, MAX_QMF_BANDS as i32);
                let hi = (ssch.sbg_lim.get(sbg + 1).copied().unwrap_or(i32::MAX) - 1 - ssch.sbx)
                    .clamp(0, MAX_QMF_BANDS as i32);
                for sb in lo..hi {
                    nom += ssch.scf_sig_sb[atsg][sb as usize];
                    denom += ssch.est_sig_sb[atsg][sb as usize];
                }
                ssch.max_sig_gain_sbg[atsg][sbg] = (nom / denom).sqrt() * lim_gain;
            }

            // Map to QMF subbands
            let mut sbg = 0usize;
            for sb in 0..ssch.num_sb_aspx as usize {
                // get(): corrupt streams can run sbg past the last group;
                // a value that never matches stops group advancement, which
                // is what the well-formed case does at the end anyway.
                let next_lim = ssch.sbg_lim.get(sbg + 1).copied().unwrap_or(i32::MIN);
                if sb as i32 == next_lim - ssch.sbx {
                    sbg += 1;
                }
                ssch.max_sig_gain_sb[atsg][sb] = ssch.max_sig_gain_sbg[atsg][sbg].min(max_sig_gain);
            }
        }

        ssch.noise_lev_sb_lim = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];

        for atsg in 0..ssch.num_atsg_sig as usize {
            for sb in 0..ssch.num_sb_aspx as usize {
                let mut tmp = ssch.noise_lev_sb[atsg][sb];
                tmp *= ssch.max_sig_gain_sb[atsg][sb] / ssch.sig_gain_sb[atsg][sb];
                ssch.noise_lev_sb_lim[atsg][sb] = ssch.noise_lev_sb[atsg][sb].min(tmp);
            }
        }

        for atsg in 0..ssch.num_atsg_sig as usize {
            for sb in 0..ssch.num_sb_aspx as usize {
                ssch.sig_gain_sb_lim[atsg][sb] =
                    ssch.sig_gain_sb[atsg][sb].min(ssch.max_sig_gain_sb[atsg][sb]);
            }
        }

        ssch.boost_fact_sbg = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];

        for atsg in 0..ssch.num_atsg_sig as usize {
            // same guards as the first limiter loop
            for sbg in 0..(ssch.num_sbg_lim as usize).min(ssch.sbg_lim.len()) {
                let mut denom = epsilon0;
                let mut nom = 0.0f32;
                let lo = (ssch.sbg_lim[sbg] - ssch.sbx).clamp(0, MAX_QMF_BANDS as i32);
                let hi = (ssch.sbg_lim.get(sbg + 1).copied().unwrap_or(i32::MAX) - 1 - ssch.sbx)
                    .clamp(0, MAX_QMF_BANDS as i32);
                for sb in lo..hi {
                    nom += ssch.scf_sig_sb[atsg][sb as usize];
                    denom += ssch.est_sig_sb[atsg][sb as usize]
                        * ssch.sig_gain_sb_lim[atsg][sb as usize].powi(2);
                    denom += ssch.sine_lev_sb[atsg][sb as usize].powi(2);
                    if !((ssch.sine_lev_sb[atsg][sb as usize] != 0.0)
                        || (atsg as i32 == ssch.aspx_tsg_ptr)
                        || (atsg as i32 == p_sine_at_end))
                    {
                        denom += ssch.noise_lev_sb_lim[atsg][sb as usize].powi(2);
                    }
                }
                ssch.boost_fact_sbg[atsg][sbg] = (nom / denom).sqrt();
            }
        }

        ssch.boost_fact_sb = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];

        for atsg in 0..ssch.num_atsg_sig as usize {
            let mut sbg = 0usize;
            for sb in 0..ssch.num_sb_aspx as usize {
                let next_lim = ssch.sbg_lim.get(sbg + 1).copied().unwrap_or(i32::MIN);
                if sb as i32 == next_lim - ssch.sbx {
                    sbg += 1;
                }
                let sbg = sbg.min(ssch.boost_fact_sbg[atsg].len() - 1);
                ssch.boost_fact_sb[atsg][sb] = ssch.boost_fact_sbg[atsg][sbg].min(max_boost_fact);
            }
        }

        ssch.noise_lev_sb_adj = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];
        ssch.sine_lev_sb_adj = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];
        ssch.sig_gain_sb_adj = [[0.0; MAX_QMF_BANDS]; MAX_ASPX_SIGNAL];

        for atsg in 0..ssch.num_atsg_sig as usize {
            for sb in 0..ssch.num_sb_aspx as usize {
                let boost_fact = ssch.boost_fact_sb[atsg][sb];
                ssch.sig_gain_sb_adj[atsg][sb] = ssch.sig_gain_sb_lim[atsg][sb] * boost_fact;
                ssch.noise_lev_sb_adj[atsg][sb] = ssch.noise_lev_sb_lim[atsg][sb] * boost_fact;
                ssch.sine_lev_sb_adj[atsg][sb] = ssch.sine_lev_sb[atsg][sb] * boost_fact;
            }
        }
    }

    fn generate_noise(&mut self, ch: usize) {
        let num_ts_in_ats = self.st.num_ts_in_ats;
        let ssch = &mut self.st.substream.ssch[ch];

        ssch.qmf_noise = [[[0.0; MAX_QMF_BANDS]; MAX_QMF_TSLOTS]; 2];

        // Loop over QMF time slots
        let ts0 = ssch.atsg_sig[0] as i32 * num_ts_in_ats;
        let ts1 = ssch.atsg_sig[ssch.num_atsg_sig as usize] as i32 * num_ts_in_ats;
        let mut atsg = 0usize;
        for ts in ts0..ts1 {
            // get()+cap: see generate_tones
            let next_bord =
                ssch.atsg_sig.get(atsg + 1).copied().unwrap_or(u8::MAX) as i32 * num_ts_in_ats;
            if ts == next_bord {
                atsg += 1;
            }
            // Loop over QMF subbands in A-SPX
            for sb in 0..ssch.num_sb_aspx as usize {
                let idx = noise_idx(sb, ts as usize, ssch);
                ssch.noise_idx_prev[ts as usize][sb] = idx as i16;

                ssch.qmf_noise[0][ts as usize][sb] =
                    ssch.noise_lev_sb_adj[atsg][sb] * ASPX_NOISE[idx][0];
                ssch.qmf_noise[1][ts as usize][sb] =
                    ssch.noise_lev_sb_adj[atsg][sb] * ASPX_NOISE[idx][1];
            }
        }
    }

    fn generate_tones(&mut self, ch: usize) {
        let num_ts_in_ats = self.st.num_ts_in_ats;
        let first_frame = self.st.first_frame;
        let ssch = &mut self.st.substream.ssch[ch];

        ssch.qmf_sine = [[[0.0; MAX_QMF_BANDS]; MAX_QMF_TSLOTS]; 2];

        let ts0 = ssch.atsg_sig[0] as i32 * num_ts_in_ats;
        let ts1 = ssch.atsg_sig[ssch.num_atsg_sig as usize] as i32 * num_ts_in_ats;
        let mut atsg = 0usize;
        for ts in ts0..ts1 {
            // get()+cap: corrupt streams can keep matching boundaries and
            // walk atsg past the signal table (C would index out of bounds)
            let next_bord =
                ssch.atsg_sig.get(atsg + 1).copied().unwrap_or(u8::MAX) as i32 * num_ts_in_ats;
            if ts == next_bord {
                atsg += 1;
            }

            // Loop over QMF subbands in A-SPX
            for sb in 0..ssch.num_sb_aspx as usize {
                let idx = sine_idx(sb, ts as usize, first_frame, ssch);
                ssch.sine_idx_prev[ts as usize][sb] = idx as i8;

                // C: powf(-1, sb + ssch->sbx)
                let sign = if (sb as i32 + ssch.sbx) & 1 != 0 {
                    -1.0f32
                } else {
                    1.0
                };
                ssch.qmf_sine[0][ts as usize][sb] = ssch.sine_lev_sb_adj[atsg][sb];
                ssch.qmf_sine[0][ts as usize][sb] *= ASPX_SINE[0][idx] as f32;
                ssch.qmf_sine[1][ts as usize][sb] = ssch.sine_lev_sb_adj[atsg][sb] * sign;
                ssch.qmf_sine[1][ts as usize][sb] *= ASPX_SINE[1][idx] as f32;
            }
        }
    }

    fn assemble_hf_signal(&mut self, ch: usize) {
        let num_ts_in_ats = self.st.num_ts_in_ats;
        const TS_OFFSET_HFADJ: usize = 4;
        let ssch = &mut self.st.substream.ssch[ch];
        let sbx = ssch.sbx;

        ssch.y_prev = ssch.y;
        ssch.y = [[[0.0; MAX_QMF_BANDS]; MAX_QMF_TSLOTS]; 2];

        // Get delayed QMF subsamples from delay buffer (clamped: corrupt
        // streams can push envelope boundaries far past the QMF history;
        // C would index out of bounds)
        let ts_max = MAX_QMF_TSLOTS as i32;
        let ts0 = (ssch.atsg_sig[0] as i32 * num_ts_in_ats).clamp(0, ts_max);
        for ts in 0..ts0 as usize {
            for sb in 0..ssch.num_sb_aspx as usize {
                ssch.y[0][ts][sb] = ssch.y_prev[0][ts][sb];
                ssch.y[1][ts][sb] = ssch.y_prev[1][ts][sb];
            }
        }

        // Loop over QMF time slots
        let ts1 =
            (ssch.atsg_sig[ssch.num_atsg_sig as usize] as i32 * num_ts_in_ats).clamp(ts0, ts_max);
        let mut atsg = 0usize;
        for ts in ts0..ts1 {
            let next_bord =
                ssch.atsg_sig.get(atsg + 1).copied().unwrap_or(u8::MAX) as i32 * num_ts_in_ats;
            if ts == next_bord {
                atsg += 1;
            }
            for sb in 0..ssch.num_sb_aspx as usize {
                let (gr, gi) = (
                    ssch.sig_gain_sb_adj[atsg][sb],
                    ssch.sig_gain_sb_adj[atsg][sb],
                );
                let (r, i) = fcomplex_mul(
                    gr,
                    gi,
                    ssch.q_high[0][(ts as usize) + TS_OFFSET_HFADJ][sb + sbx as usize],
                    ssch.q_high[1][(ts as usize) + TS_OFFSET_HFADJ][sb + sbx as usize],
                );
                ssch.y[0][ts as usize][sb] = r;
                ssch.y[1][ts as usize][sb] = i;
            }
        }

        // Loop over time slots
        for ts in ts0..ts1 {
            for sb in 0..ssch.num_sb_aspx as usize {
                ssch.y[0][ts as usize][sb] += ssch.qmf_sine[0][ts as usize][sb];
                ssch.y[1][ts as usize][sb] += ssch.qmf_sine[1][ts as usize][sb];
                ssch.y[0][ts as usize][sb] += ssch.qmf_noise[0][ts as usize][sb];
                ssch.y[1][ts as usize][sb] += ssch.qmf_noise[1][ts as usize][sb];
            }
        }

        ssch.q_prev = ssch.q;

        for ts in 0..ts1 as usize {
            let tic = ssch
                .aspx_tic_used_in_slot
                .get(ts / num_ts_in_ats as usize)
                .copied()
                .unwrap_or(0);
            if tic != 0 {
                for sb in 0..ssch.num_sb_aspx as usize {
                    ssch.q[0][ts][(sbx + sb as i32) as usize] =
                        ssch.q_prev[0][ts][(sbx + sb as i32) as usize];
                    ssch.q[1][ts][(sbx + sb as i32) as usize] =
                        ssch.q_prev[1][ts][(sbx + sb as i32) as usize];
                }
            } else {
                for sb in 0..ssch.num_sb_aspx as usize {
                    ssch.q[0][ts][(sbx + sb as i32) as usize] =
                        ssch.q_prev[0][ts][(sbx + sb as i32) as usize];
                    ssch.q[1][ts][(sbx + sb as i32) as usize] =
                        ssch.q_prev[1][ts][(sbx + sb as i32) as usize];

                    ssch.q[0][ts][(sbx + sb as i32) as usize] += ssch.y_prev[0][ts][sb] / 32768.0;
                    ssch.q[1][ts][(sbx + sb as i32) as usize] += ssch.y_prev[1][ts][sb] / 32768.0;
                }
            }
        }
    }

    fn channels_aspx_processing(&mut self, nb_ch: usize) -> Result<()> {
        if self.st.substream.codec_mode < enums::CM_ASPX {
            return Ok(());
        }

        for ch in 0..nb_ch {
            self.aspx_processing(ch);
        }
        for ch in 0..nb_ch {
            // C ignores these return values (bare calls); a channel whose
            // A-SPX state was never framed (balance-only stereo pairs) has
            // no envelope history and its HF reconstruction degrades to a
            // best-effort output instead of failing the frame.
            let _ = self.get_qsignal_scale_factors(ch);
        }
        for ch in 0..nb_ch {
            self.get_qnoise_scale_factors(ch);
        }

        for ch in 0..nb_ch {
            if self.st.substream.ssch[ch].aspx_balance == 0 {
                self.mono_deq_signal_factors(ch);
            }
        }

        for ch in 0..nb_ch {
            if self.st.substream.ssch[ch].aspx_balance == 0 {
                self.mono_deq_noise_factors(ch);
            }
        }

        let mut ch = 0usize;
        while ch < nb_ch {
            if self.st.substream.ssch[ch].aspx_balance != 0 {
                self.joint_deq_signoise_factors(ch, ch + 1);
                ch += 1;
            }
            ch += 1;
        }

        for ch in 0..nb_ch {
            self.preflattening(ch);
        }
        for ch in 0..nb_ch {
            self.get_covariance(ch);
        }
        for ch in 0..nb_ch {
            self.get_alphas(ch);
        }
        for ch in 0..nb_ch {
            self.get_chirps(ch);
        }
        for ch in 0..nb_ch {
            self.create_high_signal(ch);
        }
        for ch in 0..nb_ch {
            self.estimate_spectral_envelopes(ch);
        }
        for ch in 0..nb_ch {
            self.map_signoise(ch);
        }
        for ch in 0..nb_ch {
            self.add_sinusoids(ch);
        }
        for ch in 0..nb_ch {
            self.generate_tones(ch);
        }
        for ch in 0..nb_ch {
            self.generate_noise(ch);
        }
        for ch in 0..nb_ch {
            self.assemble_hf_signal(ch);
        }

        Ok(())
    }

    fn channel_companding(&mut self, ch: usize) {
        let num_ts_in_ats = self.st.num_ts_in_ats;
        let ssch = &mut self.st.substream.ssch[ch];
        let ts1 = ssch.atsg_sig[ssch.aspx_num_env as usize] as i32 * num_ts_in_ats;
        let ts0 = ssch.atsg_sig[0] as i32 * num_ts_in_ats;
        let sb0 = 0i32;
        let sb1 = ssch.sbx;
        let k = sb1 - sb0;
        let d = ts1 - ts0;
        let a = 0.65f32;
        let g = (0.5f32).powf(-1.0 / a);

        for ts in ts0..ts1 {
            let mut sum = 0.0f32;
            for sb in sb0..sb1 {
                let re = ssch.q[0][ts as usize][sb as usize].abs();
                let im = ssch.q[1][ts as usize][sb as usize].abs();

                ssch.e[ts as usize][sb as usize] = re.max(im) + 0.5 * re.min(im);
                sum += ssch.e[ts as usize][sb as usize];
            }

            ssch.l_[ts as usize] = sum * 0.9105 / k as f32;
            ssch.g[ts as usize] = ssch.l_[ts as usize].powf((1.0 - a) / a);
            self.st.substream.g_sum[ts as usize] += ssch.g[ts as usize];
        }

        if self.st.substream.sync_flag == 0 {
            if self.st.substream.compand_on[ch] != 0 {
                for ts in ts0..ts1 {
                    let factor = g * ssch.g[ts as usize];
                    for sb in sb0..sb1 {
                        ssch.q[0][ts as usize][sb as usize] *= factor;
                        ssch.q[1][ts as usize][sb as usize] *= factor;
                    }
                }
            } else if self.st.substream.compand_avg != 0 {
                let mut sum = 0.0f32;
                for ts in ts0..ts1 {
                    sum += ssch.l_[ts as usize];
                }
                let factor = g * (sum / d as f32).powf((1.0 - a) / a);
                for ts in ts0..ts1 {
                    for sb in sb0..sb1 {
                        ssch.q[0][ts as usize][sb as usize] *= factor;
                        ssch.q[1][ts as usize][sb as usize] *= factor;
                    }
                }
            }
        }
    }

    fn channels_companding(&mut self, nb_ch: usize) {
        if self.st.substream.codec_mode < enums::CM_ASPX {
            return;
        }

        self.st.substream.g_sum = [0.0; MAX_QMF_TSLOTS];

        for ch in 0..nb_ch {
            self.channel_companding(ch);
        }

        if self.st.substream.sync_flag != 0 {
            let num_ts_in_ats = self.st.num_ts_in_ats;
            let a = 0.65f32;
            let g = (0.5f32).powf(-1.0 / a);

            for ch in 0..nb_ch {
                let (ts1, ts0, sb0, sb1) = {
                    let ssch = &self.st.substream.ssch[ch];
                    (
                        ssch.atsg_sig[ssch.aspx_num_env as usize] as i32 * num_ts_in_ats,
                        ssch.atsg_sig[0] as i32 * num_ts_in_ats,
                        0i32,
                        ssch.sbx,
                    )
                };
                let ssch = &mut self.st.substream.ssch[ch];

                if self.st.substream.compand_on[ch] != 0 {
                    for ts in ts0..ts1 {
                        let factor = g * self.st.substream.g_sum[ts as usize] / nb_ch as f32;
                        for sb in sb0..sb1 {
                            ssch.q[0][ts as usize][sb as usize] *= factor;
                            ssch.q[1][ts as usize][sb as usize] *= factor;
                        }
                    }
                } else if self.st.substream.compand_avg != 0 {
                    let d = ts1 - ts0;
                    let mut factor = 0.0f32;
                    for ts in ts0..ts1 {
                        factor += self.st.substream.g_sum[ts as usize] / nb_ch as f32;
                    }
                    factor /= d as f32;
                    factor *= g;

                    for ts in ts0..ts1 {
                        for sb in sb0..sb1 {
                            ssch.q[0][ts as usize][sb as usize] *= factor;
                            ssch.q[1][ts as usize][sb as usize] *= factor;
                        }
                    }
                }
            }
        }
    }

    fn decode_channel(&mut self, ch: usize, out: &mut [f32], qmf_bypass: bool) {
        if qmf_bypass {
            // Without QMF-domain consumers the analysis/synthesis cascade is
            // a perfect-reconstruction identity with gain 1/32768 (the
            // scaling inside the analysis feed) and a group delay of
            // QMF_BYPASS_DELAY samples (verified NCC = 1.0 against the full
            // filterbank).
            let n = out.len();
            let pcm = &self.st.substream.ssch[ch].pcm;
            while self.st.qmf_bypass_delay.len() <= ch {
                self.st
                    .qmf_bypass_delay
                    .push(vec![0.0f32; QMF_BYPASS_DELAY]);
            }
            let d = &mut self.st.qmf_bypass_delay[ch];
            debug_assert_eq!(d.len(), QMF_BYPASS_DELAY);
            if n >= QMF_BYPASS_DELAY {
                out[..QMF_BYPASS_DELAY].copy_from_slice(&d[..]);
                out[QMF_BYPASS_DELAY..].copy_from_slice(&pcm[..n - QMF_BYPASS_DELAY]);
                d.copy_from_slice(&pcm[n - QMF_BYPASS_DELAY..n]);
            } else {
                out.copy_from_slice(&d[..n]);
                d.copy_within(n.., 0);
                d[QMF_BYPASS_DELAY - n..].copy_from_slice(&pcm[..n]);
            }
            for v in out.iter_mut() {
                *v /= 32768.0;
            }
        } else {
            self.qmf_synthesis(ch, out);
        }
    }

    /// Decodes one AC-4 frame (raw frame bytes, with the 0xAC40/0xAC41 sync
    /// header if present). Returns `None` while the decoder is still waiting
    /// for its first iframe.
    pub fn decode_frame(&mut self, packet: &[u8]) -> Result<Option<Frame>> {
        let mut data: Vec<Vec<f32>> = Vec::new();
        let info = self.decode_frame_into(packet, &mut data)?;
        Ok(info.map(|i| Frame {
            audio_kind: i.audio_kind,
            sample_rate: i.sample_rate,
            channel_mask: i.channel_mask,
            nb_samples: i.nb_samples,
            key_frame: i.key_frame,
            data,
        }))
    }

    /// Zero-allocation decoding: `buf` is resized to the frame layout and
    /// reused across calls; returns the frame metadata, or `None` while the
    /// decoder is still waiting for its first iframe.
    pub fn decode_frame_into(
        &mut self,
        packet: &[u8],
        buf: &mut Vec<Vec<f32>>,
    ) -> Result<Option<FrameInfo>> {
        self.ajoc_metadata = None;
        self.ajoc_qmf_available = false;
        if packet.len() < 8 {
            self.st.ajoc_object_decoder = None;
            if self.ajoc_objects {
                buf.clear();
            }
            return Err(invalid("invalid packet size"));
        }

        let header = u16::from_be_bytes([packet[0], packet[1]]);
        let mut start_offset = 0usize;
        if header == 0xAC40 || header == 0xAC41 {
            let size = u16::from_be_bytes([packet[2], packet[3]]);
            start_offset = 4;
            if size == 0xFFFF {
                start_offset += 3;
            }
        }

        let mut gb = BitReader::new(packet);
        gb.skip_bits_long((start_offset * 8) as i64);

        if crate::bitreader::trace_enabled() {
            crate::bitreader::TRACE.with(|t| t.borrow_mut().clear());
        }
        let res = self.decode_frame_inner(&mut gb, buf);
        if res.is_err() {
            self.ajoc_metadata = None;
            self.ajoc_qmf_available = false;
            self.st.ajoc_object_decoder = None;
            if self.ajoc_objects {
                buf.clear();
            }
            if crate::bitreader::trace_enabled() {
                crate::bitreader::trace_dump();
            }
            self.st.have_iframe = 0;
        }
        res
    }

    fn decode_frame_inner(
        &mut self,
        gb: &mut BitReader,
        data: &mut Vec<Vec<f32>>,
    ) -> Result<Option<FrameInfo>> {
        self.ac4_toc(gb)?;

        if self.st.frame_len_base_prev != self.st.frame_len_base {
            for c in 0..12 {
                self.st.substream.ssch[c].n_prev = 0;
                self.st.substream.ssch[c].idx_prev = 0;
            }
            self.st.frame_len_base_prev = self.st.frame_len_base;
        }

        if self.st.have_iframe == 0 {
            return Ok(None);
        }
        let ajoc_core = self.st.version == 2
            && self.st.ssgroup[0].channel_coded == 0
            && self.st.ssgroup[0].ajoc != 0
            && self.ajoc_core;
        if self.st.version == 2 && self.st.ssgroup[0].channel_coded == 0 && !ajoc_core {
            return Err(unsupported("object coding"));
        }

        if ajoc_core
            && (self.st.ssgroup[0].ssinfo.sf_multiplier != 0
                || self.st.pinfo[0].frame_rate_factor != 1)
        {
            return Err(unsupported("A-JOC high-rate extension"));
        }
        let presentation = self
            .st
            .target_presentation
            .min((self.st.nb_presentations - 1).max(0));
        let channel_mode = if self.st.version == 2 {
            self.st.ssgroup[0].ssinfo.channel_mode
        } else {
            self.st.pinfo[presentation as usize].ssinfo[0].channel_mode
        };
        let mut sample_rate: i64 = if self.st.fs_index != 0 { 48000 } else { 44100 };

        if !(0..CHANNEL_MODE_LAYOUTS.len() as i32).contains(&channel_mode) {
            return Err(invalid("invalid channel mode"));
        }

        let (_, mut mask) = CHANNEL_MODE_LAYOUTS[channel_mode as usize];
        if ajoc_core {
            let ssi = &self.st.ssgroup[0].ssinfo;
            if !(0..self.st.nb_substreams).contains(&ssi.substream_index) {
                return Err(invalid("invalid A-JOC substream index"));
            }
            mask = ssi.core_bed_mask;
            if mask != 0 && mask.count_ones() as i32 != ssi.n_fullband_dmx_signals {
                return Err(unsupported("A-JOC core bed assignment"));
            }
            if ssi.lfe != 0 && mask != 0 {
                mask |= 8;
            }
            if mask.count_ones() > 12 {
                return Err(unsupported("A-JOC core layout"));
            }
            let first = usize::from(ssi.lfe != 0);
            let mut index = first;
            // AC-4 bed order differs from WAVE order: surrounds precede backs.
            for speaker in [0, 1, 2, 9, 10, 4, 5, 12, 14, 11, 16, 15, 17] {
                if mask & (1 << speaker) != 0 {
                    self.st.ch_map[speaker] = index as i32;
                    index += 1;
                }
            }
            if first != 0 {
                self.st.ch_map[chan::LOW_FREQUENCY] = 0;
            }
        }
        let nb_channels = if ajoc_core && mask == 0 {
            let ssi = &self.st.ssgroup[0].ssinfo;
            let count = ssi.n_fullband_dmx_signals + ssi.lfe;
            if !(1..=12).contains(&count) {
                return Err(unsupported("A-JOC core signal count"));
            }
            count as usize
        } else {
            mask.count_ones() as usize
        };

        let (num, den) = self.st.resampling_ratio;
        if num != 0 {
            sample_rate = rescale(sample_rate, den, num);
        }
        let nb_samples = self.st.frame_len_base as usize;

        gb.skip_bits_long(self.st.payload_base as i64 * 8);

        if ajoc_core
            && self.ajoc_metadata_enabled
            && let Some(common) = &self.st.ssgroup[0].ssinfo.oamd_common
        {
            self.st.ajoc_history.common = Some(common.clone());
        }
        for i in 0..self.st.nb_substreams as usize {
            if ajoc_core {
                let target = self.st.ssgroup[0].ssinfo.substream_index;
                if i as i32 == target {
                    self.ac4_substream(gb, 0, self.st.substream_size[i])?;
                    break;
                }
                if self.st.substream_size[i] <= 0 {
                    return Err(invalid("missing preceding substream size"));
                }
                if self.ajoc_metadata_enabled && self.st.ssgroup[0].oamd_index == Some(i as i32) {
                    let start = gb.bits_count();
                    let end = start + self.st.substream_size[i] as usize * 8;
                    crate::ajoc::common_timing(gb, end, &mut self.st.ajoc_history)?;
                    gb.skip_bits_long((end - gb.bits_count()) as i64);
                    continue;
                }
                gb.skip_bits_long(self.st.substream_size[i] as i64 * 8);
                continue;
            }
            let substream_type = self.st.substream_type[i];
            match substream_type {
                enums::ST_SUBSTREAM => {
                    self.ac4_substream(gb, 0, self.st.substream_size[i])?;
                    break;
                }
                enums::ST_PRESENTATION => {
                    gb.skip_bits_long(self.st.substream_size[i] as i64 * 8);
                }
                _ => unreachable!(),
            }
        }

        if gb.bits_left() < 0 {
            // C logs an overread warning and continues.
        }

        for ch in 0..nb_channels {
            self.scale_spec(ch);
        }

        if ajoc_core && self.st.ssgroup[0].ssinfo.static_dmx == 0 {
            for p in 0..self.variable_pairs.len() {
                let (left, right) = self.variable_pairs[p];
                self.two_channel_processing(left, right);
            }
        } else {
            let mode = if ajoc_core {
                if self.st.ssgroup[0].ssinfo.lfe != 0 {
                    4
                } else {
                    3
                }
            } else {
                channel_mode
            };
            match mode {
                0 => {}
                1 => self.stereo_processing(),
                3 | 4 => self.m5channel_processing(),
                _ => {}
            }
        }

        let qmf_bypass =
            self.qmf_bypass && !self.ajoc_objects && self.st.substream.codec_mode < enums::CM_ASPX;
        for ch in 0..nb_channels {
            self.prepare_channel(ch, !qmf_bypass);
        }

        self.channels_companding(nb_channels);

        self.channels_aspx_processing(nb_channels)?;
        self.ajoc_qmf_available = ajoc_core && self.ajoc_metadata.is_some() && !qmf_bypass;

        if ajoc_core && self.ajoc_objects {
            let mut core = Vec::new();
            self.copy_ajoc_core_qmf(&mut core)?;
            let has_lfe = self.st.ssgroup[0].ssinfo.lfe != 0;
            let mut lfe = [0.0; 2048];
            if has_lfe {
                self.decode_channel(0, &mut lfe[..nb_samples], false);
            }
            let decoder = self
                .st
                .ajoc_object_decoder
                .get_or_insert_with(Default::default);
            decoder.process(
                &self.tables.qmf_syn,
                self.ajoc_metadata
                    .as_ref()
                    .ok_or_else(|| invalid("missing A-JOC matrices"))?,
                &core,
                has_lfe.then_some(&lfe[..nb_samples]),
                if let Some(options) = self.ajoc_render {
                    crate::ajoc::signals::ObjectOutput::Speakers(options)
                } else if self.ajoc_preview {
                    crate::ajoc::signals::ObjectOutput::Preview
                } else {
                    crate::ajoc::signals::ObjectOutput::Raw
                },
                data,
            )?;
            self.st.first_frame = 0;
            return Ok(Some(FrameInfo {
                audio_kind: if self.ajoc_render.is_some() {
                    AudioKind::AjocSpeakerFeeds
                } else if self.ajoc_preview {
                    AudioKind::AjocStereoPreview
                } else {
                    AudioKind::AjocObjectSignals
                },
                sample_rate: sample_rate as u32,
                channel_mask: self
                    .ajoc_render
                    .map_or(if self.ajoc_preview { 3 } else { 0 }, |o| {
                        o.layout.channel_mask()
                    }),
                nb_samples,
                key_frame: self.st.iframe_global != 0,
            }));
        }

        // Reuse the caller's channel buffers across frames (Vec::clear on a
        // Vec<Vec<f32>> would drop them).
        if data.len() != nb_channels {
            data.clear();
            data.resize_with(nb_channels, || vec![0.0f32; nb_samples]);
        } else {
            for ch in data.iter_mut() {
                ch.clear();
                ch.resize(nb_samples, 0.0);
            }
        }
        for ch in 0..nb_channels {
            let sch = if mask == 0 {
                0
            } else {
                channel_from_index(mask, ch)
            };
            let dch = if mask == 0 {
                ch as i32
            } else {
                self.st.ch_map[sch]
            };
            debug_assert!((0..12).contains(&dch));
            let dch = dch as usize;
            self.decode_channel(dch, &mut data[ch], qmf_bypass);
        }

        let key_frame = self.st.iframe_global != 0;
        self.st.first_frame = 0;

        Ok(Some(FrameInfo {
            audio_kind: if ajoc_core {
                AudioKind::AjocCoreSignals
            } else {
                AudioKind::Channels
            },
            sample_rate: sample_rate as u32,
            channel_mask: mask,
            nb_samples,
            key_frame,
        }))
    }

    /// Enables A-JOC core signal decoding.
    /// Unanchored downmix signals have channel_mask == 0 and are not speaker
    /// feeds. This does not reconstruct or render transmitted upmix objects.
    /// Disabled by default so callers explicitly choose core output.
    pub fn set_ajoc_core_signals(&mut self, enable: bool) {
        if self.ajoc_core != enable {
            self.ajoc_core = enable;
            if !enable {
                self.ajoc_objects = false;
                self.ajoc_preview = false;
                self.ajoc_render = None;
                self.ajoc_metadata_enabled = false;
            }
            self.flush();
        }
    }

    /// Parse A-JOC reconstruction side information while returning core PCM.
    /// Supports dynamic-only assignments; unsupported metadata returns an error.
    /// This does not enable object reconstruction or spatial rendering.
    pub fn set_ajoc_metadata(&mut self, enable: bool) {
        if enable {
            self.set_ajoc_core_signals(true);
        }
        if self.ajoc_metadata_enabled != enable {
            self.ajoc_metadata_enabled = enable;
            if !enable {
                self.ajoc_objects = false;
                self.ajoc_preview = false;
                self.ajoc_render = None;
            }
            self.flush();
        }
    }

    /// Reconstruction parameters from the last successful frame, if requested.
    pub fn ajoc_metadata(&self) -> Option<&crate::ajoc::AjocMetadata> {
        self.ajoc_metadata.as_ref()
    }

    /// Reconstruct fullband A-JOC objects with matrix interpolation,
    /// decorrelation/ducking and QMF synthesis. The LFE plane, when present,
    /// precedes the fullband objects. Output has a zero speaker mask and kind
    /// AjocObjectSignals. OAMD gain/position rendering and dialogue enhancement
    /// are not applied. Not a headphone/speaker playback mode.
    pub fn set_ajoc_object_signals(&mut self, enable: bool) {
        let was_preview = self.ajoc_preview || self.ajoc_render.is_some();
        self.ajoc_preview = false;
        self.ajoc_render = None;
        if enable {
            self.set_ajoc_metadata(true);
        }
        if self.ajoc_objects != enable || was_preview {
            self.ajoc_objects = enable;
            self.flush();
        }
    }

    /// Enable a basic stereo preview using OAMD object gain and X position,
    /// with sample-timed smoothing. Y/Z, zones, extents, trims, distance and
    /// divergence are not rendered. This is not a binaural or reference-
    /// equivalent immersive mode. Disabling retains raw object signal mode.
    pub fn set_ajoc_stereo_preview(&mut self, enable: bool) {
        if self.ajoc_preview == enable {
            return;
        }
        if enable {
            self.set_ajoc_object_signals(true);
        }
        self.ajoc_preview = enable;
        self.flush();
    }

    /// Render dynamic A-JOC objects to speaker feeds. Configuration changes
    /// reset all decoding/render history. None retains raw object mode.
    /// Ordinary channel-coded streams retain their original layout. This is
    /// speaker rendering, without HRTF, loudness correction or bass management.
    pub fn set_ajoc_render(
        &mut self,
        options: Option<crate::ajoc::render::RenderOptions>,
    ) -> Result<()> {
        if let Some(options) = options {
            options.validate()?;
        }
        if self.ajoc_render == options {
            return Ok(());
        }
        if options.is_some() {
            self.set_ajoc_object_signals(true);
        }
        self.ajoc_render = options;
        self.flush();
        Ok(())
    }

    /// Copy the last inspected A-JOC frame's fullband core QMF planes, in
    /// bitstream signal order, excluding LFE. Requires a successful metadata
    /// inspection frame and the full QMF path. This is a control/research API;
    /// it does not change returned PCM or reconstruct/render the objects.
    pub fn copy_ajoc_core_qmf(
        &self,
        output: &mut crate::ajoc::reconstruction::QmfPlanes,
    ) -> Result<()> {
        output.clear();
        if self.ajoc_metadata.is_none() {
            return Err(invalid("no inspected A-JOC frame"));
        }
        if !self.ajoc_qmf_available {
            return Err(unsupported("A-JOC QMF inspection with bypass"));
        }
        let info = &self.st.ssgroup[0].ssinfo;
        let first = usize::from(info.lfe != 0);
        let count = info.n_fullband_dmx_signals as usize;
        let slots = self.st.num_qmf_timeslots as usize;
        for ch in first..first + count {
            let q = &self.st.substream.ssch[ch].q;
            let mut plane = vec![[[0.0; 2]; 64]; slots];
            for (ts, slot) in plane.iter_mut().enumerate() {
                for (sb, sample) in slot.iter_mut().enumerate() {
                    *sample = [q[0][ts][sb], q[1][ts][sb]];
                }
            }
            output.push(plane);
        }
        Ok(())
    }

    /// Enables or disables the QMF round-trip shortcut for simple streams
    /// (see [`Ac4Decoder`]). Off by default.
    pub fn set_qmf_bypass(&mut self, enable: bool) {
        self.qmf_bypass = enable;
    }

    /// Coding tools parsed from the most recent frame's first audio
    /// substream. Meaningful only after a successful `decode_frame*` call.
    pub fn features(&self) -> StreamFeatures {
        StreamFeatures {
            codec_mode: self.st.substream.codec_mode,
            spec_frontend_l: self.st.substream.spec_frontend_l,
            spec_frontend_r: self.st.substream.spec_frontend_r,
            spec_frontend_m: self.st.substream.spec_frontend_m,
            spec_frontend_s: self.st.substream.spec_frontend_s,
        }
    }

    /// Clears all per-stream history and waits for a fresh iframe.
    /// Transform plans/tables and explicit output options are retained.
    /// Call on the playback control path: replacing state allocates channel
    /// histories, so this is not a real-time PCM callback operation.
    pub fn flush(&mut self) {
        self.st = State::default();
        self.variable_pairs.clear();
        self.ajoc_metadata = None;
        self.ajoc_qmf_available = false;
    }
}

/// `get_max_sfb()` as a free function so it can be called while an
/// `&mut SubstreamChannel` borrow is active.
fn get_max_sfb_(frame_len_base: i32, ssch: &SubstreamChannel, g: i32) -> i32 {
    let mut idx = 0;

    if frame_len_base >= 1536
        && ssch.scp.long_frame == 0
        && ssch.scp.transf_length_idx[0] != ssch.scp.transf_length_idx[1]
    {
        let num_windows_0 = 1i32 << (3 - ssch.scp.transf_length_idx[0] as i32);
        if g >= ssch.scp.window_to_group[num_windows_0 as usize] as i32 {
            idx = 1;
        }
    }

    if ssch.scp.side_limited == 1 || (ssch.scp.dual_maxsfb == 1 && ssch.scp.side_channel == 1) {
        ssch.scp.max_sfb_side[idx] as i32
    } else {
        ssch.scp.max_sfb[idx] as i32
    }
}

/// `get_transf_length()` returning (length, tab_index).
fn get_transf_length_(frame_len_base: i32, ssch: &SubstreamChannel, g: i32) -> (i32, i32) {
    let row = match frame_len_base {
        2048 => 0,
        1920 => 1,
        1536 => 2,
        1024 => 3,
        960 => 4,
        768 => 5,
        512 => 6,
        384 => 7,
        _ => panic!("invalid frame_len_base"),
    };
    let tab = &TRANSF_LENGTH_48KHZ[row];

    if frame_len_base >= 1536 {
        if ssch.scp.long_frame == 0 {
            let num_windows_0 = 1i32 << (3 - ssch.scp.transf_length_idx[0] as i32);

            if g < ssch.scp.window_to_group[num_windows_0 as usize] as i32 {
                (
                    tab[ssch.scp.transf_length_idx[0] as usize] as i32,
                    ssch.scp.transf_length_idx[0] as i32,
                )
            } else {
                (
                    tab[ssch.scp.transf_length_idx[1] as usize] as i32,
                    ssch.scp.transf_length_idx[1] as i32,
                )
            }
        } else {
            (frame_len_base, 4) // long frame
        }
    } else {
        (
            tab[ssch.scp.transf_length_idx[0] as usize] as i32,
            ssch.scp.transf_length_idx[0] as i32,
        )
    }
}

fn ext_decode(gb: &mut BitReader) -> i32 {
    let n_ext = gb.get_unary(0, 17);

    (1 << (n_ext + 4)) + gb.get_bits_long(n_ext + 4) as i32
}

fn get_sfb_size(transf_length: i32) -> i32 {
    get_sfb_offset(transf_length).len() as i32
}

fn get_sfb_offset(transf_length: i32) -> &'static [u16] {
    match transf_length {
        2048 => &SFB_OFFSET_48KHZ_2048,
        1920 => &SFB_OFFSET_48KHZ_1920,
        1536 => &SFB_OFFSET_48KHZ_1536,
        1024 => &SFB_OFFSET_48KHZ_1024,
        960 => &SFB_OFFSET_48KHZ_960,
        768 => &SFB_OFFSET_48KHZ_768,
        512 => &SFB_OFFSET_48KHZ_512,
        480 => &SFB_OFFSET_48KHZ_480,
        384 => &SFB_OFFSET_48KHZ_384,
        256 => &SFB_OFFSET_48KHZ_256,
        240 => &SFB_OFFSET_48KHZ_240,
        192 => &SFB_OFFSET_48KHZ_192,
        128 => &SFB_OFFSET_48KHZ_128,
        120 => &SFB_OFFSET_48KHZ_120,
        96 => &SFB_OFFSET_48KHZ_96,
        _ => panic!("invalid transf_length {transf_length}"),
    }
}

fn num_sfb_48(transf_length: i32) -> i32 {
    match transf_length {
        2048 => 63,
        1920 => 61,
        1536 => 55,
        1024 | 960 => 49,
        768 => 43,
        512 | 480 => 36,
        384 => 33,
        256 | 240 => 20,
        192 => 18,
        128 | 120 => 14,
        96 => 12,
        _ => panic!("invalid transf_length {transf_length}"),
    }
}

fn fcomplex_mul(x: f32, yi: f32, u: f32, vi: f32) -> (f32, f32) {
    (x * u - yi * vi, x * vi + u * yi)
}

fn sqr(a: f32, b: f32) -> f32 {
    a * a + b * b
}

fn fcomplex_div(x: f32, yi: f32, u: f32, vi: f32) -> (f32, f32) {
    let div = sqr(u, vi);
    let re = x * u + yi * vi;
    let im = x * vi - u * yi;
    (re / div, im / div)
}

fn sine_idx(sb: usize, ts: usize, first_frame: i32, ssch: &SubstreamChannel) -> usize {
    let mut index = if first_frame != 0 {
        1
    } else {
        ((ssch.sine_idx_prev[ts][sb] as i32) + 1) & 3
    };
    index += ts as i32 - ssch.atsg_sig[0] as i32;
    (index & 3) as usize
}

fn noise_idx(sb: usize, ts: usize, ssch: &SubstreamChannel) -> usize {
    let mut index = if ssch.master_reset != 0 {
        0
    } else {
        ssch.noise_idx_prev[ts][sb] as i32
    };
    index += ssch.num_sb_aspx * (ts as i32 - ssch.atsg_sig[0] as i32);
    index += sb as i32 + 1;
    (index & 511) as usize
}

/// Returns the `chan::*` index of the `index`-th set bit in a channel mask.
fn channel_from_index(mask: u64, index: usize) -> usize {
    let mut seen = 0usize;
    for b in 0..64 {
        if mask & (1u64 << b) != 0 {
            if seen == index {
                return b;
            }
            seen += 1;
        }
    }
    unreachable!("channel index {index} not in mask {mask:#x}");
}

/// Computes a*b/c with round-half-away-from-zero semantics.
fn rescale(a: i64, b: i64, c: i64) -> i64 {
    let mut r = a * b;
    if r >= 0 {
        r += c / 2;
    } else {
        r -= c / 2;
    }
    r / c
}

/// Least-squares polynomial fit via Gauss-Jordan elimination. Returns -1 on
/// bad input, 0 otherwise (including on a singular matrix, leaving the
/// coefficients from the partially reduced system).
fn polyfit(
    order: usize,
    count_of_elements: i32,
    dependent_values: &[f32],
    independent_values: &[f32],
    coefficients: &mut [f32],
) -> i32 {
    const MAX_ORDER: usize = 5;
    let mut b = [0.0f32; MAX_ORDER + 1];
    let mut p = [0.0f32; (MAX_ORDER + 1) * 2 + 1];
    let mut a = [0.0f32; (MAX_ORDER + 1) * 2 * (MAX_ORDER + 1)];

    if count_of_elements <= order as i32 {
        return -1;
    }
    if order > MAX_ORDER {
        return -1;
    }

    // Identify the column vector
    for ii in 0..count_of_elements as usize {
        let x = dependent_values[ii];
        let y = independent_values[ii];
        let mut powx = 1.0f32;
        for jj in 0..order + 1 {
            b[jj] += y * powx;
            powx *= x;
        }
    }

    // Initialize the PowX array
    p[0] = count_of_elements as f32;
    // Compute the sum of the Powers of X
    for ii in 0..count_of_elements as usize {
        let x = dependent_values[ii];
        let mut powx = dependent_values[ii];
        for jj in 1..2 * (order + 1) + 1 {
            p[jj] += powx;
            powx *= x;
        }
    }

    // Initialize the reduction matrix
    for ii in 0..order + 1 {
        for jj in 0..order + 1 {
            a[ii * 2 * (order + 1) + jj] = p[ii + jj];
        }
        a[ii * 2 * (order + 1) + ii + (order + 1)] = 1.0;
    }

    // Move the Identity matrix portion of the redux matrix to the left side
    // (find the inverse of the left side of the redux matrix)
    for ii in 0..order + 1 {
        let x = a[ii * 2 * (order + 1) + ii];
        if x != 0.0 {
            for kk in 0..2 * (order + 1) {
                a[ii * 2 * (order + 1) + kk] /= x;
            }
            for jj in 0..order + 1 {
                if jj != ii {
                    let y = a[jj * 2 * (order + 1) + ii];
                    for kk in 0..2 * (order + 1) {
                        a[jj * 2 * (order + 1) + kk] -= y * a[ii * 2 * (order + 1) + kk];
                    }
                }
            }
        } else {
            // Cannot work with singular matrices (C returns 0 here).
            return 0;
        }
    }

    // Calculate and identify the coefficients
    for ii in 0..order + 1 {
        let mut x = 0.0f32;
        for kk in 0..order + 1 {
            x += a[ii * 2 * (order + 1) + kk + (order + 1)] * b[kk];
        }
        coefficients[ii] = x;
    }

    0
}
