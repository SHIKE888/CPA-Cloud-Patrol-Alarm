/*
 * Milianke virtual MIPI CSI-2 sensor driver for FPGA video source.
 */

#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of_graph.h>
#include <linux/slab.h>
#include <linux/version.h>
#include <linux/compat.h>
#include <media/media-entity.h>
#include <media/v4l2-async.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-mediabus.h>
#include <media/v4l2-subdev.h>

#ifndef RKMODULE_API_VERSION
#define RKMODULE_NAME_LEN 32
#define RKMODULE_LSCDATA_LEN 289
#define RKMODULE_HDR_NONE 0x00
#define RKMODULE_HDR_X2 0x05
#define RKMODULE_HDR_X3 0x06

struct rkmodule_base_inf
{
    char sensor[RKMODULE_NAME_LEN];
    char module[RKMODULE_NAME_LEN];
    char lens[RKMODULE_NAME_LEN];
};

struct rkmodule_inf
{
    struct rkmodule_base_inf base;
    /* other fields (fuse/awb/af/lsc) unused here */
    char reserved[2048];
};

struct rkmodule_hdr_cfg
{
    __u32 hdr_mode;
    __u32 esp[8];
};

#define RKMODULE_GET_MODULE_INFO _IOR('W', 0x03, struct rkmodule_inf)
#define RKMODULE_GET_HDR_CFG _IOR('W', 0x0b, struct rkmodule_hdr_cfg)
#define RKMODULE_SET_HDR_CFG _IOW('W', 0x0c, struct rkmodule_hdr_cfg)
#define RKMODULE_SET_QUICK_STREAM _IOW('W', 0x0d, __u32)
#endif

/*
 * ==== 分辨率模式表 (Phase C) ====
 *
 * 每个条目必须与 FPGA 端 system_top.v 里的 S_res_mode 模式表一一对应:
 *     S_res_mode = 0  ->  milianke_modes[0]
 *     S_res_mode = 1  ->  milianke_modes[1]
 * FPGA 侧的切换由 I2C 写 regfile 0xE0 (RES_MODE) 完成;
 * 本驱动侧由用户态走 VIDIOC_SUBDEV_S_FMT
 * (v4l2-ctl -d /dev/videoXX --set-fmt-video=width=..,height=..)
 * 选中对应尺寸, 或开机时用 milianke_mipi.default_mode=N 指定。
 * **两侧必须保持一致**, 否则 rkcif 会按错误的尺寸解析数据流。
 *
 * link_freq : MIPI D-PHY 的 DDR 时钟 (Hz) = lane_rate / 2 = 4 x byte_clk。
 *             DTS 里没有写任何速率属性, rkcif 直接拿这个值去配 D-PHY,
 *             所以 FPGA 侧 PLL 一改, 这里所有条目都要跟着改。
 *             当前 FPGA (V22, 已回退 PLL):
 *                 VCO 1000MHz -> byte_clk 125MHz -> lane 1000Mbps
 *                 => link_freq = 125MHz x 4 = 500000000
 *             (V21 曾试过 VCO 1200MHz -> byte 150MHz -> 600000000,
 *              但 1200Mbps 下 FPGA 内部 600MHz 时序收敛不了, 画面花屏,
 *              已回退; 想重上 1200Mbps 必须先做时序收敛。)
 * pixel_rate: FPGA VTC 的像素时钟 (Hz) = htotal x vtotal x fps
 * vblank    : vtotal - vactive
 */
struct milianke_mode
{
    u32 width;
    u32 height;
    u32 fps_num;
    u32 fps_den;
    u64 link_freq;
    u64 pixel_rate;
    u32 vblank;
    const char *name;
};

