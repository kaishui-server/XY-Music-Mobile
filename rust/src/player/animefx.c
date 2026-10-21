/*
 * 次惜 animemusic 音效引擎（v1.3.318 初版 / v1.3.330 算法精修 / v1.3.331 量级校准）—— C 语言 DSP 渲染核心
 *
 * 处理链（顺序即信号流，v1.3.330 算法精修）：
 *   输入 → 10 段图形 EQ（RBJ 峰值，Q≈1.1，0dB 段恒等跳过）
 *        → 次谐波低音增强（55Hz 基频 + 110Hz 泛音双八度合成，低频包络慢放更厚）
 *        → 谐波激励（带通→全波整流→奇次软化+偶次谐波注入→高通回注，Aphex 口径）
 *        → 黑胶抖晃（慢速双 LFO + 5Hz 微颤调制延迟线读指针，线性插值）
 *        → 压缩器（峰值包络 + dB 域软拐点 + 攻击/程控释放平滑 + 补偿增益）
 *        → 立体声展宽（M-S 矩阵，S 系数 1→2，250Hz 以下低频保持居中防抵消）
 *        → 混响（Freeverb 拓扑：反馈输出低通真回环（v1.3.330 修复假回环），
 *          8 并联梳状 + 4 串联全通，左右声道独立预延时去相关 + 23 样本立体声扩展）
 *        → 3D 声像旋转（cos-sin 恒功率旋转）
 *        → 空气感（12kHz 高架搁架，0..6dB）
 *        → 输出增益 + DC 阻隔（15Hz 直流阻断） + 软限幅（tanh 渐入混合，防数字削波杂音）
 *
 * v1.3.330 精修清单：
 *   A. 混响 comb 反馈路径修复：原实现低通的是输入（回环断裂，尾音只有 8 个离散回声），
 *      改为经典 Freeverb「低通反馈输出再回写」，混响拥有真实密实尾音；房间 0..1 映射
 *      反馈 0.74..0.87（尾长约 0.8~2.2s）、阻尼 0.30..0.55（大房间更暗更长）
 *   B. 次谐波：单 55Hz 正弦 → 55Hz 基频 + 110Hz 二次泛音（+0.7rad 去相关）双八度，
 *      包络释放 9ms→32ms，低音更厚实不"嗡"单频
 *   C. 激励：整流谐波加 rl² 偶次谐波注入（HP 滤除直流失调），细节更亮更"近"
 *   D. 压缩器：硬拐点 → 6dB 软拐点（二次曲线过渡，起压更柔不"撞"）；
 *      释放程控化——过阈中速回弹、低于阈值慢速收尾（呼吸感自然）
 *   E. 展宽：全频段 M-S → 边信号 250Hz 低通分离，低频边信号不展宽，
 *      单声道兼容（手机外放低频不抵消）
 *   F. 混响输入去相关：左右声道独立预延时缓冲，尾音立体声感更强
 *   G. 输出 15Hz DC 阻隔：清除激励/次谐波路径直流失调，防扬声器偏移
 *   H. 抖晃：叠加 5.2Hz 微颤（胶盘轴心抖动），味道更真
 *
 * v1.3.331 量级校准（主人实测 330「处理前后没啥区别」）：
 *   I. 抖晃深度 0.003→0.012（旧值 100% 仅约 4 音分摆动，人耳无感；现约 16 音分明显复古）
 *   J. 激励输出 0.55→1.1（带通小信号，旧值贡献 <5%）
 *   K. 次谐波 1.5→1.8 / 混响 wetRv 0.7→0.85 + 预延时输入去 0.5 衰减
 *
 * 防杂音措施：
 *   1. 参数切换系数渐变：EQ 系数逐块向目标收敛（30~70ms），0dB 时峰值滤波器
 *      b==a 恒等于直通，开合无缝不炸响
 *   2. 总湿/干交叉淡化：音效启用/停用约 12ms 过渡，杜绝爆音
 *   3. denormal 抑制：滤波状态加 1e-20 偏置（亚正规数掉速/杂音）
 *   4. NaN/Inf 防护：每样本出口 isfinite 检查，异常即置零
 *   5. 软限幅：|x|>0.7 区域 tanh 渐入混合，永不硬削波
 *   6. 单声道输入自动跳过立体声专属模块（旋转/展宽）
 *   7. reset 只清状态不清系数（seek 后音效立即生效，无空窗）
 *
 * 线程约定：process 与 set_params/set_bypass 由 JNI 侧串行化（同一播放器线程）；
 * 交叉淡化状态仅 process 线程写。
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define EQ_BANDS 10
#define EQ_Q 1.1f
#define RV_COMBS 8
#define RV_APS 4

/* 双二阶滤波器（归一化 a0=1，含状态；b0..a2 五系数连续便于整块插值） */
typedef struct {
    float b0, b1, b2, a1, a2;
    float x1, x2, y1, y2;
} Biquad;

