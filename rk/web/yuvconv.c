/*
 * yuvconv.c —— MIPI YUV -> BGR888 高速转换 (Python 版的 C 实现)
 *
 * 为什么需要它:
 *   mipi_webstream.py 里用 numpy/cv2 做 YUV->BGR, 实测 1920x1080 要 55~67ms,
 *   成了整条 1080p60 流水线的瓶颈 (编码只要 18ms, 采集只要 17ms)。
 *   OpenCV 自带的 cvtColor 只要 4.5ms, 但它按 **BT.601 + full range** 解释,
 *   而本工程 FPGA 送的是 **BT.709 + limited(16~235)**, 直接用会偏灰偏绿。
 *   所以这里用 C 重写同一套整数查表算法:
 *       Y' = clip((Y-16)*255/219, 0, 255)
 *       B  = clip(Y' + 1.8556*(Cb-128)')
 *       G  = clip(Y' - 0.1873*(Cb-128)' - 0.4681*(Cr-128)')
 *       R  = clip(Y' + 1.5748*(Cr-128)')
 *   (Cb-128)' = (Cb-128)*255/224, 系数与 Python 版 YUV_MATRIX["709"] 一致
 *
 * 用法 (ctypes):
 *   lib.yuvconv_nv16_to_bgr(src, dst, w, h, swap_uv, matrix, range)
 *
 * 编译: 见同目录 build_yuvconv.sh
 */
#include <math.h>
#include <stdint.h>
#include <string.h>

#define MATRIX_601 601
#define MATRIX_709 709
#define RANGE_LIMITED 0
#define RANGE_FULL 1

static int16_t g_lutY[256];
static int16_t g_lutB[256];  /* Cb -> B */
static int16_t g_lutGU[256]; /* Cb -> G */
static int16_t g_lutGV[256]; /* Cr -> G */
static int16_t g_lutR[256];  /* Cr -> R */
static int g_key = -1;

static void build_tables(int matrix, int range)
{
    double kr, kgu, kgv, kb;
    int i;

    if (matrix == MATRIX_601)
    {
        kr = 1.402000;
        kgu = -0.344136;
        kgv = -0.714136;
        kb = 1.772000;
    }
    else
    {
        kr = 1.574800;
        kgu = -0.187300;
        kgv = -0.468100;
        kb = 1.855600;
    }

    for (i = 0; i < 256; i++)
    {
        double yv, c;
        if (range == RANGE_LIMITED)
        {
            yv = (i - 16.0) * (255.0 / 219.0);
            if (yv < 0.0)
                yv = 0.0;
            if (yv > 255.0)
                yv = 255.0;
            c = (i - 128.0) * (255.0 / 224.0);
        }
        else
        {
            yv = (double)i;
            c = (double)i - 128.0;
        }
        g_lutY[i] = (int16_t)lrint(yv);
        g_lutB[i] = (int16_t)lrint(kb * c);
        g_lutGU[i] = (int16_t)lrint(kgu * c);
        g_lutGV[i] = (int16_t)lrint(kgv * c);
        g_lutR[i] = (int16_t)lrint(kr * c);
    }
    g_key = matrix * 2 + range;
}

static inline uint8_t clip8(int v)
{
    if (v < 0)
        return 0;
    if (v > 255)
        return 255;
    return (uint8_t)v;
}

/* 处理一行: yrow 有 w 个亮度, uvrow 有 w 个字节 (每 2 像素共用 1 组 U/V),
 * dst 有 w*3 个 BGR 字节。
 *
 * 优化点:
 *   - 一次循环处理 4 个像素(2 组 UV), 给编译器更多指令级并行
 *   - 6/12 个字节用 memcpy(4B+2B) 写出, 代替逐字节存储
 */
static void conv_row_422(const uint8_t *restrict yrow,
                         const uint8_t *restrict uvrow,
                         uint8_t *restrict dst, int w)
{
    int j = 0;
    for (; j + 4 <= w; j += 4)
    {
        int u0 = uvrow[j], v0 = uvrow[j + 1];
        int u1 = uvrow[j + 2], v1 = uvrow[j + 3];
        int b0 = g_lutB[u0], g0 = g_lutGU[u0] + g_lutGV[v0], r0 = g_lutR[v0];
        int b1 = g_lutB[u1], g1 = g_lutGU[u1] + g_lutGV[v1], r1 = g_lutR[v1];
        int y0 = g_lutY[yrow[j]];
        int y1 = g_lutY[yrow[j + 1]];
        int y2 = g_lutY[yrow[j + 2]];
        int y3 = g_lutY[yrow[j + 3]];
        uint32_t wa, wb;
        uint16_t ta, tb;

        wa = (uint32_t)clip8(y0 + b0) | ((uint32_t)clip8(y0 + g0) << 8) | ((uint32_t)clip8(y0 + r0) << 16) | ((uint32_t)clip8(y1 + b0) << 24);
        ta = (uint16_t)clip8(y1 + g0) | ((uint16_t)clip8(y1 + r0) << 8);
        wb = (uint32_t)clip8(y2 + b1) | ((uint32_t)clip8(y2 + g1) << 8) | ((uint32_t)clip8(y2 + r1) << 16) | ((uint32_t)clip8(y3 + b1) << 24);
        tb = (uint16_t)clip8(y3 + g1) | ((uint16_t)clip8(y3 + r1) << 8);

        memcpy(dst, &wa, 4);
        memcpy(dst + 4, &ta, 2);
        memcpy(dst + 6, &wb, 4);
        memcpy(dst + 10, &tb, 2);
        dst += 12;
    }
    for (; j < w; j += 2)
    { /* w%4 != 0 的尾巴 */
        int y0 = g_lutY[yrow[j]];
        int y1 = g_lutY[yrow[j + 1]];
        int u = uvrow[j], v = uvrow[j + 1];
        int b = g_lutB[u];
        int gs = g_lutGU[u] + g_lutGV[v];
        int r = g_lutR[v];
        uint32_t lo;
        uint16_t hi;
        lo = (uint32_t)clip8(y0 + b) | ((uint32_t)clip8(y0 + gs) << 8) | ((uint32_t)clip8(y0 + r) << 16) | ((uint32_t)clip8(y1 + b) << 24);
        hi = (uint16_t)clip8(y1 + gs) | ((uint16_t)clip8(y1 + r) << 8);
        memcpy(dst, &lo, 4);
        memcpy(dst + 4, &hi, 2);
        dst += 6;
    }
}