static const struct milianke_mode milianke_modes[] = {
    /* FPGA VTC 2200x1125 @147.5MHz -> 147.5e6/(2200*1125) = 59.6fps */
    {1920, 1080, 1, 60, 500000000ULL, 148500000ULL, 45, "1920x1080@60"},
    /* FPGA VTC 2060x2864 @147.5MHz -> 25.0fps, 414.7MB/s = 82.9% 带宽 (4K 实际可用档) */
    {3840, 2160, 1, 25, 500000000ULL, 147500000ULL, 704, "3840x2160@25"},
    /* FPGA VTC 2060x2387 @147.5MHz -> 30.0fps, 但 497.7MB/s = 99.5% 带宽跑不动 */
    {3840, 2160, 1, 30, 500000000ULL, 147500000ULL, 227, "3840x2160@30"},
};

#define MILIANKE_NUM_MODES ARRAY_SIZE(milianke_modes)

static bool always_on = true;
module_param(always_on, bool, 0644);
MODULE_PARM_DESC(always_on,
                 "Assert mipi-en GPIO at probe so FPGA starts HS before DPHY (default: true)");

/* 开机默认模式索引; 0 = 1920x1080@60 (对应 FPGA S_res_mode=0) */
static uint default_mode = 0;
module_param(default_mode, uint, 0644);
MODULE_PARM_DESC(default_mode,
                 "Default mode index into milianke_modes[] (0=1920x1080@60, 1=3840x2160@30)");

/* 所有模式共用同一个 D-PHY 速率 (FPGA PLL 与分辨率无关), 所以菜单只有一项 */
static const s64 link_freq_menu[] = {500000000};

struct milianke_mipi
{
    struct v4l2_subdev subdev;
    struct media_pad pad;
    struct v4l2_ctrl_handler ctrl_handler;
    struct v4l2_ctrl *link_freq;
    struct v4l2_ctrl *pixel_rate;
    struct v4l2_ctrl *vblank;
    struct mutex mutex;
    struct gpio_desc *mipi_en_gpio;
    bool streaming;
    const char *module_name;
    const char *lens_name;
    const char *module_facing;
    u32 module_index;
    /* 当前选中的模式索引 (对应 FPGA S_res_mode), 由 set_fmt 更新 */
    u32 mode_index;
};

static int milianke_g_volatile_ctrl(struct v4l2_ctrl *ctrl)
{
    switch (ctrl->id)
    {
    case V4L2_CID_LINK_FREQ:
        ctrl->val = 0;
        break;
    case V4L2_CID_PIXEL_RATE:
    {
        struct milianke_mipi *sensor =
            container_of(ctrl->handler, struct milianke_mipi,
                         ctrl_handler);
        u32 idx = sensor->mode_index;

        if (idx >= MILIANKE_NUM_MODES)
            idx = 0;
        ctrl->val = (s32)milianke_modes[idx].pixel_rate;
        break;
    }
    default:
        return -EINVAL;
    }

    return 0;
}

static const struct v4l2_ctrl_ops milianke_ctrl_ops = {
    .g_volatile_ctrl = milianke_g_volatile_ctrl,
};

static int milianke_enum_mbus_code(struct v4l2_subdev *sd,
                                   struct v4l2_subdev_state *state,
                                   struct v4l2_subdev_mbus_code_enum *code)
{
    if (code->index > 0)
        return -EINVAL;

    code->code = MEDIA_BUS_FMT_YUYV8_2X8;

    return 0;
}

static int milianke_enum_frame_size(struct v4l2_subdev *sd,
                                    struct v4l2_subdev_state *state,
                                    struct v4l2_subdev_frame_size_enum *fse)
{
    if (fse->index >= MILIANKE_NUM_MODES)
        return -EINVAL;

    fse->min_width = milianke_modes[fse->index].width;
    fse->max_width = milianke_modes[fse->index].width;
    fse->min_height = milianke_modes[fse->index].height;
    fse->max_height = milianke_modes[fse->index].height;

    return 0;
}

