use xymusic_core::music::lyric_fetcher::{
    test_support_des_trace, test_support_qrc_decrypt_raw,
};

/// 诊断用：输出沧浪歌密文 3DES 解密后的原始字节（未解压），
/// 用于与 Dart 侧翻译实现逐字节对比。
#[test]
fn dump_canglangge_decrypted_raw() {
    let hex = std::fs::read_to_string("tests/canglangge_lyric.hex")
        .expect("missing tests/canglangge_lyric.hex");
    let raw = test_support_qrc_decrypt_raw(hex.trim());
    let head: String = raw
        .iter()
        .take(32)
        .map(|b| format!("{:02x}", b))
        .collect();
    println!("decrypted_raw_head_32 = {}", head);
    println!("decrypted_raw_len = {}", raw.len());
}

#[test]
fn dump_des_trace_first_block() {
    let hex = std::fs::read_to_string("tests/canglangge_lyric.hex")
        .expect("missing tests/canglangge_lyric.hex");
    let first_block = hex.trim().split_at(16).0.to_string();
    println!("trace = {}", test_support_des_trace(&first_block));
}