typedef struct {
    /* 基础 */
    int rate;
    int ch;
    float wet;        /* 湿声权重 0..1（启用/停用交叉淡化） */
    float wetTarget;
    int bypass;

    /* 输出增益（线性） */
    float gainLin;

    /* 10 段 EQ：目标增益 dB / 目标系数 / 当前系数 / 开关 */
    float eqGain[EQ_BANDS];
    float eqTgt[EQ_BANDS][5];
    float eqCur[EQ_BANDS][5];
    Biquad eq[EQ_BANDS][2];

    /* 压缩器 */
    int cOn; float cThr; float cRatio; float cAtk; float cRel; float cMkup;
    float cEnv; float cGr; /* 包络（线性）/ 增益削减（dB，平滑后） */

    /* 次谐波 */
    int sOn; float sAmt; float sPhase; float sLp; float sEnv;

    /* 激励 */
    int xOn; float xAmt; float xFreq;
    Biquad xBp[2]; Biquad xHp[2];

    /* 抖晃 */
    int wOn; float wAmt; float wPhase; float *wBuf[2]; int wLen; int wPos;

    /* 3D 旋转 */
    int rotOn; float rotRate; float rotPhase;

    /* 展宽 / 空气感 */
    float width;
    float airDb;
    Biquad air[2];

    /* 混响（Freeverb）：左右声道各自长度（+23 样本立体声扩展）与位置 */
    int rOn; float rMix; float rRoom; float rPre;
    float *rcBuf[2][RV_COMBS]; int rcLenL[RV_COMBS]; int rcLenR[RV_COMBS];
    int rcPosL[RV_COMBS]; int rcPosR[RV_COMBS]; float rcStore[2][RV_COMBS];
    float *raBuf[2][RV_APS]; int raLenL[RV_APS]; int raLenR[RV_APS];
    int raPosL[RV_APS]; int raPosR[RV_APS];
    float *rpBuf; int rpLen; int rpPos;
    float *rpBufR; /* v1.3.330 右声道预延时缓冲（立体声去相关） */

    /* v1.3.330：输出 DC 阻隔状态（左右）/ 展宽边信号低频状态 */
    float dcX[2], dcY[2];
    float wLp;
} FxEngine;

/* ================= 工具 ================= */

static int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

/* 软限幅：0.7 以上渐入 tanh，硬边界 1.0 */
static float softclip(float x) {
    float a = fabsf(x);
    if (a <= 0.7f) return x;
    if (a > 4.0f) a = 4.0f;
    float t = tanhf(a * 1.05f) / tanhf(1.05f); /* 端点归一到 1 */
    float k = (a - 0.7f) / 0.3f;               /* 0.7→1.0 渐入权重 */
    if (k > 1.0f) k = 1.0f;
    float y = (1.0f - k) * a + k * t;
    if (y > 1.0f) y = 1.0f;
    return x >= 0.0f ? y : -y;
}

/* RBJ 峰值 EQ 系数（归一化 a0=1） */
static void biquad_peak(Biquad *b, float f0, float gainDb, float rate) {
    float A = powf(10.0f, gainDb / 40.0f);
    float w0 = 2.0f * (float)M_PI * f0 / rate;
    float cw = cosf(w0), sw = sinf(w0);
    float alpha = sw / (2.0f * EQ_Q);
    float a0 = 1.0f + alpha / A;
    b->b0 = (1.0f + alpha * A) / a0;
    b->b1 = (-2.0f * cw) / a0;
    b->b2 = (1.0f - alpha * A) / a0;
    b->a1 = (-2.0f * cw) / a0;
    b->a2 = (1.0f - alpha / A) / a0;
}

/* RBJ 高架搁架（空气感，S=1） */
static void biquad_highshelf(Biquad *b, float f0, float gainDb, float rate) {
    float A = powf(10.0f, gainDb / 40.0f);
    float w0 = 2.0f * (float)M_PI * f0 / rate;
    float cw = cosf(w0), sw = sinf(w0);
    float sa = sqrtf(2.0f) * sw / 2.0f;
    float sqA = sqrtf(A);
    float a0 = (A + 1.0f) - (A - 1.0f) * cw + 2.0f * sqA * sa;
    b->b0 = (A * ((A + 1.0f) + (A - 1.0f) * cw + 2.0f * sqA * sa)) / a0;
    b->b1 = (-2.0f * A * ((A - 1.0f) + (A + 1.0f) * cw)) / a0;
    b->b2 = (A * ((A + 1.0f) + (A - 1.0f) * cw - 2.0f * sqA * sa)) / a0;
    b->a1 = (2.0f * ((A - 1.0f) - (A + 1.0f) * cw)) / a0;
    b->a2 = ((A + 1.0f) - (A - 1.0f) * cw - 2.0f * sqA * sa) / a0;
}