/*
 * 把模式表里的一个条目填进 V4L2 格式结构体。
 * 色彩空间见下面那段注释: FPGA 输出 = BT.709 + limited range(16~235),
 * 绝不能声明成 sRGB(full range), 否则画面发灰发绿。
 */
static void milianke_fill_fmt(struct v4l2_subdev_format *fmt,
                              const struct milianke_mode *mode)
{
    fmt->format.width = mode->width;
    fmt->format.height = mode->height;
    fmt->format.code = MEDIA_BUS_FMT_YUYV8_2X8;
    fmt->format.field = V4L2_FIELD_NONE;
    /*
     * ==== 色彩空间（重要，改过） ====
     *
     * FPGA 端 rgb_to_yuv422_quad.v 用的是 **BT.709 + limited range**：
     *     Y = 0.183R + 0.614G + 0.062B + 16
     * 系数和 0.859 = 219/255，且 (0.183,0.614,0.062) 与 BT.709 的
     * (0.2126,0.7152,0.0722) x 219/255 吻合；抓帧实测 Y 范围 22~234
     * （limited 白点 = 235）。所以黑点=16、白点=235。
     *
     * 原来这里写的是 V4L2_COLORSPACE_SRGB，而 sRGB 的默认 quantization 是
     * **full range(0~255)**，导致 rkcif/rkisp 把 limited 数据当 full 处理：
     * 黑电平被抬到 16/255、白点只到 235、色度欠饱和 —— 画面发灰、发绿、
     * 颜色很怪（HDMI / kmssink 输出同样受影响）。
     *
     * 改成 REC709 + LIM_RANGE 后整条 RK 侧链路（ISP -> VPSS -> kmssink/HDMI）
     * 都会按正确的方式做 YUV->RGB。
     */
    fmt->format.colorspace = V4L2_COLORSPACE_REC709;
    fmt->format.ycbcr_enc = V4L2_YCBCR_ENC_709;
    fmt->format.quantization = V4L2_QUANTIZATION_LIM_RANGE;
    fmt->format.xfer_func = V4L2_XFER_FUNC_709;
}

static int milianke_get_fmt(struct v4l2_subdev *sd,
                            struct v4l2_subdev_state *state,
                            struct v4l2_subdev_format *fmt)
{
    struct milianke_mipi *sensor =
        container_of(sd, struct milianke_mipi, subdev);
    u32 idx = sensor->mode_index;

    if (idx >= MILIANKE_NUM_MODES)
        idx = 0;

    milianke_fill_fmt(fmt, &milianke_modes[idx]);

    return 0;
}

/*
 * 选择模式: 精确匹配宽高优先, 否则取像素数最接近的那个。
 * 只有 ACTIVE 格式才真正改变状态; TRY 格式只回报结果。
 */
static int milianke_set_fmt(struct v4l2_subdev *sd,
                            struct v4l2_subdev_state *state,
                            struct v4l2_subdev_format *fmt)
{
    struct milianke_mipi *sensor =
        container_of(sd, struct milianke_mipi, subdev);
    u32 want_w = fmt->format.width;
    u32 want_h = fmt->format.height;
    u64 want = (u64)want_w * want_h;
    u64 best_diff = ~0ULL;
    u32 i, best = 0;

    for (i = 0; i < MILIANKE_NUM_MODES; i++)
    {
        u64 have = (u64)milianke_modes[i].width *
                   milianke_modes[i].height;
        u64 diff;

        if (milianke_modes[i].width == want_w &&
            milianke_modes[i].height == want_h)
        {
            best = i;
            goto done;
        }
        diff = (have > want) ? (have - want) : (want - have);
        if (diff < best_diff)
        {
            best_diff = diff;
            best = i;
        }
    }

done:
    if (fmt->which == V4L2_SUBDEV_FORMAT_ACTIVE)
        sensor->mode_index = best;

    milianke_fill_fmt(fmt, &milianke_modes[best]);

    return 0;
}

