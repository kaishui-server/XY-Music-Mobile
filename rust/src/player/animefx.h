/*
 * animemusic 音效引擎对外接口（animefx.h）
 * 开放平台随 animefx.c 一并提供，第三方软件 include 本头文件接入。
 * 详见使用文档：https://open.anime.bzxhkj.com/docs.php
 */
#ifndef ANIMEFX_H
#define ANIMEFX_H

#ifdef __cplusplus
extern "C" {
#endif

/* 创建引擎：rate=采样率（<8000 按 44100 处理）ch=声道数（1 或 2，其余按 2）
 * 返回引擎句柄（不透明指针），失败返回 NULL */
void *animefx_create(int rate, int ch);

/* 释放引擎（NULL 安全） */
void animefx_destroy(void *ep);

/* 清空内部缓冲与滤波状态（seek/换曲用）：保留参数与系数，音效立即恢复无空窗 */
void animefx_reset(void *ep);

/* 套用调音参数 JSON（schema 见开放平台使用文档「参数定义」；非法值自动钳制不报错）
 * 例：{"eq":[2,1.5,0.5,0,-0.5,-0.5,0,0,0.5,0.5],"comp":{"on":1,"thr":-16,...},...} */
void animefx_set_params(void *ep, const char *json);

/* 启用/停用音效：内部约 12ms 交叉淡化，开合无缝防爆音；停用后进入零开销快路径 */
void animefx_set_bypass(void *ep, int bypass);

/* 原地处理 PCM16 交错样本：pcm 长度必须 = frames * 引擎声道数（create 时传入的 ch）
 * 线程约定：本函数与 set_params/set_bypass 由调用方串行化（同一播放器线程或加锁） */
void animefx_process(void *ep, short *pcm, int frames);

#ifdef __cplusplus
}
#endif

#endif /* ANIMEFX_H */
