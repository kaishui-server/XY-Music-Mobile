fn main() {
    // anime 音效引擎（open.anime.bzxhkj.com 开放平台官方 C 源码，纯 C 零依赖）。
    // 随 Rust 核心库一同编入 .so，由 player::output::android_aaudio 内的
    // AnimeFxEngine 封装调用（F32↔PCM16 域转换 + 直通快路径）。
    let mut build = cc::Build::new();
    build
        .file("src/player/animefx.c")
        .include("src/player")
        .warnings(false);
    build.compile("animefx");
}