static int milianke_enum_frame_interval(struct v4l2_subdev *sd,
                                        struct v4l2_subdev_state *state,
                                        struct v4l2_subdev_frame_interval_enum *fie)
{
    u32 i, idx = 0;

    /*
     * V4L2 规范里 enum_frame_interval 是"枚举器": 调用方给 index,
     * 我们回答"第 index 个可用的 (宽, 高, 帧率)"组合。
     *
     *  - 调用方给了非 0 的 width/height 时, 只在匹配这些尺寸的模式里数 index;
     *  - width/height 为 0 表示"不过滤", 数全部模式。
     *
     * ★ 为什么必须支持 width/height == 0:
     *   rkcif 的 rkcif_create_dummy_buf() 就是 memset(fie,0) 之后只设
     *   fie.index, 然后逐个 index 调用本回调, 用返回的
     *       size = fie.width * fie.height * 2
     *   取所有模式的最大值来决定 dummy buffer 要多大。
     *   旧实现把 width/height 当"必须匹配的过滤器", 遇到 width==0 就一路
     *   continue 最后返回 -EINVAL -> rkcif 的循环立刻 break -> max_size 保持 0
     *   -> rkcif_alloc_buffer(size=0) 返回 -EINVAL -> 用户侧看到
     *      "VIDIOC_STREAMON returned -1 (Cannot allocate memory)"。
     *   1080p 时因为 get_fmt 兜底路径偶尔能拿到尺寸所以"看起来正常",
     *   4K 时更依赖这条枚举路径, 于是 4K 完全起不来。
     */
    for (i = 0; i < MILIANKE_NUM_MODES; i++)
    {
        if (fie->width && fie->height &&
            (fie->width != milianke_modes[i].width ||
             fie->height != milianke_modes[i].height))
            continue;
        if (idx == fie->index)
        {
            fie->width = milianke_modes[i].width;
            fie->height = milianke_modes[i].height;
            fie->code = MEDIA_BUS_FMT_YUYV8_2X8;
            fie->interval.numerator = milianke_modes[i].fps_num;
            fie->interval.denominator = milianke_modes[i].fps_den;
            return 0;
        }
        idx++;
    }

    return -EINVAL;
}

static int milianke_g_frame_interval(struct v4l2_subdev *sd,
                                     struct v4l2_subdev_frame_interval *fi)
{
    struct milianke_mipi *sensor =
        container_of(sd, struct milianke_mipi, subdev);
    u32 idx = sensor->mode_index;

    if (idx >= MILIANKE_NUM_MODES)
        idx = 0;

    fi->interval.numerator = milianke_modes[idx].fps_num;
    fi->interval.denominator = milianke_modes[idx].fps_den;

    return 0;
}

static int milianke_g_mbus_config(struct v4l2_subdev *sd, unsigned int pad,
                                  struct v4l2_mbus_config *config)
{
    if (!config)
        return -EINVAL;

    memset(config, 0, sizeof(*config));
    config->type = V4L2_MBUS_CSI2_DPHY;
    config->bus.mipi_csi2.num_data_lanes = 4;
    /* Continuous clock = absence of NONCONTINUOUS flag; keep 0. */
    config->bus.mipi_csi2.flags = 0;

    return 0;
}

static int milianke_s_stream(struct v4l2_subdev *sd, int on)
{
    struct milianke_mipi *sensor =
        container_of(sd, struct milianke_mipi, subdev);

    mutex_lock(&sensor->mutex);
    if (sensor->mipi_en_gpio)
    {

        gpiod_set_value_cansleep(sensor->mipi_en_gpio, on ? 1 : 0);
    }
    sensor->streaming = !!on;
    mutex_unlock(&sensor->mutex);

    dev_info(sd->dev, "s_stream(%d): mipi-en GPIO toggled %s\n",
             on, on ? "HIGH" : "LOW");
    return 0;
}