/* 二阶带通（Q≈0.5 宽带） */
static void biquad_bandpass(Biquad *b, float f0, float rate) {
    float w0 = 2.0f * (float)M_PI * f0 / rate;
    float cw = cosf(w0), sw = sinf(w0);
    float alpha = sw / 2.0f;
    float a0 = 1.0f + alpha;
    b->b0 = alpha / a0;
    b->b1 = 0.0f;
    b->b2 = -alpha / a0;
    b->a1 = (-2.0f * cw) / a0;
    b->a2 = (1.0f - alpha) / a0;
}

/* 二阶高通 */
static void biquad_highpass(Biquad *b, float f0, float rate) {
    float w0 = 2.0f * (float)M_PI * f0 / rate;
    float cw = cosf(w0), sw = sinf(w0);
    float alpha = sw / 2.0f;
    float a0 = 1.0f + alpha;
    b->b0 = ((1.0f + cw) / 2.0f) / a0;
    b->b1 = (-(1.0f + cw)) / a0;
    b->b2 = ((1.0f + cw) / 2.0f) / a0;
    b->a1 = (-2.0f * cw) / a0;
    b->a2 = (1.0f - alpha) / a0;
}

static inline float biquad_tick(Biquad *b, float x) {
    float y = b->b0 * x + b->b1 * b->x1 + b->b2 * b->x2 - b->a1 * b->y1 - b->a2 * b->y2;
    b->x2 = b->x1; b->x1 = x;
    b->y2 = b->y1; b->y1 = y + 1e-20f; /* denormal 偏置 */
    return y;
}

/* 只清滤波器状态保留系数（reset 用） */
static inline void biquad_clear_state(Biquad *b) { b->x1 = b->x2 = b->y1 = b->y2 = 0.0f; }

static const float EQ_FREQS[EQ_BANDS] = {31.0f, 62.0f, 125.0f, 250.0f, 500.0f, 1000.0f, 2000.0f, 4000.0f, 8000.0f, 16000.0f};

/* ================= 参数解析（手写固定 schema JSON，零依赖） ================= */