/*
 * 按行切片版本 —— 供多线程并发调用 (每段行号不同, 互不影响)。
 *
 * y     : 该段第一行的 Y 起始地址
 * uv    : 该段第一行的 UV 起始地址
 * dst   : 该段第一行的 BGR 起始地址
 * rows  : 本段行数
 * uv_stride : UV 平面每行字节数 (= w, 供调用方传 stride)
 * 这样调用方只需传偏移指针, 不必依赖整帧连续。
 */
int yuvconv_nv16_to_bgr_rows(const uint8_t *y, const uint8_t *uv,
                             uint8_t *dst, int w, int rows, int uv_stride,
                             int swap_uv, int matrix, int range)
{
    int row, key;

    if (!y || !uv || !dst || w <= 0 || rows <= 0 || (w & 1))
        return -1;
    key = matrix * 2 + range;
    if (key != g_key)
        build_tables(matrix, range);

    for (row = 0; row < rows; row++)
    {
        const uint8_t *yrow = y + (size_t)row * w;
        const uint8_t *uvrow = uv + (size_t)row * uv_stride;
        uint8_t *drow = dst + (size_t)row * w * 3;

        if (swap_uv)
        {
            int j;
            for (j = 0; j < w; j += 2)
            {
                int y0 = g_lutY[yrow[j]];
                int y1 = g_lutY[yrow[j + 1]];
                int u = uvrow[j + 1]; /* 交换 U/V */
                int v = uvrow[j];
                int b = g_lutB[u];
                int gs = g_lutGU[u] + g_lutGV[v];
                int r = g_lutR[v];
                uint32_t lo;
                uint16_t hi;
                lo = (uint32_t)clip8(y0 + b) | ((uint32_t)clip8(y0 + gs) << 8) | ((uint32_t)clip8(y0 + r) << 16) | ((uint32_t)clip8(y1 + b) << 24);
                hi = (uint16_t)clip8(y1 + gs) | ((uint16_t)clip8(y1 + r) << 8);
                memcpy(drow, &lo, 4);
                memcpy(drow + 4, &hi, 2);
                drow += 6;
            }
        }
        else
        {
            conv_row_422(yrow, uvrow, drow, w);
        }
    }
    return 0;
}

/*
 * 便捷封装: src = [Y 平面 w*h][UV 交织平面 h*(w/2)*2], dst = w*h*3 的 BGR
 * swap_uv != 0 时交换 U/V 分量
 * 返回 0 成功, -1 参数错误
 */
int yuvconv_nv16_to_bgr(const uint8_t *src, uint8_t *dst,
                        int w, int h, int swap_uv, int matrix, int range)
{
    if (!src || !dst || w <= 0 || h <= 0 || (w & 1))
        return -1;
    return yuvconv_nv16_to_bgr_rows(src, src + (size_t)w * h, dst,
                                    w, h, w, swap_uv, matrix, range);
}

/*
 * NV12 / NV21: src = [Y w*h][UV (h/2)*(w/2)*2]
 * swap_uv != 0 -> NV21 (V 在前)
 */
int yuvconv_nv12_to_bgr(const uint8_t *src, uint8_t *dst,
                        int w, int h, int swap_uv, int matrix, int range)
{
    const uint8_t *yplane, *uvplane;
    int row, col, key;

    if (!src || !dst || w <= 0 || h <= 0 || (w & 1) || (h & 1))
        return -1;
    key = matrix * 2 + range;
    if (key != g_key)
        build_tables(matrix, range);

    yplane = src;
    uvplane = src + (size_t)w * h;

    for (row = 0; row < h; row++)
    {
        const uint8_t *uvrow = uvplane + (size_t)(row >> 1) * w; /* 每 2 行共用 */
        const uint8_t *yrow = yplane + (size_t)row * w;
        uint8_t *drow = dst + (size_t)row * w * 3;
        for (col = 0; col < w; col += 2)
        {
            int y0 = g_lutY[yrow[col]];
            int y1 = g_lutY[yrow[col + 1]];
            int a = uvrow[col];
            int b = uvrow[col + 1];
            int u = swap_uv ? b : a;
            int v = swap_uv ? a : b;
            int bu = g_lutB[u], gu = g_lutGU[u];
            int gv = g_lutGV[v], rv = g_lutR[v];
            int gsum = gu + gv;
            drow[0] = clip8(y0 + bu);
            drow[1] = clip8(y0 + gsum);
            drow[2] = clip8(y0 + rv);
            drow[3] = clip8(y1 + bu);
            drow[4] = clip8(y1 + gsum);
            drow[5] = clip8(y1 + rv);
            drow += 6;
        }
    }
    return 0;
}

const char *yuvconv_version(void) { return "yuvconv 1.0 (nv16/nv12 -> BGR)"; }