static int milianke_s_power(struct v4l2_subdev *sd, int on)
{
    /* No power rails to toggle; GPIO handled in s_stream. */
    dev_dbg(sd->dev, "s_power(%d)\n", on);
    return 0;
}

static long milianke_priv_ioctl(struct v4l2_subdev *sd, unsigned int cmd,
                                void *arg)
{
    struct milianke_mipi *sensor =
        container_of(sd, struct milianke_mipi, subdev);
    struct rkmodule_inf *inf;
    struct rkmodule_hdr_cfg *hdr;
    u32 *stream;

    switch (cmd)
    {
    case RKMODULE_GET_MODULE_INFO:
        inf = arg;
        if (!inf)
            return -EINVAL;
        memset(inf, 0, sizeof(*inf));
        strscpy(inf->base.sensor, "FPGA-MIPI",
                sizeof(inf->base.sensor));
        if (sensor->module_name)
            strscpy(inf->base.module, sensor->module_name,
                    sizeof(inf->base.module));
        if (sensor->lens_name)
            strscpy(inf->base.lens, sensor->lens_name,
                    sizeof(inf->base.lens));
        return 0;
    case RKMODULE_GET_HDR_CFG:
        hdr = arg;
        if (!hdr)
            return -EINVAL;
        memset(hdr, 0, sizeof(*hdr));
        hdr->hdr_mode = RKMODULE_HDR_NONE;
        return 0;
    case RKMODULE_SET_HDR_CFG:
        hdr = arg;
        if (!hdr)
            return -EINVAL;
        if (hdr->hdr_mode != RKMODULE_HDR_NONE)
            return -EINVAL;
        return 0;
    case RKMODULE_SET_QUICK_STREAM:
        stream = arg;
        if (!stream)
            return -EINVAL;
        return milianke_s_stream(sd, *stream);
    default:
        return -ENOIOCTLCMD;
    }
}

#ifdef CONFIG_COMPAT
static long milianke_priv_compat_ioctl(struct v4l2_subdev *sd, unsigned int cmd,
                                       unsigned long arg)
{
    void __user *up = compat_ptr(arg);
    long ret;

    switch (cmd)
    {
    case RKMODULE_GET_MODULE_INFO:
    {
        struct rkmodule_inf *inf;

        inf = kzalloc(sizeof(*inf), GFP_KERNEL);
        if (!inf)
            return -ENOMEM;
        ret = milianke_priv_ioctl(sd, cmd, inf);
        if (!ret && copy_to_user(up, inf, sizeof(*inf)))
            ret = -EFAULT;
        kfree(inf);
        return ret;
    }
    case RKMODULE_GET_HDR_CFG:
    {
        struct rkmodule_hdr_cfg *hdr;

        hdr = kzalloc(sizeof(*hdr), GFP_KERNEL);
        if (!hdr)
            return -ENOMEM;
        ret = milianke_priv_ioctl(sd, cmd, hdr);
        if (!ret && copy_to_user(up, hdr, sizeof(*hdr)))
            ret = -EFAULT;
        kfree(hdr);
        return ret;
    }
    case RKMODULE_SET_HDR_CFG:
    {
        struct rkmodule_hdr_cfg hdr;

        if (copy_from_user(&hdr, up, sizeof(hdr)))
            return -EFAULT;
        return milianke_priv_ioctl(sd, cmd, &hdr);
    }
    case RKMODULE_SET_QUICK_STREAM:
    {
        u32 stream;

        if (copy_from_user(&stream, up, sizeof(stream)))
            return -EFAULT;
        return milianke_priv_ioctl(sd, cmd, &stream);
    }
    default:
        return -ENOIOCTLCMD;
    }
}
#endif

static const struct v4l2_subdev_core_ops milianke_core_ops = {
    .s_power = milianke_s_power,
    .ioctl = milianke_priv_ioctl,
#ifdef CONFIG_COMPAT
    .compat_ioctl32 = milianke_priv_compat_ioctl,
#endif
};