/* 找 "key": 后的值指针；找不到返回 NULL（键带引号防子串误中） */
static const char *jfind(const char *s, const char *key) {
    char needle[40];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(s, needle);
    if (!p) return NULL;
    p += strlen(needle);
    while (*p == ' ' || *p == ':' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    return p;
}

static float jnum(const char *s, const char *key, float def) {
    const char *p = jfind(s, key);
    if (!p || *p == '\0') return def;
    return strtof(p, NULL);
}

static int jbool(const char *s, const char *key) {
    const char *p = jfind(s, key);
    if (!p) return 0;
    if (strncmp(p, "true", 4) == 0) return 1;
    return (int)strtof(p, NULL) != 0;
}

/* 读 eq 数组恰好 10 项；非法返回 0 */
static int jeq10(const char *s, float out[EQ_BANDS]) {
    const char *p = jfind(s, "eq");
    if (!p || *p != '[') return 0;
    p++;
    int n = 0;
    while (*p && n < EQ_BANDS) {
        while (*p == ' ' || *p == ',') p++;
        if (*p == ']') break;
        char *end = NULL;
        float v = strtof(p, &end);
        if (end == p) return 0;
        out[n++] = clampf(v, -12.0f, 12.0f);
        p = end;
    }
    return n == EQ_BANDS;
}

/* ================= 生命周期 ================= */

void *animefx_create(int rate, int ch) {
    if (rate < 8000) rate = 44100;
    if (ch != 1 && ch != 2) ch = 2;
    FxEngine *e = (FxEngine *)calloc(1, sizeof(FxEngine));
    if (!e) return NULL;
    e->rate = rate;
    e->ch = ch;
    e->wet = 0.0f;
    e->wetTarget = 0.0f; /* 默认旁通，set_bypass(false) 后淡入 */
    e->bypass = 1;
    e->gainLin = 1.0f;

    /* 混响缓冲：Freeverb 44.1k 基准调音，按采样率缩放；右声道 +23 样本立体声扩展 */
    static const int combT[RV_COMBS] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
    static const int apT[RV_APS] = {556, 441, 341, 225};
    float scale = (float)rate / 44100.0f;
    for (int c = 0; c < RV_COMBS; c++) {
        e->rcLenL[c] = clampi((int)(combT[c] * scale) + 1, 8, rate);
        e->rcLenR[c] = clampi((int)((combT[c] + 23) * scale) + 1, 8, rate);
        e->rcBuf[0][c] = (float *)calloc(e->rcLenL[c], sizeof(float));
        e->rcBuf[1][c] = (float *)calloc(e->rcLenR[c], sizeof(float));
    }
    for (int a = 0; a < RV_APS; a++) {
        e->raLenL[a] = clampi((int)(apT[a] * scale) + 1, 4, rate);
        e->raLenR[a] = clampi((int)((apT[a] + 23) * scale) + 1, 4, rate);
        e->raBuf[0][a] = (float *)calloc(e->raLenL[a], sizeof(float));
        e->raBuf[1][a] = (float *)calloc(e->raLenR[a], sizeof(float));
    }
    /* 预延时：最大 0.1s（左右声道各一，立体声去相关） */
    e->rpLen = clampi((int)(0.1f * rate) + 1, 8, rate * 2);
    e->rpBuf = (float *)calloc(e->rpLen, sizeof(float));
    e->rpBufR = (float *)calloc(e->rpLen, sizeof(float));

    /* 抖晃延迟线：最大 24ms */
    e->wLen = clampi((int)(0.024f * rate) + 4, 16, rate);
    e->wBuf[0] = (float *)calloc(e->wLen, sizeof(float));
    e->wBuf[1] = (float *)calloc(e->wLen, sizeof(float));

    /* EQ 初始恒等系数（0dB 峰值滤波器 b==a 恒等于直通） */
    for (int i = 0; i < EQ_BANDS; i++) {
        for (int side = 0; side < 2; side++) {
            Biquad *b = &e->eq[i][side];
            memset(b, 0, sizeof(Biquad));
            b->b0 = 1.0f;
        }
        e->eqGain[i] = 0.0f;
        biquad_peak(&e->eq[i][0], EQ_FREQS[i], 0.0f, rate);
        e->eqTgt[i][0] = e->eq[i][0].b0;
        e->eqTgt[i][1] = e->eq[i][0].b1;
        e->eqTgt[i][2] = e->eq[i][0].b2;
        e->eqTgt[i][3] = e->eq[i][0].a1;
        e->eqTgt[i][4] = e->eq[i][0].a2;
        memcpy(e->eqCur[i], e->eqTgt[i], 5 * sizeof(float));
    }
    /* 空气感初始恒等（0dB 高架） */
    for (int side = 0; side < 2; side++) {
        memset(&e->air[side], 0, sizeof(Biquad));
        e->air[side].b0 = 1.0f;
    }
    return e;
}

void animefx_destroy(void *ep) {
    FxEngine *e = (FxEngine *)ep;
    if (!e) return;
    for (int c = 0; c < RV_COMBS; c++) {
        free(e->rcBuf[0][c]);
        free(e->rcBuf[1][c]);
    }
    for (int a = 0; a < RV_APS; a++) {
        free(e->raBuf[0][a]);
        free(e->raBuf[1][a]);
    }
    free(e->rpBuf);
    free(e->rpBufR);
    free(e->wBuf[0]);
    free(e->wBuf[1]);
    free(e);
}

/* 清所有缓冲与状态（seek/换曲）：保留参数与系数，音效立即恢复无空窗 */
void animefx_reset(void *ep) {
    FxEngine *e = (FxEngine *)ep;
    if (!e) return;
    for (int c = 0; c < RV_COMBS; c++) {
        if (e->rcBuf[0][c]) memset(e->rcBuf[0][c], 0, e->rcLenL[c] * sizeof(float));
        if (e->rcBuf[1][c]) memset(e->rcBuf[1][c], 0, e->rcLenR[c] * sizeof(float));
        e->rcStore[0][c] = e->rcStore[1][c] = 0.0f;
    }
    memset(e->rcPosL, 0, sizeof(e->rcPosL));
    memset(e->rcPosR, 0, sizeof(e->rcPosR));
    for (int a = 0; a < RV_APS; a++) {
        if (e->raBuf[0][a]) memset(e->raBuf[0][a], 0, e->raLenL[a] * sizeof(float));
        if (e->raBuf[1][a]) memset(e->raBuf[1][a], 0, e->raLenR[a] * sizeof(float));
    }
    memset(e->raPosL, 0, sizeof(e->raPosL));
    memset(e->raPosR, 0, sizeof(e->raPosR));
    if (e->rpBuf) memset(e->rpBuf, 0, e->rpLen * sizeof(float));
    if (e->rpBufR) memset(e->rpBufR, 0, e->rpLen * sizeof(float));
    e->rpPos = 0;
    for (int side = 0; side < 2; side++)
        if (e->wBuf[side]) memset(e->wBuf[side], 0, e->wLen * sizeof(float));
    e->wPos = 0;
    e->sPhase = 0.0f; e->sLp = 0.0f; e->sEnv = 0.0f;
    e->wPhase = 0.0f;
    e->rotPhase = 0.0f;
    e->cEnv = 0.0f; e->cGr = 0.0f;
    e->dcX[0] = e->dcX[1] = e->dcY[0] = e->dcY[1] = 0.0f;
    e->wLp = 0.0f;
    for (int i = 0; i < EQ_BANDS; i++)
        for (int side = 0; side < 2; side++)
            biquad_clear_state(&e->eq[i][side]);
    for (int side = 0; side < 2; side++) {
        biquad_clear_state(&e->air[side]);
        biquad_clear_state(&e->xBp[side]);
        biquad_clear_state(&e->xHp[side]);
    }
}

/* 应用调音参数 JSON（schema 见文件头；非法值钳制不报错） */
void animefx_set_params(void *ep, const char *json) {
    FxEngine *e = (FxEngine *)ep;
    if (!e || !json) return;

    /* EQ：数组合法才覆盖（部分参数缺 eq 时保持原值） */
    float eq[EQ_BANDS];
    if (jeq10(json, eq)) {
        for (int i = 0; i < EQ_BANDS; i++) {
            e->eqGain[i] = eq[i];
            biquad_peak(&e->eq[i][0], EQ_FREQS[i], eq[i], e->rate);
            e->eqTgt[i][0] = e->eq[i][0].b0;
            e->eqTgt[i][1] = e->eq[i][0].b1;
            e->eqTgt[i][2] = e->eq[i][0].b2;
            e->eqTgt[i][3] = e->eq[i][0].a1;
            e->eqTgt[i][4] = e->eq[i][0].a2;
        }
    }

    /* 压缩器 */
    {
        const char *p = jfind(json, "comp");
        if (p && *p == '{') {
            e->cOn = jbool(p, "on");
            e->cThr = jnum(p, "thr", -20.0f);
            e->cRatio = clampf(jnum(p, "ratio", 3.0f), 1.0f, 20.0f);
            e->cAtk = clampf(jnum(p, "atk", 20.0f), 1.0f, 200.0f) / 1000.0f; /* ms → s */
            e->cRel = clampf(jnum(p, "rel", 200.0f), 10.0f, 1000.0f) / 1000.0f;
            e->cMkup = clampf(jnum(p, "mkup", 0.0f), -6.0f, 6.0f);
        }
    }

    /* 混响 */
    {
        const char *p = jfind(json, "reverb");
        if (p && *p == '{') {
            e->rOn = jbool(p, "on");
            e->rMix = clampf(jnum(p, "mix", 0.2f), 0.0f, 1.0f);
            e->rRoom = clampf(jnum(p, "room", 0.5f), 0.0f, 1.0f);
            e->rPre = clampf(jnum(p, "pre", 0.02f), 0.0f, 0.1f);
        }
    }

    /* 次谐波 */
    {
        const char *p = jfind(json, "sub");
        if (p && *p == '{') {
            e->sOn = jbool(p, "on");
            e->sAmt = clampf(jnum(p, "amt", 0.4f), 0.0f, 1.0f);
        }
    }

    /* 激励 */
    {
        const char *p = jfind(json, "exc");
        if (p && *p == '{') {
            e->xOn = jbool(p, "on");
            e->xAmt = clampf(jnum(p, "amt", 0.3f), 0.0f, 1.0f);
            e->xFreq = clampf(jnum(p, "freq", 3500.0f), 1000.0f, 8000.0f);
            for (int side = 0; side < 2; side++) {
                biquad_bandpass(&e->xBp[side], e->xFreq, e->rate);
                biquad_highpass(&e->xHp[side], e->xFreq, e->rate);
            }
        }
    }

    /* 抖晃 */
    {
        const char *p = jfind(json, "wow");
        if (p && *p == '{') {
            e->wOn = jbool(p, "on");
            e->wAmt = clampf(jnum(p, "amt", 0.2f), 0.0f, 1.0f);
        }
    }

    /* 3D 旋转 */
    {
        const char *p = jfind(json, "rotate");
        if (p && *p == '{') {
            e->rotOn = jbool(p, "on");
            e->rotRate = clampf(jnum(p, "rate", 0.12f), 0.05f, 0.5f);
        }
    }

    /* 展宽 / 空气感 / 增益 */
    e->width = clampf(jnum(json, "width", 0.0f), 0.0f, 1.0f);
    e->airDb = clampf(jnum(json, "air", 0.0f), 0.0f, 6.0f);
    {
        float g = clampf(jnum(json, "gain", 0.0f), -6.0f, 6.0f);
        e->gainLin = powf(10.0f, g / 20.0f);
        for (int side = 0; side < 2; side++)
            biquad_highshelf(&e->air[side], 12000.0f, e->airDb, e->rate);
    }
}

/* 启用/停用：内部约 12ms 交叉淡化防爆音 */
void animefx_set_bypass(void *ep, int bypass) {
    FxEngine *e = (FxEngine *)ep;
    if (!e) return;
    e->bypass = bypass ? 1 : 0;
    e->wetTarget = bypass ? 0.0f : 1.0f;
}

/* ================= 处理 ================= */

/* 梳状滤波器一步（Freeverb：反馈输出低通 + 回写，v1.3.330 修复真回环）
 * 旧实现低通的是 input（回环断裂，尾音只剩离散回声）；经典口径是
 * filterstore = LP(feedback output)，buf = input + filterstore * fb */
static inline float comb_tick(float *buf, int len, int *pos, float input, float fb, float damp, float *store) {
    float out = buf[*pos];
    *store = out * (1.0f - damp) + *store * damp;
    *store += 1e-20f; /* denormal */
    buf[*pos] = input + *store * fb;
    if (++*pos >= len) *pos = 0;
    return out;
}

/* 全通滤波器一步（fb=0.5） */
static inline float ap_tick(float *buf, int len, int *pos, float input) {
    float bufout = buf[*pos];
    float y = -input + bufout;
    buf[*pos] = input + bufout * 0.5f;
    if (++*pos >= len) *pos = 0;
    return y;
}

/* 环形缓冲线性插值读（抖晃延迟线），wPos 为写指针 */
static inline float delay_read(float *buf, int len, int wPos, float delay) {
    if (delay < 1.0f) delay = 1.0f;
    if (delay > (float)(len - 2)) delay = (float)(len - 2);
    float rp = (float)wPos - delay;
    while (rp < 0.0f) rp += (float)len;
    int i0 = (int)rp;
    int i1 = i0 + 1;
    if (i0 >= len) i0 -= len;
    if (i1 >= len) i1 -= len;
    float fr = rp - (float)i0;
    return buf[i0] * (1.0f - fr) + buf[i1] * fr;
}

void animefx_process(void *ep, short *pcm, int frames) {
    FxEngine *e = (FxEngine *)ep;
    if (!e || !pcm || frames <= 0) return;
    int ch = e->ch;

    /* 快路径：停用且已淡出 → 原样返回 */
    if (e->bypass && e->wet <= 0.0005f) {
        e->wet = 0.0f;
        return;
    }

    /* EQ 系数逐块向目标收敛（拖滑条无咔哒） */
    for (int b = 0; b < EQ_BANDS; b++) {
        if (e->eqGain[b] == 0.0f) continue; /* 0dB 恒等段不处理 */
        for (int k = 0; k < 5; k++)
            e->eqCur[b][k] += (e->eqTgt[b][k] - e->eqCur[b][k]) * 0.35f;
        for (int side = 0; side < 2; side++) {
            Biquad *q = &e->eq[b][side];
            q->b0 = e->eqCur[b][0]; q->b1 = e->eqCur[b][1]; q->b2 = e->eqCur[b][2];
            q->a1 = e->eqCur[b][3]; q->a2 = e->eqCur[b][4];
        }
    }

    /* 每块常量预计算 */
    float atkC = expf(-1.0f / (e->rate * e->cAtk));
    float relC = expf(-1.0f / (e->rate * e->cRel));
    float relCs = expf(-1.0f / (e->rate * e->cRel * 2.5f)); /* v1.3.330 程控释放：低于阈值慢收 */
    float mkupLin = powf(10.0f, e->cMkup / 20.0f);
    /* v1.3.330 混响：房间 0..1 → 反馈 0.74..0.87（尾长 0.8~2.2s）/ 阻尼 0.30..0.55 */
    float fb = 0.74f + e->rRoom * 0.13f;
    float damp = 0.30f + e->rRoom * 0.25f;
    int predSamp = (int)(e->rPre * e->rate);
    if (predSamp >= e->rpLen) predSamp = e->rpLen - 1;
    float wetRv = e->rMix * 0.85f; /* v1.3.331 量级校准：0.7→0.85 混响存在感达标 */
    float rotStep = 2.0f * (float)M_PI * e->rotRate / e->rate;
    float subStep = 2.0f * (float)M_PI * 55.0f / e->rate;
    float subLpA = expf(-2.0f * (float)M_PI * 80.0f / e->rate);
    float wLpA = expf(-2.0f * (float)M_PI * 250.0f / e->rate); /* 展宽低频保护 250Hz */
    float dcR = 1.0f - 6.2831853f * 15.0f / e->rate;           /* 输出 DC 阻隔 15Hz */

    for (int i = 0; i < frames; i++) {
        float L = pcm[i * ch] / 32768.0f;
        float R = (ch == 2) ? pcm[i * ch + 1] / 32768.0f : L;
        float dryL = L, dryR = R;
        float pL = L, pR = R;

        if (e->wet > 0.0005f) {
            /* ---- 10 段 EQ ---- */
            for (int b = 0; b < EQ_BANDS; b++) {
                if (e->eqGain[b] == 0.0f) continue;
                pL = biquad_tick(&e->eq[b][0], pL);
                if (ch == 2) pR = biquad_tick(&e->eq[b][1], pR);
            }

            /* ---- 次谐波低音（单声道和求包络，55Hz 基频 + 110Hz 泛音双八度） ---- */
            if (e->sOn && e->sAmt > 0.001f) {
                float mono = (pL + pR) * 0.5f;
                e->sLp += subLpA * (mono - e->sLp);
                float rect = fabsf(e->sLp);
                if (rect > e->sEnv) e->sEnv += 0.25f * (rect - e->sEnv);
                else e->sEnv += 0.0009f * (rect - e->sEnv); /* v1.3.330 释放 9ms→32ms 更厚 */
                e->sEnv += 1e-20f;
                e->sPhase += subStep;
                if (e->sPhase > 2.0f * (float)M_PI) e->sPhase -= 2.0f * (float)M_PI;
                float tone = (sinf(e->sPhase) + 0.35f * sinf(e->sPhase * 2.0f + 0.7f))
                             * e->sEnv * e->sAmt * 1.8f; /* v1.3.331 1.5→1.8 */
                pL += tone;
                if (ch == 2) pR += tone;
            }

            /* ---- 谐波激励（奇次软化 + rl² 偶次谐波注入，HP 滤除直流） ---- */
            if (e->xOn && e->xAmt > 0.001f) {
                float bpl = biquad_tick(&e->xBp[0], pL);
                float rl = fabsf(bpl);
                float hl = rl - rl * rl * rl * 0.35f + rl * rl * 0.3f;
                hl = biquad_tick(&e->xHp[0], hl) * e->xAmt * 1.1f; /* v1.3.331 0.55→1.1 量级达标 */
                pL += hl;
                if (ch == 2) {
                    float bpr = biquad_tick(&e->xBp[1], pR);
                    float rr = fabsf(bpr);
                    float hr = rr - rr * rr * rr * 0.35f + rr * rr * 0.3f;
                    hr = biquad_tick(&e->xHp[1], hr) * e->xAmt * 1.1f;
                    pR += hr;
                }
            }

            /* ---- 黑胶抖晃（双 LFO + 5.2Hz 微颤，双声道微差更像胶盘偏心） ---- */
            if (e->wOn && e->wAmt > 0.001f) {
                e->wPhase += 2.0f * (float)M_PI * 0.4f / e->rate;
                if (e->wPhase > 2.0f * (float)M_PI) e->wPhase -= 2.0f * (float)M_PI;
                float lfo = sinf(e->wPhase) + 0.4f * sinf(e->wPhase * 0.27f + 1.3f);
                float flut = sinf(e->wPhase * 13.0f) * 0.12f; /* 轴心微颤 */
                float depth = e->wAmt * 0.012f * e->rate; /* v1.3.331 0.003→0.012：旧值 100% 仅约 4 音分摆动无感，现约 16 音分明显复古 */
                float dly = depth * (0.5f + 0.3f * lfo + 0.06f * flut) + 1.0f;
                if (dly < 1.0f) dly = 1.0f;
                float wl = delay_read(e->wBuf[0], e->wLen, e->wPos, dly);
                e->wBuf[0][e->wPos] = pL;
                pL = wl;
                if (ch == 2) {
                    float wr = delay_read(e->wBuf[1], e->wLen, e->wPos, dly * 1.03f);
                    e->wBuf[1][e->wPos] = pR;
                    pR = wr;
                }
                if (++e->wPos >= e->wLen) e->wPos = 0;
            }

            /* ---- 压缩器（立体声联动峰值 + dB 域软拐点 + 程控释放） ---- */
            if (e->cOn) {
                float peak = fabsf(pL);
                if (ch == 2 && fabsf(pR) > peak) peak = fabsf(pR);
                float c = (peak > e->cEnv) ? atkC : relC;
                e->cEnv = c * e->cEnv + (1.0f - c) * peak;
                e->cEnv += 1e-20f;
                /* 软拐点：过阈 -3..+3dB 二次曲线过渡，起压更柔 */
                float envDb = 20.0f * log10f(e->cEnv + 1e-9f);
                float over = envDb - e->cThr;
                float grT = 0.0f;
                if (over > -3.0f) {
                    float slope = 1.0f - 1.0f / e->cRatio;
                    if (over < 3.0f) {
                        float t = over + 3.0f;
                        grT = -slope * t * t / 12.0f;
                    } else {
                        grT = -slope * over;
                    }
                }
                /* 程控释放：过阈中速回弹，低于阈值慢速收尾 */
                float gc = (grT < e->cGr) ? atkC : ((over > 0.0f) ? relC : relCs);
                e->cGr = gc * e->cGr + (1.0f - gc) * grT;
                float gLin = powf(10.0f, e->cGr / 20.0f) * mkupLin;
                pL *= gLin; pR *= gLin;
            }

            /* ---- 立体声展宽（M-S 矩阵，边信号 250Hz 以下不展宽保低频居中） ---- */
            if (ch == 2 && e->width > 0.001f) {
                float m = (pL + pR) * 0.5f;
                float s = (pL - pR) * 0.5f;
                e->wLp += wLpA * (s - e->wLp);
                e->wLp += 1e-20f;
                float sLow = e->wLp;
                float sHi = s - sLow;
                float sw = sHi * (1.0f + e->width) + sLow;
                pL = m + sw;
                pR = m - sw;
            }

            /* ---- 混响（预延时左右独立去相关 → 8 梳状并联 → 4 全通串联） ---- */
            if (e->rOn && e->rMix > 0.001f) {
                e->rpBuf[e->rpPos] = pL; /* v1.3.331 去 *0.5 衰减，混响量级达标 */
                e->rpBufR[e->rpPos] = pR;
                int pr = (e->rpPos + e->rpLen - predSamp) % e->rpLen;
                float rinL = e->rpBuf[pr];
                float rinR = e->rpBufR[pr];
                if (++e->rpPos >= e->rpLen) e->rpPos = 0;

                float cL = 0.0f, cR = 0.0f;
                for (int c = 0; c < RV_COMBS; c++) {
                    cL += comb_tick(e->rcBuf[0][c], e->rcLenL[c], &e->rcPosL[c], rinL, fb, damp, &e->rcStore[0][c]);
                    cR += comb_tick(e->rcBuf[1][c], e->rcLenR[c], &e->rcPosR[c], rinR, fb, damp, &e->rcStore[1][c]);
                }
                cL *= 0.125f; cR *= 0.125f;
                for (int a = 0; a < RV_APS; a++) {
                    cL = ap_tick(e->raBuf[0][a], e->raLenL[a], &e->raPosL[a], cL);
                    cR = ap_tick(e->raBuf[1][a], e->raLenR[a], &e->raPosR[a], cR);
                }
                pL += cL * wetRv;
                pR += cR * wetRv;
            }

            /* ---- 3D 声像旋转（恒功率 cos-sin） ---- */
            if (ch == 2 && e->rotOn) {
                e->rotPhase += rotStep;
                if (e->rotPhase > 2.0f * (float)M_PI) e->rotPhase -= 2.0f * (float)M_PI;
                float cl = cosf(e->rotPhase), sl = sinf(e->rotPhase);
                float nl = pL * cl + pR * sl;
                float nr = pR * cl - pL * sl;
                pL = nl; pR = nr;
            }

            /* ---- 空气感 ---- */
            if (e->airDb > 0.01f) {
                pL = biquad_tick(&e->air[0], pL);
                if (ch == 2) pR = biquad_tick(&e->air[1], pR);
            }
        }

        /* ---- 湿干交叉 + 输出增益 + DC 阻隔 + 软限幅 ---- */
        float outL = dryL + (pL - dryL) * e->wet;
        float outR = dryR + (pR - dryR) * e->wet;
        outL *= e->gainLin;
        outR *= e->gainLin;
        /* 15Hz DC 阻隔：清激励/次谐波路径直流失调（防扬声器偏移） */
        float dL = outL - e->dcX[0] + dcR * e->dcY[0];
        e->dcX[0] = outL; e->dcY[0] = dL + 1e-20f;
        outL = dL;
        if (ch == 2) {
            float dR = outR - e->dcX[1] + dcR * e->dcY[1];
            e->dcX[1] = outR; e->dcY[1] = dR + 1e-20f;
            outR = dR;
        }
        outL = softclip(outL);
        outR = softclip(outR);
        if (!isfinite(outL)) outL = 0.0f;
        if (!isfinite(outR)) outR = 0.0f;

        pcm[i * ch] = (short)clampf(outL * 32767.0f, -32768.0f, 32767.0f);
        if (ch == 2) pcm[i * ch + 1] = (short)clampf(outR * 32767.0f, -32768.0f, 32767.0f);

        /* 交叉淡化步进（约 12ms 收敛） */
        e->wet += (e->wetTarget - e->wet) * 0.004f;
    }
}

/* 注：官方 JNI 桥段（Java_www_anime_bzxhkj_com_AnimeFx_*）已按接入文档移除——
 * 本项目经 Rust FFI 直调上述 animefx_* 接口，无需 JNI 导出符号。 */