static const struct v4l2_subdev_pad_ops milianke_pad_ops = {
    .enum_mbus_code = milianke_enum_mbus_code,
    .enum_frame_size = milianke_enum_frame_size,
    .get_fmt = milianke_get_fmt,
    .set_fmt = milianke_set_fmt,
    .enum_frame_interval = milianke_enum_frame_interval,
    .get_mbus_config = milianke_g_mbus_config,
};

static const struct v4l2_subdev_video_ops milianke_video_ops = {
    .g_frame_interval = milianke_g_frame_interval,
    .s_stream = milianke_s_stream,
};

static const struct v4l2_subdev_ops milianke_subdev_ops = {
    .core = &milianke_core_ops,
    .pad = &milianke_pad_ops,
    .video = &milianke_video_ops,
};

static int milianke_probe(struct i2c_client *client,
                          const struct i2c_device_id *id)
{
    struct milianke_mipi *sensor;
    struct device_node *np = client->dev.of_node;
    struct v4l2_subdev *sd;
    char sd_name[V4L2_SUBDEV_NAME_SIZE];
    int ret;

    sensor = devm_kzalloc(&client->dev, sizeof(*sensor), GFP_KERNEL);
    if (!sensor)
        return -ENOMEM;

    if (np)
    {
        of_property_read_u32(np, "rockchip,camera-module-index",
                             &sensor->module_index);
        of_property_read_string(np, "rockchip,camera-module-facing",
                                &sensor->module_facing);
        of_property_read_string(np, "rockchip,camera-module-name",
                                &sensor->module_name);
        of_property_read_string(np, "rockchip,camera-module-lens-name",
                                &sensor->lens_name);
    }

    /* 模式表默认值 (可用 milianke_mipi.default_mode=N 覆盖) */
    if (default_mode >= MILIANKE_NUM_MODES)
    {
        dev_warn(&client->dev,
                 "default_mode=%u out of range, fallback to 0 (%s)\n",
                 default_mode, milianke_modes[0].name);
        default_mode = 0;
    }
    sensor->mode_index = default_mode;

    mutex_init(&sensor->mutex);

    sd = &sensor->subdev;
    v4l2_i2c_subdev_init(sd, client, &milianke_subdev_ops);
    sd->flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;

    snprintf(sd_name, sizeof(sd_name), "m%02d_%s_%s %s",
             sensor->module_index,
             sensor->module_facing ? sensor->module_facing : "b",
             sensor->module_name ? sensor->module_name : "fpga-mipi",
             dev_name(sd->dev));
    strscpy(sd->name, sd_name, sizeof(sd->name));

    sensor->pad.flags = MEDIA_PAD_FL_SOURCE;
    sd->entity.function = MEDIA_ENT_F_CAM_SENSOR;
    ret = media_entity_pads_init(&sd->entity, 1, &sensor->pad);
    if (ret)
        goto err_mutex;

    v4l2_ctrl_handler_init(&sensor->ctrl_handler, 3);
    sensor->link_freq = v4l2_ctrl_new_int_menu(&sensor->ctrl_handler,
                                               &milianke_ctrl_ops,
                                               V4L2_CID_LINK_FREQ,
                                               0, 0, link_freq_menu);
    if (sensor->link_freq)
        sensor->link_freq->flags |= V4L2_CTRL_FLAG_READ_ONLY;
    {
        u32 pr_max = 0;
        u32 vb_min = milianke_modes[0].vblank;
        u32 vb_max = milianke_modes[0].vblank;
        u32 i;

        for (i = 0; i < MILIANKE_NUM_MODES; i++)
        {
            if (milianke_modes[i].pixel_rate > pr_max)
                pr_max = (u32)milianke_modes[i].pixel_rate;
            if (milianke_modes[i].vblank < vb_min)
                vb_min = milianke_modes[i].vblank;
            if (milianke_modes[i].vblank > vb_max)
                vb_max = milianke_modes[i].vblank;
        }

        sensor->pixel_rate = v4l2_ctrl_new_std(
            &sensor->ctrl_handler, &milianke_ctrl_ops,
            V4L2_CID_PIXEL_RATE, 0, pr_max, 1,
            (s32)milianke_modes[sensor->mode_index].pixel_rate);
        if (sensor->pixel_rate)
            sensor->pixel_rate->flags |= V4L2_CTRL_FLAG_READ_ONLY;
        sensor->vblank = v4l2_ctrl_new_std(
            &sensor->ctrl_handler, NULL, V4L2_CID_VBLANK, vb_min, vb_max,
            1, milianke_modes[sensor->mode_index].vblank);
    }
    if (sensor->ctrl_handler.error)
    {
        ret = sensor->ctrl_handler.error;
        goto err_ctrl;
    }

    sensor->mipi_en_gpio = devm_gpiod_get_optional(&client->dev, "mipi-en",
                                                   GPIOD_OUT_LOW);
    if (IS_ERR(sensor->mipi_en_gpio))
    {
        ret = PTR_ERR(sensor->mipi_en_gpio);
        goto err_ctrl;
    }

    if (sensor->mipi_en_gpio)
        gpiod_set_value_cansleep(sensor->mipi_en_gpio, 0);
    if (sensor->mipi_en_gpio && always_on)
    {
        dev_info(&client->dev,
                 "always_on=1 ignored: mipi-en toggled by s_stream()\n");
    }

    sd->ctrl_handler = &sensor->ctrl_handler;
    v4l2_ctrl_handler_setup(&sensor->ctrl_handler);

    {
        struct fwnode_handle *ep;

        ep = fwnode_graph_get_next_endpoint(dev_fwnode(&client->dev),
                                            NULL);
        if (ep)
            sd->fwnode = ep;
    }

    ret = v4l2_async_register_subdev(sd);
    if (ret)
        goto err_ctrl;

    dev_info(&client->dev,
             "milianke MIPI sensor registered: %s (FPGA CSI-2, mode[%u]=%s, max-4k, link-freq=%lld, mipi-en=%s)\n",
             sd->name, sensor->mode_index,
             milianke_modes[sensor->mode_index].name,
             (long long)milianke_modes[sensor->mode_index].link_freq,
             sensor->mipi_en_gpio ? "yes" : "none");

    return 0;

err_ctrl:
    v4l2_ctrl_handler_free(&sensor->ctrl_handler);
    media_entity_cleanup(&sd->entity);
err_mutex:
    mutex_destroy(&sensor->mutex);
    return ret;
}

static void milianke_remove(struct i2c_client *client)
{
    struct v4l2_subdev *sd = i2c_get_clientdata(client);
    struct milianke_mipi *sensor =
        container_of(sd, struct milianke_mipi, subdev);

    v4l2_async_unregister_subdev(sd);
    media_entity_cleanup(&sd->entity);
    v4l2_ctrl_handler_free(&sensor->ctrl_handler);
    mutex_destroy(&sensor->mutex);
}

static const struct of_device_id milianke_of_match[] = {

    {.compatible = "milianke,fpga-virtual"},
    {},
};
MODULE_DEVICE_TABLE(of, milianke_of_match);

static const struct i2c_device_id milianke_id[] = {
    {"milianke_mipi", 0},
    {},
};
MODULE_DEVICE_TABLE(i2c, milianke_id);

static struct i2c_driver milianke_driver = {
    .driver = {
        .name = "milianke_mipi",
        .of_match_table = milianke_of_match,
    },
    .probe = milianke_probe,
    .remove = milianke_remove,
    .id_table = milianke_id,
};
module_i2c_driver(milianke_driver);

MODULE_DESCRIPTION("Milianke virtual MIPI CSI-2 sensor (RK3576)");
MODULE_AUTHOR("Milianke / AFC03 FPGA team");
MODULE_LICENSE("GPL");
